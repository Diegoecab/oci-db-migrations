# ============================================================================
# OCI GoldenGate - Deployment, Connections, Assignments, and Processes
# ============================================================================
#
# FIXES applied in this version:
#   1. Connection display_name = original key (avoid recreation)
#      GG alias = key with non-alphanumeric chars stripped
#   2. TRANLOGOPTIONS EXCLUDEUSER prevents replication loops with DMS
#   3. Extract JSON: credentials/registration/targets for auto-registration
#   4. "source": "tranlogs" (GG 23.26+ syntax, not deprecated object)
#   5. OGG-08241 auto-recovery (retry with registration:none)
#   6. DISCARDFILE without ./dirrpt/ path (OCI GG managed)
#   7. Auto checkpoint table: GGADMIN.GG_CHECKPOINT on source (not biz schema)
#   8. Auto-start controlled by var.gg_auto_start_processes
#   9. curl timeout 90s for registration operations
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

  # Checkpoint table in GGADMIN schema (not business schemas)
  gg_checkpoint_table = var.gg_checkpoint_table

  # -------------------------------------------------------------------
  # GG alias: USERIDALIAS that GoldenGate internally derives by
  # stripping ALL non-alphanumeric chars from the connection display_name.
  # E.g. "adb_prod_26ai" -> "adbprod26ai"
  #
  # Verify with AdminClient: INFO CREDENTIALSTORE
  # -------------------------------------------------------------------
  gg_adb_alias = {
    for k, v in var.target_databases :
    k => replace(replace("${k}", "-", ""), "_", "")
  }
  gg_src_alias = {
    for k, v in var.source_databases :
    k => replace(replace("${k}", "-", ""), "_", "")
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
# GG Connections - display_name = original key (avoid Terraform recreation)
# ----------------------------------------------------------------------------
resource "oci_golden_gate_connection" "adb" {
  for_each        = var.target_databases
  compartment_id  = var.compartment_ocid
  display_name    = each.key
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
  display_name    = each.key
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
# Stabilization Delay
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
  display_name   = "${each.key}"
  alias_name     = "${each.key}"
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
  display_name   = "${each.key}"
  alias_name     = "${each.key}"

  fqdn     = var.source_databases[each.key].hostname
  username = var.source_databases[each.key].gg_username
  password = var.source_databases[each.key].gg_password

  connection_string = format(
    "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%d))(CONNECT_DATA=(SERVICE_NAME=%s)))",
    coalesce(try(var.source_databases[each.key].hostname, null), var.source_databases[each.key].host),
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
# Extract - TRANLOGOPTIONS EXCLUDEUSER + auto-registration + OGG-08241 recovery
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
      ADB_ALIAS="${local.gg_adb_alias[each.value.target_db_key]}"

      echo "--- Extract creation for ${each.key} ---" >> "$LOGFILE"
      echo "EXTRACT_NAME=$EXTRACT_NAME  ADB_ALIAS=$ADB_ALIAS" >> "$LOGFILE"

      exists() {
        local path="$1"
        curl -k -m 15 -s -o /dev/null -w "%%{http_code}" \
          -u "$GG_USER:$GG_PASS" -H "Accept: application/json" \
          "$GG_URL$path/$EXTRACT_NAME" 2>>"$LOGFILE" || echo "000"
      }

      CODE1=$(exists "/services/v2/extracts")
      CODE2=$(exists "/services/adminsrvr/v2/extracts")
      echo "EXISTS(services/v2)=$CODE1 EXISTS(adminsrvr)=$CODE2" >> "$LOGFILE"
      if [ "$CODE1" = "200" ] || [ "$CODE2" = "200" ]; then
        echo "Extract $EXTRACT_NAME already exists. Skipping." | tee -a "$LOGFILE"
        exit 0
      fi

      # Build TABLE lines
      TABLE_LINES=""
      %{for obj in each.value.include_allow_objects~}
      %{ if length(split(".", obj)) > 1 && split(".", obj)[1] != "*" ~}
      TABLE_LINES="$${TABLE_LINES}\n    \"TABLE ${split(".", obj)[0]}.${split(".", obj)[1]};\","
      %{ else ~}
      TABLE_LINES="$${TABLE_LINES}\n    \"TABLE ${split(".", obj)[0]}.*;\","
      %{ endif ~}
      %{endfor~}
      TABLE_LINES=$(printf "%b" "$TABLE_LINES" | sed '$s/,$//')

      # Build TRANLOGOPTIONS EXCLUDEUSER lines (prevent loop with DMS)
      EXCLUDE_LINES=""
      %{for eu in var.gg_exclude_users~}
      EXCLUDE_LINES="$${EXCLUDE_LINES}\n    \"TRANLOGOPTIONS EXCLUDEUSER ${eu}\","
      %{endfor~}

      EXTRACT_JSON=$(cat <<EJSON
{
  "config": [
    "EXTRACT $EXTRACT_NAME",
    "USERIDALIAS $ADB_ALIAS",
$(if [ -n "$EXCLUDE_LINES" ]; then printf "%b" "$EXCLUDE_LINES"; fi)
    "EXTTRAIL $TRAIL_NAME",
$(printf "%b" "$TABLE_LINES")
  ],
  "source": "tranlogs",
  "credentials": { "alias": "$ADB_ALIAS" },
  "registration": { "optimized": false },
  "begin": "now",
  "status": "${local.auto_start_gg[each.key] ? "running" : "stopped"}"
}
EJSON
)

      echo "EXTRACT_JSON:" >> "$LOGFILE"
      echo "$EXTRACT_JSON" >> "$LOGFILE"

      try_create() {
        local method="$1"
        local url="$2"
        local json="$3"
        local resp http body
        resp=$(curl -k -m 90 -s -w "\\n%%{http_code}" \
          -u "$GG_USER:$GG_PASS" \
          -H "Content-Type: application/json" -H "Accept: application/json" \
          -X "$method" "$url" -d "$json" 2>>"$LOGFILE" || true)
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
        # OGG-08241: already registered with DB but process doesn't exist
        if echo "$body" | grep -q "OGG-08241"; then
          echo "OGG-08241 detected: already registered. Retrying with registration:none..." | tee -a "$LOGFILE"
          RETRY_JSON=$(echo "$json" | sed 's/"registration":[[:space:]]*{[^}]*}/"registration": "none"/')
          resp=$(curl -k -m 90 -s -w "\\n%%{http_code}" \
            -u "$GG_USER:$GG_PASS" \
            -H "Content-Type: application/json" -H "Accept: application/json" \
            -X "$method" "$url" -d "$RETRY_JSON" 2>>"$LOGFILE" || true)
          http=$(echo "$resp" | tail -1)
          body=$(echo "$resp" | sed '$d')
          echo "RETRY $method $url -> HTTP $http" >> "$LOGFILE"
          echo "$body" >> "$LOGFILE"
          if [ "$http" = "200" ] || [ "$http" = "201" ] || [ "$http" = "202" ]; then
            return 0
          fi
        fi
        return 1
      }

      ENDPOINTS=(
        "$GG_URL/services/v2/extracts/$EXTRACT_NAME"
        "$GG_URL/services/adminsrvr/v2/extracts/$EXTRACT_NAME"
      )

      ok=1
      for ep in "$${ENDPOINTS[@]}"; do
        if try_create "POST" "$ep" "$EXTRACT_JSON"; then
          ok=0
          break
        else
          echo "FAILED on POST $ep - continue." | tee -a "$LOGFILE"
        fi
      done

      if [ "$ok" -ne 0 ]; then
        echo "FAILED: Could not create Extract. See log: $LOGFILE" | tee -a "$LOGFILE"
        exit 1
      fi

      echo "Extract $EXTRACT_NAME created successfully." | tee -a "$LOGFILE"
    EOC
    on_failure = fail
  }
}

# ----------------------------------------------------------------------------
# Checkpoint Table - auto-created on source (on-prem) via Python + oracledb
#
# Uses GGADMIN.GG_CHECKPOINT to avoid polluting business schemas.
# Creates both the main table and auxiliary _lox table via direct SQL.
# Supports NNE (Native Network Encryption) via thick mode auto-detection.
#
# Controlled by var.gg_auto_create_checkpoint (default: true).
# If false, create manually:
#   DBLOGIN USERIDALIAS <alias> DOMAIN OracleGoldenGate
#   ADD CHECKPOINTTABLE GGADMIN.GG_CHECKPOINT
#
# Requires: miniconda3 (auto-installed) + oracledb pip package
# ----------------------------------------------------------------------------
resource "null_resource" "gg_checkpoint_table" {
  for_each = var.gg_auto_create_checkpoint ? toset([
    for k, m in local.fallback_migrations : m.source_db_key
  ]) : toset([])

  depends_on = [time_sleep.wait_for_assignments]

  triggers = {
    deployment_id = oci_golden_gate_deployment.gg.id
    source_db_key = each.key
    rerun_token   = var.gg_process_rerun_token
  }

  # Install Python 3.11+ via miniconda if system python is too old for oracledb
  provisioner "local-exec" {
    command = <<-EOC
      set -euo pipefail
      LOGFILE="${path.module}/gg_checkpoint_${each.key}_setup.log"
      : > "$LOGFILE"

      # Check if oracledb already works
      if python3 -c "import oracledb" 2>/dev/null; then
        echo "oracledb already available on system python3" | tee -a "$LOGFILE"
        exit 0
      fi

      CONDA_DIR="$HOME/miniconda3"
      CONDA_BIN="$CONDA_DIR/bin"

      # Check if miniconda already installed
      if [ -x "$CONDA_BIN/python3" ]; then
        echo "miniconda already installed at $CONDA_DIR" | tee -a "$LOGFILE"
        "$CONDA_BIN/pip3" install oracledb -q 2>&1 | tee -a "$LOGFILE" || true
        exit 0
      fi

      echo "Installing miniconda3 (Python 3.11)..." | tee -a "$LOGFILE"
      curl -fsSL -o /tmp/miniconda.sh \
        "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh" \
        2>&1 | tee -a "$LOGFILE"

      bash /tmp/miniconda.sh -b -p "$CONDA_DIR" 2>&1 | tee -a "$LOGFILE"
      rm -f /tmp/miniconda.sh

      echo "Installing oracledb..." | tee -a "$LOGFILE"
      "$CONDA_BIN/pip3" install oracledb -q 2>&1 | tee -a "$LOGFILE"

      echo "Setup complete: $($CONDA_BIN/python3 --version)" | tee -a "$LOGFILE"
    EOC
    on_failure = fail
  }

  provisioner "local-exec" {
    command = <<-EOC
      set -euo pipefail
      LOGFILE="${path.module}/gg_checkpoint_${each.key}.log"
      : > "$LOGFILE"

      # Use miniconda python if available, otherwise system python
      CONDA_BIN="$HOME/miniconda3/bin"
      if [ -x "$CONDA_BIN/python3" ]; then
        PY="$CONDA_BIN/python3"
      else
        PY="python3"
      fi
      echo "Using: $($PY --version)" >> "$LOGFILE"

      # Export ORACLE_HOME for thick mode (NNE support)
      export ORACLE_HOME="${coalesce(try(var.oracle_home, ""), "")}"
      if [ -n "$ORACLE_HOME" ] && [ -d "$ORACLE_HOME/lib" ]; then
        export LD_LIBRARY_PATH="$ORACLE_HOME/lib:$${LD_LIBRARY_PATH:-}"
        echo "ORACLE_HOME=$ORACLE_HOME" >> "$LOGFILE"
      fi

      DB_HOST="${coalesce(try(var.source_databases[each.key].host, ""), var.source_databases[each.key].hostname)}"
      DB_PORT="${var.source_databases[each.key].port}"
      DB_SERVICE="${var.source_databases[each.key].service_name}"
      DB_USER="${var.source_databases[each.key].gg_username}"
      DB_PASS="${var.source_databases[each.key].gg_password}"
      CHECKPOINT_TABLE="${local.gg_checkpoint_table}"

      echo "HOST=$DB_HOST PORT=$DB_PORT SERVICE=$DB_SERVICE TABLE=$CHECKPOINT_TABLE" >> "$LOGFILE"

      $PY ${path.module}/scripts/gg_create_checkpoint.py \
        "$DB_HOST" "$DB_PORT" "$DB_SERVICE" \
        "$DB_USER" "$DB_PASS" "$CHECKPOINT_TABLE" \
        2>&1 | tee -a "$LOGFILE"

      exit $${PIPESTATUS[0]}
    EOC
    on_failure = fail
  }
}

# ----------------------------------------------------------------------------
# Replicat - applies changes TO source on-prem
# Checkpoint: GGADMIN.GG_CHECKPOINT (shared, not per-schema)
# ----------------------------------------------------------------------------
resource "null_resource" "gg_fallback_replicat" {
  for_each = local.fallback_migrations

  depends_on = [
    time_sleep.wait_for_assignments,
    null_resource.gg_fallback_extract,
    null_resource.gg_checkpoint_table
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
      EXT_ALIAS="${local.gg_src_alias[each.value.source_db_key]}"
      CHECKPOINT_TABLE="${local.gg_checkpoint_table}"

      # Build MAP lines
      MAP_LINES=""
      %{for obj in each.value.include_allow_objects~}
      %{ if length(split(".", obj)) > 1 && split(".", obj)[1] != "*" ~}
      MAP_LINES="$${MAP_LINES}\n    \"MAP ${split(".", obj)[0]}.${split(".", obj)[1]}, TARGET ${split(".", obj)[0]}.${split(".", obj)[1]};\","
      %{ else ~}
      MAP_LINES="$${MAP_LINES}\n    \"MAP ${split(".", obj)[0]}.*, TARGET ${split(".", obj)[0]}.*;\","
      %{ endif ~}
      %{endfor~}
      MAP_LINES=$(printf "%b" "$MAP_LINES" | sed '$s/,$//')

      echo "--- Replicat creation for ${each.key} ---" >> "$LOGFILE"
      echo "REPLICAT_NAME=$REPLICAT_NAME  EXT_ALIAS=$EXT_ALIAS  CHECKPOINT=$CHECKPOINT_TABLE" >> "$LOGFILE"

      exists() {
        local path="$1"
        curl -k -m 15 -s -o /dev/null -w "%%{http_code}" \
          -u "$GG_USER:$GG_PASS" -H "Accept: application/json" \
          "$GG_URL$path/$REPLICAT_NAME" 2>>"$LOGFILE" || echo "000"
      }
      CODE1=$(exists "/services/v2/replicats")
      CODE2=$(exists "/services/adminsrvr/v2/replicats")
      echo "EXISTS(services/v2)=$CODE1 EXISTS(adminsrvr)=$CODE2" >> "$LOGFILE"
      if [ "$CODE1" = "200" ] || [ "$CODE2" = "200" ]; then
        echo "Replicat $REPLICAT_NAME already exists. Skipping." | tee -a "$LOGFILE"
        exit 0
      fi

      REPLICAT_JSON=$(cat <<RJSON
{
  "config": [
    "REPLICAT $REPLICAT_NAME",
    "USERIDALIAS $EXT_ALIAS",
    "DISCARDFILE $${REPLICAT_NAME}_discard.txt, PURGE",
$(printf "%b" "$MAP_LINES")
  ],
  "source": { "name": "$TRAIL_NAME" },
  "credentials": { "alias": "$EXT_ALIAS" },
  "checkpoint": { "table": "$CHECKPOINT_TABLE" },
  "mode": { "type": "nonintegrated", "parallel": false },
  "registration": "none",
  "begin": "now",
  "status": "${local.auto_start_gg[each.key] ? "running" : "stopped"}"
}
RJSON
)

      echo "REPLICAT_JSON:" >> "$LOGFILE"
      echo "$REPLICAT_JSON" >> "$LOGFILE"

      try_create() {
        local method="$1"
        local url="$2"
        local resp http body
        resp=$(curl -k -m 90 -s -w "\\n%%{http_code}" \
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
        "$GG_URL/services/v2/replicats/$REPLICAT_NAME"
        "$GG_URL/services/adminsrvr/v2/replicats/$REPLICAT_NAME"
      )

      ok=1
      for ep in "$${ENDPOINTS[@]}"; do
        if try_create "POST" "$ep"; then
          ok=0
          break
        else
          echo "FAILED on POST $ep - continue." | tee -a "$LOGFILE"
        fi
      done

      if [ "$ok" -ne 0 ]; then
        echo "FAILED: Could not create Replicat. See log: $LOGFILE" | tee -a "$LOGFILE"
        exit 1
      fi

      echo "Replicat $REPLICAT_NAME created successfully." | tee -a "$LOGFILE"
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
-- Auto-generated fallback Extract
EXTRACT ${local.gg_extract_name[each.key]}
USERIDALIAS ${local.gg_adb_alias[each.value.target_db_key]}
%{for eu in var.gg_exclude_users~}
TRANLOGOPTIONS EXCLUDEUSER ${eu}
%{endfor~}
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
-- Auto-generated fallback Replicat
REPLICAT ${local.gg_replicat_name[each.key]}
USERIDALIAS ${local.gg_src_alias[each.value.source_db_key]}
DISCARDFILE ${local.gg_replicat_name[each.key]}_discard.txt, PURGE
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
