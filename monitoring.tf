# ============================================================================
# OCI Monitoring - Alarms for DMS and GoldenGate
# ============================================================================
#
# DMS Console Quickstart Template #6:
#   "Replication latency exceeds 5 seconds"
#   → Metric alarm on MigrationLag in namespace oci_database_migration
#
# Additional alarms:
#   - MigrationHealth (0=Unhealthy, 1=Healthy) per migration
#   - GoldenGate CPU, ExtractLag, ReplicatLag
#
# IMPORTANT:
#   - MigrationLag metric is ONLY emitted during the CDC replication phase
#     of ONLINE migrations. During initial load or validation, no data exists.
#   - MigrationHealth is emitted for all active migrations.
#   - message_format = "ONS_OPTIMIZED" sends readable email notifications.
#     Without it, emails contain raw JSON.
#
# VERIFY:
#   oci monitoring metric list --compartment-id $COMPARTMENT_ID \
#     --namespace oci_database_migration
#   oci ons subscription list --compartment-id $COMPARTMENT_ID \
#     --topic-id $TOPIC_OCID \
#     --query 'data[].{email:endpoint, state:"lifecycle-state"}' \
#     --output table
# ============================================================================

# ============================================================================
# TEMPLATE 6: Replication latency exceeds N seconds (per ONLINE migration)
# ============================================================================
resource "oci_monitoring_alarm" "dms_replication_lag_warn" {
  for_each              = var.enable_monitoring && var.notification_topic_ocid != null ? local.online_migrations : {}
  compartment_id        = var.compartment_ocid
  display_name          = "DMS Replication Lag WARNING - ${each.key}"
  is_enabled            = true
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_database_migration"
  severity              = "WARNING"
  message_format        = "ONS_OPTIMIZED"

  query = "MigrationLag[5m]{migrationId = \"${oci_database_migration_migration.migration[each.key].id}\"}.max() > ${var.lag_threshold_seconds}"

  body = "Migration \"${each.key}\" replication lag exceeded ${var.lag_threshold_seconds}s.\nMigration ID: ${oci_database_migration_migration.migration[each.key].id}\nCheck GoldenGate replication status."

  pending_duration             = "PT5M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT1H"
  freeform_tags                = var.freeform_tags
}

resource "oci_monitoring_alarm" "dms_replication_lag_crit" {
  for_each              = var.enable_monitoring && var.notification_topic_ocid != null ? local.online_migrations : {}
  compartment_id        = var.compartment_ocid
  display_name          = "DMS Replication Lag CRITICAL - ${each.key}"
  is_enabled            = true
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_database_migration"
  severity              = "CRITICAL"
  message_format        = "ONS_OPTIMIZED"

  query = "MigrationLag[5m]{migrationId = \"${oci_database_migration_migration.migration[each.key].id}\"}.max() > ${var.lag_critical_threshold_seconds}"

  body = "CRITICAL - Migration \"${each.key}\" replication lag exceeded ${var.lag_critical_threshold_seconds}s.\nMigration ID: ${oci_database_migration_migration.migration[each.key].id}\nImmediate attention required."

  pending_duration             = "PT5M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT15M"
  freeform_tags                = var.freeform_tags
}

# ============================================================================
# MIGRATION HEALTH (all migrations)
# MigrationHealth = 0 means UNHEALTHY (visible in DMS Console Monitoring tab)
# ============================================================================
resource "oci_monitoring_alarm" "dms_health" {
  for_each              = var.enable_monitoring && var.notification_topic_ocid != null ? var.migrations : {}
  compartment_id        = var.compartment_ocid
  display_name          = "DMS Health CRITICAL - ${each.key}"
  is_enabled            = true
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_database_migration"
  severity              = "CRITICAL"
  message_format        = "ONS_OPTIMIZED"

  query = "MigrationHealth[5m]{migrationId = \"${oci_database_migration_migration.migration[each.key].id}\"}.max() < 1"

  body = "Migration \"${each.key}\" is UNHEALTHY (MigrationHealth = 0).\nMigration ID: ${oci_database_migration_migration.migration[each.key].id}\nCheck migration status in OCI Console."

  pending_duration             = "PT5M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT30M"
  freeform_tags                = var.freeform_tags
}

# ============================================================================
# GOLDENGATE ALARMS
# ============================================================================

# --- GG CPU ---
resource "oci_monitoring_alarm" "gg_cpu_warn" {
  count                 = var.enable_monitoring && var.notification_topic_ocid != null ? 1 : 0
  compartment_id        = var.compartment_ocid
  display_name          = "GoldenGate CPU WARNING"
  is_enabled            = true
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_goldengate"
  severity              = "WARNING"
  message_format        = "ONS_OPTIMIZED"

  query = "DeploymentCpuUtilization[5m]{deploymentId = \"${oci_golden_gate_deployment.gg.id}\"}.max() > 80"

  body = "GoldenGate CPU > 80%.\nDeployment: ${var.goldengate_display_name}\nConsider enabling auto-scaling."

  pending_duration             = "PT10M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT1H"
  freeform_tags                = var.freeform_tags
}

resource "oci_monitoring_alarm" "gg_cpu_critical" {
  count                 = var.enable_monitoring && var.notification_topic_ocid != null ? 1 : 0
  compartment_id        = var.compartment_ocid
  display_name          = "GoldenGate CPU CRITICAL"
  is_enabled            = true
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_goldengate"
  severity              = "CRITICAL"
  message_format        = "ONS_OPTIMIZED"

  query = "DeploymentCpuUtilization[5m]{deploymentId = \"${oci_golden_gate_deployment.gg.id}\"}.max() > 95"

  body = "GoldenGate CPU > 95% CRITICAL.\nDeployment: ${var.goldengate_display_name}\nScale up immediately."

  pending_duration             = "PT5M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT15M"
  freeform_tags                = var.freeform_tags
}

# --- GG Extract Lag ---
resource "oci_monitoring_alarm" "gg_extract_lag" {
  count                 = var.enable_monitoring && var.notification_topic_ocid != null ? 1 : 0
  compartment_id        = var.compartment_ocid
  display_name          = "GoldenGate Extract Lag WARNING"
  is_enabled            = true
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_goldengate"
  severity              = "WARNING"
  message_format        = "ONS_OPTIMIZED"

  query = "ExtractLag[5m]{deploymentId = \"${oci_golden_gate_deployment.gg.id}\"}.max() > ${var.lag_threshold_seconds}"

  body = "GoldenGate Extract lag > ${var.lag_threshold_seconds}s.\nDeployment: ${var.goldengate_display_name}"

  pending_duration             = "PT5M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT1H"
  freeform_tags                = var.freeform_tags
}

# --- GG Replicat Lag ---
resource "oci_monitoring_alarm" "gg_replicat_lag" {
  count                 = var.enable_monitoring && var.notification_topic_ocid != null ? 1 : 0
  compartment_id        = var.compartment_ocid
  display_name          = "GoldenGate Replicat Lag WARNING"
  is_enabled            = true
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_goldengate"
  severity              = "WARNING"
  message_format        = "ONS_OPTIMIZED"

  query = "ReplicatLag[5m]{deploymentId = \"${oci_golden_gate_deployment.gg.id}\"}.max() > ${var.lag_threshold_seconds}"

  body = "GoldenGate Replicat lag > ${var.lag_threshold_seconds}s.\nDeployment: ${var.goldengate_display_name}"

  pending_duration             = "PT5M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT1H"
  freeform_tags                = var.freeform_tags
}
