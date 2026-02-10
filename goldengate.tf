# ============================================================================
# OCI GoldenGate - Deployment, Connections, Assignments, and Processes
# ============================================================================
#
# For migrations with enable_reverse_replication = true, this file also creates
# GoldenGate Extract and Replicat processes via the GG REST API. This enables
# reverse (fallback) replication from ADB target back to the source Oracle DB.
#
# The GG REST API is documented here:
#   https://docs.oracle.com/en/cloud/paas/goldengate-service/uaest/
#
# IMPORTANT: The Terraform OCI provider does NOT have native resources for
# GoldenGate Extract/Replicat processes. We use null_resource + local-exec
# calling the GG REST API via curl. This requires network connectivity from
# the machine running Terraform to the GG private endpoint.
# ============================================================================

# ----------------------------------------------------------------------------
# Locals
# ----------------------------------------------------------------------------
locals {
  gg_target_db_keys = toset(keys(var.target_databases))
  gg_source_db_keys = toset(keys(var.source_databases))

  # Migrations with reverse replication enabled (fallback)
  fallback_migrations = {
    for k, m in var.migrations : k => m if try(m.enable_reverse_replication, false)
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
  routing_method  = "DEDICATED_ENDPOINT"
  subnet_id       = var.private_subnet_ocid
  nsg_ids         = local.all_nsg_ids
  vault_id        = var.vault_ocid
  key_id          = var.vault_key_ocid

  lifecycle { ignore_changes = [password] }
}

resource "oci_golden_gate_connection" "ext_oracle" {
  for_each        = var.source_databases
  compartment_id  = var.compartment_ocid
  display_name    = "gg-ext-oracle-${each.key}"
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
# OCI needs time to make connections usable after creation
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
  fqdn           = var.source_databases[each.key].hostname
  username       = var.source_databases[each.key].gg_username
  password       = var.source_databases[each.key].gg_password
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
#
# Created via GG REST API for migrations with enable_reverse_replication=true
#
# Reverse replication flow:
#   ADB (source for fallback) → Extract → Trail → Replicat → Source Oracle DB
#
# The alias names for credentials match the connection display names registered
# in the GG deployment via connection_assignments above.
#
# REST API reference:
#   https://docs.oracle.com/en/cloud/paas/goldengate-service/uaest/
# ============================================================================

# --- Wait for assignments to complete before creating processes ---
resource "time_sleep" "wait_for_assignments" {
  count = length(local.fallback_migrations) > 0 ? 1 : 0
  depends_on = [
    oci_golden_gate_connection_assignment.adb,
    oci_golden_gate_connection_assignment.ext_oracle
  ]
  create_duration = "60s"
}

# ----------------------------------------------------------------------------
# Create Extract process (captures changes FROM the ADB target for fallback)
# ----------------------------------------------------------------------------
resource "null_resource" "gg_fallback_extract" {
  for_each = local.fallback_migrations

  depends_on = [time_sleep.wait_for_assignments]

  triggers = {
    deployment_id = oci_golden_gate_deployment.gg.id
    migration_key = each.key
    target_db_key = each.value.target_db_key
    run_id        = var.force_rerun_validate_start
  }

  provisioner "local-exec" {
    command = <<-EOC
      set -e

      GG_URL="${oci_golden_gate_deployment.gg.deployment_url}"
      GG_USER="${var.goldengate_admin_username}"
      GG_PASS="${var.goldengate_admin_password}"

      # Extract name: up to 8 chars, uppercase
      EXTRACT_NAME=$(echo "EX${upper(substr(each.key, 0, 6))}" | head -c 8 | tr '[:lower:]' '[:upper:]')
      TRAIL_NAME="${var.extract_config.trail_name}"
      ADB_ALIAS="${upper(replace("gg-adb-${each.value.target_db_key}", "-", "_"))}"

      # Schemas to replicate for this migration
      SCHEMAS_JSON=""
      %{for obj in each.value.include_allow_objects~}
      SCHEMA_OWNER=$(echo "${obj}" | cut -d'.' -f1)
      SCHEMAS_JSON="$SCHEMAS_JSON\"Table $SCHEMA_OWNER.*;\","
      %{endfor~}
      # Remove trailing comma
      SCHEMAS_JSON=$(echo "$SCHEMAS_JSON" | sed 's/,$//')

      echo "[GG-EXTRACT] Creating extract $EXTRACT_NAME for migration ${each.key}..."
      echo "[GG-EXTRACT] GG URL: $GG_URL"
      echo "[GG-EXTRACT] Alias: $ADB_ALIAS"

      # Check if extract already exists
      HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" \
        -u "$GG_USER:$GG_PASS" \
        -H "Content-Type: application/json" \
        "$GG_URL/services/v2/extracts/$EXTRACT_NAME" 2>/dev/null || echo "000")

      if [ "$HTTP_CODE" = "200" ]; then
        echo "[GG-EXTRACT] Extract $EXTRACT_NAME already exists. Skipping creation."
        exit 0
      fi

      # Create Extract via REST API
      EXTRACT_JSON=$(cat <<-EJSON
      {
        "config": [
          "Extract $EXTRACT_NAME",
          "ExtTrail $TRAIL_NAME",
          "UserIdAlias $ADB_ALIAS",
          $SCHEMAS_JSON
        ],
        "source": {"tranlogs": "integrated"},
        "credentials": {"alias": "$ADB_ALIAS"},
        "registration": {"optimized": false},
        "begin": "now",
        "targets": [{"name": "$TRAIL_NAME"}],
        "status": "stopped"
      }
EJSON
      )

      RESPONSE=$(curl -s -w "\n%%{http_code}" \
        -u "$GG_USER:$GG_PASS" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X POST "$GG_URL/services/v2/extracts/$EXTRACT_NAME" \
        -d "$EXTRACT_JSON" 2>/dev/null || echo "CURL_FAILED")

      HTTP_CODE=$(echo "$RESPONSE" | tail -1)
      BODY=$(echo "$RESPONSE" | head -n -1)

      echo "[GG-EXTRACT] Response code: $HTTP_CODE"
      echo "[GG-EXTRACT] Body: $BODY"

      if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
        echo "[GG-EXTRACT] Extract $EXTRACT_NAME created successfully (stopped)."
      else
        echo "[WARN] Extract creation returned $HTTP_CODE. Check GG console manually."
        echo "[INFO] This may be expected if GG deployment is not yet fully ready."
      fi
    EOC

    on_failure = continue
  }
}

# ----------------------------------------------------------------------------
# Create Replicat process (applies changes TO the source Oracle DB for fallback)
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
    run_id        = var.force_rerun_validate_start
  }

  provisioner "local-exec" {
    command = <<-EOC
      set -e

      GG_URL="${oci_golden_gate_deployment.gg.deployment_url}"
      GG_USER="${var.goldengate_admin_username}"
      GG_PASS="${var.goldengate_admin_password}"

      # Replicat name: up to 8 chars, uppercase
      REPLICAT_NAME=$(echo "RP${upper(substr(each.key, 0, 6))}" | head -c 8 | tr '[:lower:]' '[:upper:]')
      TRAIL_NAME="${var.extract_config.trail_name}"
      EXT_ALIAS="${upper(replace("gg-ext-oracle-${each.value.source_db_key}", "-", "_"))}"

      # Schemas to replicate
      MAP_JSON=""
      %{for obj in each.value.include_allow_objects~}
      SCHEMA_OWNER=$(echo "${obj}" | cut -d'.' -f1)
      MAP_JSON="$MAP_JSON\"MAP $SCHEMA_OWNER.*, TARGET $SCHEMA_OWNER.*;\","
      %{endfor~}
      MAP_JSON=$(echo "$MAP_JSON" | sed 's/,$//')

      # Checkpoint table: use first schema owner
      FIRST_SCHEMA=$(echo "${try(each.value.include_allow_objects[0], "GGADMIN")}" | cut -d'.' -f1)
      CHECKPOINT_TABLE="$FIRST_SCHEMA.GG_CHECKPOINT"

      echo "[GG-REPLICAT] Creating replicat $REPLICAT_NAME for migration ${each.key}..."
      echo "[GG-REPLICAT] GG URL: $GG_URL"
      echo "[GG-REPLICAT] Alias: $EXT_ALIAS"

      # Check if replicat already exists
      HTTP_CODE=$(curl -s -o /dev/null -w "%%{http_code}" \
        -u "$GG_USER:$GG_PASS" \
        -H "Content-Type: application/json" \
        "$GG_URL/services/v2/replicats/$REPLICAT_NAME" 2>/dev/null || echo "000")

      if [ "$HTTP_CODE" = "200" ]; then
        echo "[GG-REPLICAT] Replicat $REPLICAT_NAME already exists. Skipping creation."
        exit 0
      fi

      # Create Replicat via REST API
      REPLICAT_JSON=$(cat <<-RJSON
      {
        "config": [
          "Replicat $REPLICAT_NAME",
          "UserIdAlias $EXT_ALIAS",
          "DiscardFile ./dirrpt/$${REPLICAT_NAME}_discard.txt, PURGE",
          $MAP_JSON
        ],
        "source": {"name": "$TRAIL_NAME"},
        "credentials": {"alias": "$EXT_ALIAS"},
        "checkpoint": {"table": "$CHECKPOINT_TABLE"},
        "mode": {
          "type": "nonintegrated",
          "parallel": false
        },
        "registration": "none",
        "begin": "now",
        "status": "stopped"
      }
RJSON
      )

      RESPONSE=$(curl -s -w "\n%%{http_code}" \
        -u "$GG_USER:$GG_PASS" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X POST "$GG_URL/services/v2/replicats/$REPLICAT_NAME" \
        -d "$REPLICAT_JSON" 2>/dev/null || echo "CURL_FAILED")

      HTTP_CODE=$(echo "$RESPONSE" | tail -1)
      BODY=$(echo "$RESPONSE" | head -n -1)

      echo "[GG-REPLICAT] Response code: $HTTP_CODE"
      echo "[GG-REPLICAT] Body: $BODY"

      if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
        echo "[GG-REPLICAT] Replicat $REPLICAT_NAME created successfully (stopped)."
        echo "[INFO] To start fallback replication, run:"
        echo "  curl -u $GG_USER:<password> -H 'Content-Type: application/json' -X POST $GG_URL/services/v2/commands/execute -d '{\"name\":\"start\",\"processName\":\"$EXTRACT_NAME\"}'"
        echo "  curl -u $GG_USER:<password> -H 'Content-Type: application/json' -X POST $GG_URL/services/v2/commands/execute -d '{\"name\":\"start\",\"processName\":\"$REPLICAT_NAME\"}'"
      else
        echo "[WARN] Replicat creation returned $HTTP_CODE. Check GG console manually."
      fi
    EOC

    on_failure = continue
  }
}

