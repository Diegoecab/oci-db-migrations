# ============================================================================
# OCI GoldenGate - Deployment, Connections, Assignments, and Processes
# Create Extract/Replicat via POST on NAMED resource (no "name" field in JSON)
# Based on observed behavior:
#  - /extracts (collection) returns 405
#  - POST /extracts/<NAME> is accepted, but schema rejects "name" property
# ============================================================================

# ----------------------------------------------------------------------------
# Locals
# ----------------------------------------------------------------------------
locals {
  gg_target_db_keys = toset(keys(var.target_databases))
  gg_source_db_keys = toset(keys(var.source_databases))

  fallback_migrations = {
    for k, m in var.migrations : k => m if try(m.enable_reverse_replication, false)
  }

  # Unique 8-char names: EX/RP + 6 hex chars from md5(key)
  gg_extract_name = {
    for k, m in local.fallback_migrations :
    k => upper("EX${substr(md5(k), 0, 6)}")
  }
  gg_replicat_name = {
    for k, m in local.fallback_migrations :
    k => upper("RP${substr(md5(k), 0, 6)}")
  }
}

# ----------------------------------------------------------------------------
# GoldenGate Deployment
# ----------------------------------------------------------------------------
resource "oci_golden_gate_deployment" "gg" {
  compartment_id          = var.compartment_ocid
  display_name            = var.goldengate_display_name
  license_model           = var.goldengate_license_model
  subnet_id               = var.private_subnet_ocid
  cpu_core_count          = var.goldengate_cpu_core_count
  is_auto_scaling_enabled = var.goldengate_is_auto_scaling_enabled
  deployment_type         = var.goldengate_deployment_type
  nsg_ids                 = local.all_nsg_ids

  ogg_data {
    admin_username  = var.goldengate_admin_username
    admin_password  = var.goldengate_admin_password
    deployment_name = replace(var.goldengate_display_name, "-", "_")
  }

  lifecycle {
    ignore_changes = [ogg_data[0].admin_password, defined_tags]
  }
}

# ----------------------------------------------------------------------------
# GG Connections (Base Resources)
# ----------------------------------------------------------------------------
resource "oci_golden_gate_connection" "adb" {
  for_each        = var.target_databases
  compartment_id  = var.compartment_ocid
  display_name    = "gg-adb-${each.key}"
  connection_type = "ORACLE"
  technology_type = "OCI_AUTONOMOUS_DATABASE"
  database_id     = each.value.adb_ocid
  username        = each.value.gg_username
  password        = each.value.gg_password

  routing_method = "DEDICATED_ENDPOINT"
  subnet_id      = var.private_subnet_ocid
  nsg_ids        = local.all_nsg_ids
  vault_id       = var.vault_ocid
  key_id         = var.vault_key_ocid

  lifecycle { ignore_changes = [password] }
}

resource "oci_golden_gate_connection" "ext_oracle" {
  for_each        = var.source_databases
  compartment_id  = var.compartment_ocid
  display_name    = "gg-src-${each.key}"
  connection_type = "ORACLE"
  technology_type = "ORACLE_DATABASE"
  username        = each.value.gg_username
  password        = each.value.gg_password

  connection_string = format(
    "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%d))(CONNECT_DATA=(SERVICE_NAME=%s)))",
    coalesce(try(each.value.hostname, null), each.value.host),
    try(each.value.port, 1521),
    each.value.service_name
  )

  routing_method = "DEDICATED_ENDPOINT"
  subnet_id      = var.private_subnet_ocid
  nsg_ids        = local.all_nsg_ids
  vault_id       = var.vault_ocid
  key_id         = var.vault_key_ocid

  lifecycle { ignore_changes = [password] }
}

# ----------------------------------------------------------------------------
# Stabilization Delay (avoid 409/Reflection timing issues)
# ----------------------------------------------------------------------------
resource "time_sleep" "wait_for_connections" {
  depends_on = [
    oci_golden_gate_connection.adb,
    oci_golden_gate_connection.ext_oracle
  ]
  create_duration = "30s"
}

