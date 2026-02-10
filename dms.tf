# ============================================================================
# OCI Database Migration Service (DMS)
# Connections per source/target DB, migrations per schema set
# ============================================================================

# ----------------------------------------------------------------------------
# Source Connections (one per source database, private endpoint)
# ----------------------------------------------------------------------------
resource "oci_database_migration_connection" "source" {
  for_each             = var.source_databases
  compartment_id       = var.compartment_ocid
  display_name         = "src-${each.key}"
  connection_type      = "ORACLE"
  technology_type      = "ORACLE_DATABASE"
  username             = each.value.username    # General DMS user (e.g., dms_admin for initial load)
  password             = each.value.password    # Password for username
  replication_username = each.value.gg_username # GGADMIN for CDC/replication
  replication_password = each.value.gg_password # Password for GGADMIN
  connection_string = format(
    "(description=(address=(protocol=tcp)(port=%d)(host=%s))(connect_data=(service_name=%s)))",
    each.value.port,
    each.value.host,
    each.value.service_name
  )
  key_id    = var.vault_key_ocid
  vault_id  = var.vault_ocid
  subnet_id = var.private_subnet_ocid
  nsg_ids   = local.all_nsg_ids
  freeform_tags = merge(var.freeform_tags, {
    "Database" = each.key
    "Role"     = "Source"
  })
  lifecycle { ignore_changes = [password, replication_password] } # Ignore sensitive changes
}

resource "oci_database_migration_connection" "source_cdb" {
  for_each        = var.source_container_databases
  compartment_id  = var.compartment_ocid
  display_name    = "src-cdb-${each.key}"
  connection_type = "ORACLE"
  technology_type = "ORACLE_DATABASE"

  username = each.value.username
  password = each.value.password

  connection_string = format(
    "(description=(address=(protocol=tcp)(port=%d)(host=%s))(connect_data=(service_name=%s)))",
    try(each.value.port, 1521),
    each.value.host,
    each.value.service_name
  )

  key_id    = var.vault_key_ocid
  vault_id  = var.vault_ocid
  subnet_id = var.private_subnet_ocid
  nsg_ids   = local.all_nsg_ids

  lifecycle { ignore_changes = [password] }
}