# ----------------------------------------------------------------------------
# GG Parameter Files (generated per fallback migration for reference)
# ----------------------------------------------------------------------------
resource "local_file" "extract_params" {
  for_each = local.fallback_migrations

  filename        = "${path.module}/gg-config/extract-${each.key}.prm"
  file_permission = "0644"

  content = <<-EOT
-- GoldenGate Extract Parameter File (Reverse/Fallback)
-- Migration: ${each.key}
-- Source for Extract: ADB ${each.value.target_db_key} (captures changes for fallback)
-- Auto-generated by Terraform

EXTRACT EX${upper(substr(each.key, 0, 6))}
USERIDALIAS ${upper(replace("gg-adb-${each.value.target_db_key}", "-", "_"))}
EXTTRAIL ${var.extract_config.trail_name}

%{for obj in each.value.include_allow_objects~}
TABLE ${split(".", obj)[0]}.*;
%{endfor~}

-- End of file
  EOT

  depends_on = [oci_golden_gate_deployment.gg]
}

resource "local_file" "replicat_params" {
  for_each = local.fallback_migrations

  filename        = "${path.module}/gg-config/replicat-${each.key}.prm"
  file_permission = "0644"

  content = <<-EOT
-- GoldenGate Replicat Parameter File (Reverse/Fallback)
-- Migration: ${each.key}
-- Target for Replicat: Source Oracle DB ${each.value.source_db_key}
-- Auto-generated by Terraform

REPLICAT RP${upper(substr(each.key, 0, 6))}
USERIDALIAS ${upper(replace("gg-ext-oracle-${each.value.source_db_key}", "-", "_"))}
DISCARDFILE ./dirrpt/RP${upper(substr(each.key, 0, 6))}_discard.txt, PURGE

%{for obj in each.value.include_allow_objects~}
MAP ${split(".", obj)[0]}.*, TARGET ${split(".", obj)[0]}.*;
%{endfor~}

-- End of file
  EOT

  depends_on = [oci_golden_gate_deployment.gg]
}