# ----------------------------------------------------------------------------
# GG Database Registrations
# ----------------------------------------------------------------------------
resource "oci_golden_gate_database_registration" "adb" {
  for_each       = local.gg_target_db_keys
  compartment_id = var.compartment_ocid
  display_name   = "gg-reg-adb-${each.key}"
  alias_name     = upper(replace("adb_${each.key}", "-", "_"))
  database_id    = var.target_databases[each.key].adb_ocid
  username       = var.target_databases[each.key].gg_username
  password       = var.target_databases[each.key].gg_password

  fqdn = lower(try(
    regex("host=([^)]+)", data.oci_database_autonomous_database.target_adb[each.key].connection_strings[0].all_connection_strings["HIGH"])[0],
    "${data.oci_database_autonomous_database.target_adb[each.key].db_name}.adb.${var.region}.oraclecloud.com"
  ))

  depends_on = [time_sleep.wait_for_connections]
  lifecycle { ignore_changes = [password] }
}

resource "oci_golden_gate_database_registration" "ext_oracle" {
  for_each       = local.gg_source_db_keys
  compartment_id = var.compartment_ocid
  display_name   = "gg-reg-ext-${each.key}"
  alias_name     = upper(replace("ext_${each.key}", "-", "_"))

  fqdn     = var.source_databases[each.key].hostname
  username = var.source_databases[each.key].gg_username
  password = var.source_databases[each.key].gg_password

  connection_string = format(
    "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%d))(CONNECT_DATA=(SERVICE_NAME=%s)))",
    coalesce(try(var.source_databases[each.key].host, null), var.source_databases[each.key].hostname),
    var.source_databases[each.key].port,
    var.source_databases[each.key].service_name
  )

  depends_on = [time_sleep.wait_for_connections]
  lifecycle { ignore_changes = [password] }
}

# ----------------------------------------------------------------------------
# Connection Assignments
# ----------------------------------------------------------------------------
resource "oci_golden_gate_connection_assignment" "adb" {
  for_each      = local.gg_target_db_keys
  connection_id = oci_golden_gate_connection.adb[each.key].id
  deployment_id = oci_golden_gate_deployment.gg.id
  depends_on    = [time_sleep.wait_for_connections]
}

resource "oci_golden_gate_connection_assignment" "ext_oracle" {
  for_each      = local.gg_source_db_keys
  connection_id = oci_golden_gate_connection.ext_oracle[each.key].id
  deployment_id = oci_golden_gate_deployment.gg.id
  depends_on    = [time_sleep.wait_for_connections]
}

# ============================================================================
# GoldenGate Extract & Replicat Processes (Reverse/Fallback Replication)
# ============================================================================

resource "time_sleep" "wait_for_assignments" {
  count = length(local.fallback_migrations) > 0 ? 1 : 0
  depends_on = [
    oci_golden_gate_connection_assignment.adb,
    oci_golden_gate_connection_assignment.ext_oracle
  ]
  create_duration = "60s"
}