# ----------------------------------------------------------------------------
# Target Connections (one per target ADB, private endpoint)
# ----------------------------------------------------------------------------
resource "oci_database_migration_connection" "target" {
  for_each             = var.target_databases
  compartment_id       = var.compartment_ocid
  display_name         = "tgt-${each.key}"
  connection_type      = "ORACLE"
  technology_type      = "OCI_AUTONOMOUS_DATABASE"
  username             = each.value.username    # ADMIN for initial load
  password             = each.value.password    # Password for ADMIN
  replication_username = each.value.gg_username # GGADMIN for CDC/replication on ADB
  replication_password = each.value.gg_password # Password for GGADMIN
  database_id          = each.value.adb_ocid
  key_id               = var.vault_key_ocid
  vault_id             = var.vault_ocid
  subnet_id            = var.private_subnet_ocid
  nsg_ids              = local.all_nsg_ids
  freeform_tags = merge(var.freeform_tags, {
    "Database" = each.key
    "Role"     = "Target"
  })
  lifecycle { ignore_changes = [password, replication_password] } # Ignore sensitive changes
}
# ----------------------------------------------------------------------------
# DMS Migrations (one per migration entry)
# Each references shared source/target connections by key
# ----------------------------------------------------------------------------
resource "oci_database_migration_migration" "migration" {
  for_each       = var.migrations
  compartment_id = var.compartment_ocid
  display_name   = each.value.display_name
  type           = each.value.migration_type

  # REQUIRED (newer provider): ORACLE / MYSQL etc.
  database_combination = try(each.value.database_combination, "ORACLE")

  source_database_connection_id = oci_database_migration_connection.source[each.value.source_db_key].id
  target_database_connection_id = oci_database_migration_connection.target[each.value.target_db_key].id

  # ------------------------------------------------------------
  # ONLY for Online + PDB sources: link the CDB/root connection
  # Docs: required for PDB online migrations; optional otherwise
  # ------------------------------------------------------------
  source_container_database_connection_id = ((upper(try(each.value.migration_mode, "")) == "ONLINE" || can(regex("ONLINE", upper(try(each.value.migration_type, ""))))) && try(each.value.source_cdb_key, null) != null) ? oci_database_migration_connection.source_cdb[each.value.source_cdb_key].id : null

  # ------------------------------------------------------------
  # GoldenGate Settings - Required for Online Replication
  # ------------------------------------------------------------
  dynamic "ggs_details" {
    for_each = upper(each.value.migration_type) == "ONLINE" ? [1] : []
    content {
      acceptable_lag = try(each.value.acceptable_lag, 30)
    }
  }


  # --------------------------------------------------------------------------
  # Initial Load + Data Transport (match OCI Console "Create migration")
  # - Transfer medium for initial load: Data Pump via Object Storage
  # - Job mode: SCHEMA
  # - Export directory object name/path
  # - SSL wallet path for HTTPS upload to Object Storage
  # --------------------------------------------------------------------------
  dynamic "data_transfer_medium_details" {
    for_each = var.object_storage_bucket != null ? [1] : []
    content {
      type = "OBJECT_STORAGE"

      object_storage_bucket {
        namespace = local.os_namespace
        bucket    = var.object_storage_bucket
      }

      source {
        kind            = "CURL"
        wallet_location = var.source_db_ssl_wallet_path
      }

      # Target is ADB; do not set a target dump transfer host/wallet.
    }
  }


  dynamic "initial_load_settings" {
    for_each = var.object_storage_bucket != null ? [1] : []
    content {
      job_mode = "SCHEMA"

      export_directory_object {
        name = var.source_export_directory_object_name
        path = var.source_export_directory_object_path
      }
    }
  }

  # --------------------------------------------------------------------------
  # IMPORTANT: DMS doesn't allow include_objects and exclude_objects together.
  # --------------------------------------------------------------------------
  lifecycle {
    ignore_changes = [freeform_tags, defined_tags]

    precondition {
      condition = !(
        length(try(each.value.include_allow_objects, [])) > 0 &&
        length(try(each.value.exclude_objects, [])) > 0
      )
      error_message = "DMS Migration can't set both include_objects (include_allow_objects) and exclude_objects at the same time. Pick one approach per migration."
    }

    # Si declarás source_cdb_key, forzá que sea online (evita misconfig silenciosa)
    precondition {
      condition = !(
        try(each.value.source_cdb_key, null) != null &&
        !(
          upper(try(each.value.migration_mode, "")) == "ONLINE" ||
          can(regex("ONLINE", upper(try(each.value.migration_type, ""))))
        )
      )
      error_message = "source_cdb_key was provided but migration is not ONLINE. CDB connection is only used for Online migrations."
    }
  }

  # -----------------------
  # INCLUDE rules
  # "SCHEMA.*" -> whole schema (type=SCHEMA, no object)
  # "SCHEMA.TABLE" -> specific table (type=TABLE, object=TABLE)
  # -----------------------
  dynamic "include_objects" {
    for_each = try(each.value.include_allow_objects, [])
    content {
      owner = split(".", include_objects.value)[0]
      object = (
        length(split(".", include_objects.value)) > 1 &&
        split(".", include_objects.value)[1] != "*"
      ) ? split(".", include_objects.value)[1] : ".*"
      type = (
        length(split(".", include_objects.value)) <= 1 ||
        split(".", include_objects.value)[1] == "*" ||
        split(".", include_objects.value)[1] == ".*"
      ) ? "ALL" : "TABLE"
    }
  }

  # -----------------------
  # EXCLUDE rules (only if no include rules)
  # -----------------------
  dynamic "exclude_objects" {
    for_each = (length(try(each.value.include_allow_objects, [])) == 0) ? try(each.value.exclude_objects, []) : []
    content {
      owner  = split(".", exclude_objects.value)[0]
      object = length(split(".", exclude_objects.value)) > 1 ? split(".", exclude_objects.value)[1] : null
      type   = "TABLE"
    }
  }

  freeform_tags = merge(var.freeform_tags, { "Migration" = each.key })
}