# ----------------------------------------------------------------------------
# Create Extract process (ADMIN SERVICE REST)
# IMPORTANT: create via POST on /extracts/<NAME>, and JSON must NOT include "name"
# ----------------------------------------------------------------------------
resource "null_resource" "gg_fallback_extract" {
  for_each = local.fallback_migrations

  depends_on = [time_sleep.wait_for_assignments]

  triggers = {
    deployment_id = oci_golden_gate_deployment.gg.id
    migration_key = each.key
    target_db_key = each.value.target_db_key
    rerun_token   = var.gg_process_rerun_token
  }

  provisioner "local-exec" {
    command = <<-EOC
      set -euo pipefail
      LOGFILE="${path.module}/gg_extract_${each.key}.log"
      : > "$LOGFILE"

      GG_URL="${oci_golden_gate_deployment.gg.deployment_url}"
      GG_URL="$${GG_URL%/}"
      GG_USER="${var.goldengate_admin_username}"
      GG_PASS="${var.goldengate_admin_password}"

      EXTRACT_NAME="${local.gg_extract_name[each.key]}"
      TRAIL_NAME="${var.extract_config.trail_name}"
      ADB_ALIAS="${oci_golden_gate_connection.adb[each.value.target_db_key].display_name}"

      echo "--- Extract creation for ${each.key} ---" >> "$LOGFILE"
      echo "GG_URL=$GG_URL" >> "$LOGFILE"
      echo "EXTRACT_NAME=$EXTRACT_NAME" >> "$LOGFILE"
      echo "TRAIL_NAME=$TRAIL_NAME" >> "$LOGFILE"
      echo "ADB_ALIAS=$ADB_ALIAS" >> "$LOGFILE"

      HTTP_PING=$(curl -k -m 15 -s -o /dev/null -w "%%{http_code}" \
        -u "$GG_USER:$GG_PASS" \
        "$GG_URL/services/adminsrvr/v2/extracts" 2>>"$LOGFILE" || echo "000")
      echo "PING(adminsrvr/v2/extracts)=$HTTP_PING" >> "$LOGFILE"

      exists() {
        local path="$1"
        curl -k -m 15 -s -o /dev/null -w "%%{http_code}" \
          -u "$GG_USER:$GG_PASS" -H "Accept: application/json" \
          "$GG_URL$path/$EXTRACT_NAME" 2>>"$LOGFILE" || echo "000"
      }

      CODE1=$(exists "/services/adminsrvr/v2/extracts")
      CODE2=$(exists "/services/v2/extracts")
      echo "EXISTS(adminsrvr)=$CODE1 EXISTS(services/v2)=$CODE2" >> "$LOGFILE"
      if [ "$CODE1" = "200" ] || [ "$CODE2" = "200" ]; then
        echo "Extract $EXTRACT_NAME already exists. Skipping." | tee -a "$LOGFILE"
        exit 0
      fi

      # Build TABLE lines from allowlist:
      # - "SCHEMA.*" => TABLE SCHEMA.*;
      # - "SCHEMA.TABLE" => TABLE SCHEMA.TABLE;
      TABLE_LINES=""
      %{for obj in each.value.include_allow_objects~}
      %{ if length(split(".", obj)) > 1 && split(".", obj)[1] != "*" ~}
      TABLE_LINES="$${TABLE_LINES}\n    \"TABLE ${split(".", obj)[0]}.${split(".", obj)[1]};\","
      %{ else ~}
      TABLE_LINES="$${TABLE_LINES}\n    \"TABLE ${split(".", obj)[0]}.*;\","
      %{ endif ~}
      %{endfor~}
      TABLE_LINES=$(printf "%b" "$TABLE_LINES" | sed '$s/,$//')

      # NOTE: No "name" field here (your API rejects it)
      EXTRACT_JSON=$(cat <<EJSON
{
  "config": [
    "EXTRACT $EXTRACT_NAME",
    "USERIDALIAS $ADB_ALIAS",
    "EXTTRAIL $TRAIL_NAME",
$(printf "%b" "$TABLE_LINES")
  ],
  "source": { "tranlogs": "integrated" },
  "begin": "now",
  "status": "stopped"
}
EJSON
)

      try_create() {
        local method="$1"
        local url="$2"
        local resp http body
        resp=$(curl -k -m 30 -s -w "\\n%%{http_code}" \
          -u "$GG_USER:$GG_PASS" \
          -H "Content-Type: application/json" -H "Accept: application/json" \
          -X "$method" "$url" -d "$EXTRACT_JSON" 2>>"$LOGFILE" || true)
        http=$(echo "$resp" | tail -1)
        body=$(echo "$resp" | sed '$d')
        echo "TRY $method $url -> HTTP $http" >> "$LOGFILE"
        echo "$body" >> "$LOGFILE"

        if [ "$http" = "200" ] || [ "$http" = "201" ] || [ "$http" = "202" ]; then
          return 0
        fi
        if [ "$http" = "409" ] || echo "$body" | grep -qiE "already exists|exists"; then
          return 0
        fi
        return 1
      }

      # Only try NAMED endpoints (collection is 405 in your deployment)
      ENDPOINTS=(
        "$GG_URL/services/adminsrvr/v2/extracts/$EXTRACT_NAME"
        "$GG_URL/services/v2/extracts/$EXTRACT_NAME"
      )
      METHODS=("POST" "PATCH")

      ok=1
      for ep in "$${ENDPOINTS[@]}"; do
        for m in "$${METHODS[@]}"; do
          if try_create "$m" "$ep"; then
            ok=0
            break 2
          else
            echo "FAILED on $m $ep - continue." | tee -a "$LOGFILE"
          fi
        done
      done

      if [ "$ok" -ne 0 ]; then
        echo "FAILED: Could not create Extract. See log: $LOGFILE" | tee -a "$LOGFILE"
        exit 1
      fi
    EOC
    on_failure = fail
  }
}

# ----------------------------------------------------------------------------
# Create Replicat process (ADMIN SERVICE REST)
# IMPORTANT: create via POST on /replicats/<NAME>, and JSON must NOT include "name"
# ----------------------------------------------------------------------------
resource "null_resource" "gg_fallback_replicat" {
  for_each = local.fallback_migrations

  depends_on = [
    time_sleep.wait_for_assignments,
    null_resource.gg_fallback_extract
  ]

  triggers = {
    deployment_id = oci_golden_gate_deployment.gg.id
    migration_key = each.key
    source_db_key = each.value.source_db_key
    rerun_token   = var.gg_process_rerun_token
  }

  provisioner "local-exec" {
    command = <<-EOC
      set -euo pipefail
      LOGFILE="${path.module}/gg_replicat_${each.key}.log"
      : > "$LOGFILE"

      GG_URL="${oci_golden_gate_deployment.gg.deployment_url}"
      GG_URL="$${GG_URL%/}"
      GG_USER="${var.goldengate_admin_username}"
      GG_PASS="${var.goldengate_admin_password}"

      REPLICAT_NAME="${local.gg_replicat_name[each.key]}"
      TRAIL_NAME="${var.extract_config.trail_name}"
      EXT_ALIAS="${oci_golden_gate_connection.ext_oracle[each.value.source_db_key].display_name}"

      # Build MAP lines from allowlist:
      # - "SCHEMA.*" => MAP SCHEMA.*, TARGET SCHEMA.*;
      # - "SCHEMA.TABLE" => MAP SCHEMA.TABLE, TARGET SCHEMA.TABLE;
      MAP_LINES=""
      %{for obj in each.value.include_allow_objects~}
      %{ if length(split(".", obj)) > 1 && split(".", obj)[1] != "*" ~}
      MAP_LINES="$${MAP_LINES}\n    \"MAP ${split(".", obj)[0]}.${split(".", obj)[1]}, TARGET ${split(".", obj)[0]}.${split(".", obj)[1]};\","
      %{ else ~}
      MAP_LINES="$${MAP_LINES}\n    \"MAP ${split(".", obj)[0]}.*, TARGET ${split(".", obj)[0]}.*;\","
      %{ endif ~}
      %{endfor~}
      MAP_LINES=$(printf "%b" "$MAP_LINES" | sed '$s/,$//')

      FIRST_SCHEMA=$(echo "${try(each.value.include_allow_objects[0], "GGADMIN.DUMMY")}" | cut -d'.' -f1)
      CHECKPOINT_TABLE="$FIRST_SCHEMA.GG_CHECKPOINT"

      echo "--- Replicat creation for ${each.key} ---" >> "$LOGFILE"
      echo "GG_URL=$GG_URL" >> "$LOGFILE"
      echo "REPLICAT_NAME=$REPLICAT_NAME" >> "$LOGFILE"
      echo "TRAIL_NAME=$TRAIL_NAME" >> "$LOGFILE"
      echo "EXT_ALIAS=$EXT_ALIAS" >> "$LOGFILE"
      echo "CHECKPOINT_TABLE=$CHECKPOINT_TABLE" >> "$LOGFILE"

      exists() {
        local path="$1"
        curl -k -m 15 -s -o /dev/null -w "%%{http_code}" \
          -u "$GG_USER:$GG_PASS" -H "Accept: application/json" \
          "$GG_URL$path/$REPLICAT_NAME" 2>>"$LOGFILE" || echo "000"
      }
      CODE1=$(exists "/services/adminsrvr/v2/replicats")
      CODE2=$(exists "/services/v2/replicats")
      echo "EXISTS(adminsrvr)=$CODE1 EXISTS(services/v2)=$CODE2" >> "$LOGFILE"
      if [ "$CODE1" = "200" ] || [ "$CODE2" = "200" ]; then
        echo "Replicat $REPLICAT_NAME already exists. Skipping." | tee -a "$LOGFILE"
        exit 0
      fi

      # NOTE: No "name" field
      REPLICAT_JSON=$(cat <<RJSON
{
  "config": [
    "REPLICAT $REPLICAT_NAME",
    "USERIDALIAS $EXT_ALIAS",
    "DISCARDFILE ./dirrpt/$${REPLICAT_NAME}_discard.txt, PURGE",
$(printf "%b" "$MAP_LINES")
  ],
  "source": { "name": "$TRAIL_NAME" },
  "checkpoint": { "table": "$CHECKPOINT_TABLE" },
  "mode": { "type": "nonintegrated", "parallel": false },
  "begin": "now",
  "status": "stopped"
}
RJSON
)

      try_create() {
        local method="$1"
        local url="$2"
        local resp http body
        resp=$(curl -k -m 30 -s -w "\\n%%{http_code}" \
          -u "$GG_USER:$GG_PASS" \
          -H "Content-Type: application/json" -H "Accept: application/json" \
          -X "$method" "$url" -d "$REPLICAT_JSON" 2>>"$LOGFILE" || true)
        http=$(echo "$resp" | tail -1)
        body=$(echo "$resp" | sed '$d')
        echo "TRY $method $url -> HTTP $http" >> "$LOGFILE"
        echo "$body" >> "$LOGFILE"

        if [ "$http" = "200" ] || [ "$http" = "201" ] || [ "$http" = "202" ]; then
          return 0
        fi
        if [ "$http" = "409" ] || echo "$body" | grep -qiE "already exists|exists"; then
          return 0
        fi
        return 1
      }

      ENDPOINTS=(
        "$GG_URL/services/adminsrvr/v2/replicats/$REPLICAT_NAME"
        "$GG_URL/services/v2/replicats/$REPLICAT_NAME"
      )
      METHODS=("POST" "PATCH")

      ok=1
      for ep in "$${ENDPOINTS[@]}"; do
        for m in "$${METHODS[@]}"; do
          if try_create "$m" "$ep"; then
            ok=0
            break 2
          else
            echo "FAILED on $m $ep - continue." | tee -a "$LOGFILE"
          fi
        done
      done

      if [ "$ok" -ne 0 ]; then
        echo "FAILED: Could not create Replicat. See log: $LOGFILE" | tee -a "$LOGFILE"
        exit 1
      fi
    EOC
    on_failure = fail
  }
}