# ----------------------------------------------------------------------------
# Auto-Validate and Auto-Start (per migration, configurable)
# Uses a timestamp trigger so 'terraform apply' re-runs when flags change.
# References locals from data.tf (no duplication).
# Set auto_start_migration = true (or per-migration auto_start = true)
# then run 'terraform apply' to trigger start.
# Updated: No 'validate' CLI; use state check. Conditional start if not Active.
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# Auto-Validate and Auto-Start (per migration, configurable)
# Uses a timestamp trigger so 'terraform apply' re-runs when flags change.
# References locals from data.tf (no duplication).
# Set auto_start_migration = true (or per-migration auto_start = true)
# then run 'terraform apply' to trigger start.
# Updated: use 'evaluate' as Validate Migration job. Improved wait + logs.
# ----------------------------------------------------------------------------
resource "null_resource" "validate_and_start_migration" {
  for_each = { for k, v in var.migrations : k => v if local.auto_start[k] || local.auto_validate[k] } # Uses data.tf locals

  depends_on = [
    oci_database_migration_migration.migration,
    oci_golden_gate_connection_assignment.adb,
    oci_golden_gate_connection_assignment.ext_oracle,
  ]

  triggers = {
    migration_id = oci_database_migration_migration.migration[each.key].id
    do_validate  = tostring(local.auto_validate[each.key]) # From data.tf
    do_start     = tostring(local.auto_start[each.key])    # From data.tf
    run_id       = var.force_rerun_validate_start
  }

  provisioner "local-exec" {
    command = <<-EOC
      set -e

      MIGRATION_ID="${oci_database_migration_migration.migration[each.key].id}"
      MIGRATION_KEY="${each.key}"

      echo "[MIGRATION] $MIGRATION_KEY id=$MIGRATION_ID"

      if ! command -v oci &>/dev/null; then
        echo "[WARN] OCI CLI not found. Skipping evaluate/start for $MIGRATION_KEY. Use Console."
        exit 0
      fi

      dump_wr_details() {
        local WR="$1"
        echo "[DIAG] Work Request: $WR"
        oci database-migration work-request get --work-request-id "$WR" --query 'data' --raw-output || true
        echo "[DIAG] Work Request Errors (if any):"
        oci database-migration work-request-error list --work-request-id "$WR" || true
        echo "[DIAG] Work Request Logs (last 100):"
        oci database-migration work-request-log-entry list --work-request-id "$WR" --limit 100 || true
      }

      get_state() {
        oci database-migration migration get \
          --migration-id "$MIGRATION_ID" \
          --query 'data."lifecycle-state"' \
          --raw-output 2>/dev/null || echo "UNKNOWN"
      }

      # 0) Current state (before anything)
      STATE="$(get_state)"
      echo "  Current State (pre): $STATE"

      # 1) Validate (Evaluate == Validate Migration job in OCI CLI)
      #    - Run if auto_validate=true
      #    - Or if auto_start=true AND state is ACCEPTED (common after create)
      SHOULD_EVALUATE="false"
      if [ "${local.auto_validate[each.key]}" = "true" ]; then
        SHOULD_EVALUATE="true"
      elif [ "${local.auto_start[each.key]}" = "true" ] && [ "$STATE" = "ACCEPTED" ]; then
        # You asked to allow start when ACCEPTED; evaluation usually moves it forward.
        SHOULD_EVALUATE="true"
      fi

      if [ "$SHOULD_EVALUATE" = "true" ]; then
        echo "[VALIDATE] Starting Validate Migration job (evaluate) for $MIGRATION_KEY..."
        WORK_ID="$(oci database-migration migration evaluate \
          --migration-id "$MIGRATION_ID" \
          --query 'opc-work-request-id' \
          --raw-output 2>/dev/null || echo "")"

        if [ -n "$WORK_ID" ] && [ "$WORK_ID" != "" ]; then
          echo "[VALIDATE] Work ID: $WORK_ID - Waiting for SUCCEEDED/FAILED..."
          # IMPORTANT: wait-for-state must be specified once per state
          set +e
          oci database-migration work-request get \
            --work-request-id "$WORK_ID" \
            --wait-for-state SUCCEEDED \
            --wait-for-state FAILED \
            --wait-interval-seconds 10 \
            --max-wait-seconds 1800
          WR_WAIT_RC=$?
          set -e

          VALIDATION_STATE="$(oci database-migration work-request get \
            --work-request-id "$WORK_ID" \
            --query 'data.status' \
            --raw-output 2>/dev/null || echo "UNKNOWN")"

          echo "  Validation Status: $VALIDATION_STATE (wait_rc=$WR_WAIT_RC)"

          if [ "$VALIDATION_STATE" != "SUCCEEDED" ]; then
            echo "[ERROR] Validation did not succeed for $MIGRATION_KEY."
            dump_wr_details "$WORK_ID"
            exit 1
          fi
        else
          echo "[WARN] No work ID from evaluate for $MIGRATION_KEY (already running/validated or API error)."
          echo "[INFO] Continuing with state checks..."
        fi
      fi

      # 2) Re-check state after validation attempt
      STATE="$(get_state)"
      echo "  Current State (post-validate): $STATE"

      # 3) Auto-start logic
      if [ "${local.auto_start[each.key]}" = "true" ]; then
        echo "[CHECK] Attempting to start $MIGRATION_KEY..."

        if [ "$STATE" = "ACTIVE" ] || [ "$STATE" = "MIGRATING" ]; then
          echo "[INFO] Migration already active ($STATE). Nothing to start."
          exit 0
        fi

        # If still ACCEPTED, give it a short window to transition (eventual consistency)
        if [ "$STATE" = "ACCEPTED" ]; then
          echo "[INFO] State is ACCEPTED. Waiting briefly for transition to READY/ACTIVE..."
          for i in $(seq 1 30); do
            sleep 10
            STATE="$(get_state)"
            echo "  Poll[$i] State: $STATE"
            if [ "$STATE" = "READY" ] || [ "$STATE" = "ACTIVE" ] || [ "$STATE" = "MIGRATING" ]; then
              break
            fi
          done
        fi

        if [ "$STATE" = "READY" ]; then
          echo "[START] Starting $MIGRATION_KEY (state=READY)"
          oci database-migration migration start --migration-id "$MIGRATION_ID"
          exit 0
        fi

        # You asked: start even if ACCEPTED. Try, but warn.
        if [ "$STATE" = "ACCEPTED" ]; then
          echo "[WARN] Still ACCEPTED after waiting. Trying start anyway (as requested)."
          set +e
          oci database-migration migration start --migration-id "$MIGRATION_ID"
          START_RC=$?
          set -e
          if [ $START_RC -ne 0 ]; then
            echo "[ERROR] Start failed for $MIGRATION_KEY (state=$STATE). Check DMS Work Requests in Console."
            exit 1
          fi
          exit 0
        fi

        echo "[INFO] State=$STATE. Not starting. (Expected READY/ACCEPTED/ACTIVE/MIGRATING)"
      fi
    EOC

    # Keep your original behavior (no hard-fail the whole apply), but we now exit 1 on real failures.
    on_failure = continue
  }
}