# ----------------------------------------------------------------------------
# GG Parameter Files (local reference)
# ----------------------------------------------------------------------------
resource "local_file" "extract_params" {
  for_each        = local.fallback_migrations
  filename        = "${path.module}/gg-config/extract-${each.key}.prm"
  file_permission = "0644"

  content = <<-EOT
-- Auto-generated
EXTRACT ${local.gg_extract_name[each.key]}
USERIDALIAS ${oci_golden_gate_connection.adb[each.value.target_db_key].display_name}
EXTTRAIL ${var.extract_config.trail_name}
%{for obj in each.value.include_allow_objects~}
%{ if length(split(".", obj)) > 1 && split(".", obj)[1] != "*" ~}
TABLE ${split(".", obj)[0]}.${split(".", obj)[1]};
%{ else ~}
TABLE ${split(".", obj)[0]}.*;
%{ endif ~}
%{endfor~}
EOT

  depends_on = [oci_golden_gate_deployment.gg]
}

resource "local_file" "replicat_params" {
  for_each        = local.fallback_migrations
  filename        = "${path.module}/gg-config/replicat-${each.key}.prm"
  file_permission = "0644"

  content = <<-EOT
-- Auto-generated
REPLICAT ${local.gg_replicat_name[each.key]}
USERIDALIAS ${oci_golden_gate_connection.ext_oracle[each.value.source_db_key].display_name}
DISCARDFILE ./dirrpt/${local.gg_replicat_name[each.key]}_discard.txt, PURGE
%{for obj in each.value.include_allow_objects~}
%{ if length(split(".", obj)) > 1 && split(".", obj)[1] != "*" ~}
MAP ${split(".", obj)[0]}.${split(".", obj)[1]}, TARGET ${split(".", obj)[0]}.${split(".", obj)[1]};
%{ else ~}
MAP ${split(".", obj)[0]}.*, TARGET ${split(".", obj)[0]}.*;
%{ endif ~}
%{endfor~}
EOT

  depends_on = [oci_golden_gate_deployment.gg]
}