# ----------------------------------------------------------------------------
# Pre-Cutover Validation Script (generated per ONLINE migration)
# Uses local.online_migrations from data.tf
# ----------------------------------------------------------------------------
resource "local_file" "pre_cutover_script" {
  for_each        = var.pre_cutover_validation_enabled ? local.online_migrations : {} # From data.tf
  filename        = "${path.module}/gg-config/pre-cutover-${each.key}.sh"
  file_permission = "0755"
  content         = <<-SCRIPT
#!/bin/bash
# Pre-Cutover Validation for migration: ${each.key}
# Auto-generated by Terraform. Run before executing switchover.
set -e
MIGRATION_ID="${oci_database_migration_migration.migration[each.key].id}"
MAX_LAG=${var.pre_cutover_max_lag_seconds}
echo "============================================"
echo " Pre-Cutover Validation: ${each.key}"
echo "============================================"
echo ""
# 1. Check migration state
echo "[CHECK] Migration state..."
STATE=$(oci database-migration migration get --migration-id "$MIGRATION_ID" \
  --query 'data."lifecycle-state"' --raw-output 2>/dev/null)
echo "  State: $STATE"
if [ "$STATE" != "ACTIVE" ] && [ "$STATE" != "MIGRATING" ]; then
  echo "[FAIL] Migration is not in ACTIVE/MIGRATING state."
  exit 1
fi
# 2. Check lag
echo "[CHECK] Replication lag..."
echo "  Maximum acceptable lag: $MAX_LAG seconds"
echo "  (Verify current lag in OCI Console or GoldenGate admin)"
# 3. Check connections
echo "[CHECK] Source connection..."
SRC_ID="${oci_database_migration_connection.source[each.value.source_db_key].id}"
SRC_STATE=$(oci database-migration connection get --connection-id "$SRC_ID" \
  --query 'data."lifecycle-state"' --raw-output 2>/dev/null)
echo "  Source connection state: $SRC_STATE"
echo "[CHECK] Target connection..."
TGT_ID="${oci_database_migration_connection.target[each.value.target_db_key].id}"
TGT_STATE=$(oci database-migration connection get --connection-id "$TGT_ID" \
  --query 'data."lifecycle-state"' --raw-output 2>/dev/null)
echo "  Target connection state: $TGT_STATE"
echo ""
echo "============================================"
echo " All pre-cutover checks passed for ${each.key}"
echo " Safe to proceed with switchover."
echo "============================================"
  SCRIPT
}
