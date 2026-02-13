# ============================================================================
# OCI Monitoring - Alarms for DMS and GoldenGate
# ============================================================================
#
# Includes:
#   - DMS MigrationLag (WARNING + CRITICAL) per ONLINE migration
#   - DMS MigrationHealth per migration
#   - GoldenGate CPU (WARNING + CRITICAL)
#   - GoldenGate ExtractLag, ReplicatLag
#   - GoldenGate DeploymentHealthState (Extract/Replicat ABENDED detection)
# ============================================================================

# ============================================================================
# DMS: Replication latency (ONLINE migrations only)
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
# DMS: Migration Health (all migrations)
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
# GOLDENGATE: CPU
# ============================================================================
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
  body  = "GoldenGate CPU > 80%.\nDeployment: ${var.goldengate_display_name}\nConsider enabling auto-scaling."

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
  body  = "GoldenGate CPU > 95% CRITICAL.\nDeployment: ${var.goldengate_display_name}\nScale up immediately."

  pending_duration             = "PT5M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT15M"
  freeform_tags                = var.freeform_tags
}

# ============================================================================
# GOLDENGATE: Extract Lag
# ============================================================================
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
  body  = "GoldenGate Extract lag > ${var.lag_threshold_seconds}s.\nDeployment: ${var.goldengate_display_name}"

  pending_duration             = "PT5M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT1H"
  freeform_tags                = var.freeform_tags
}

# ============================================================================
# GOLDENGATE: Replicat Lag
# ============================================================================
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
  body  = "GoldenGate Replicat lag > ${var.lag_threshold_seconds}s.\nDeployment: ${var.goldengate_display_name}"

  pending_duration             = "PT5M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT1H"
  freeform_tags                = var.freeform_tags
}

# ============================================================================
# GOLDENGATE: Process Health (ABENDED / STOPPED detection)
#
# DeploymentHealthState metric:
#   1 = All processes healthy
#   0 = At least one process is ABENDED or STOPPED unexpectedly
#
# This catches Extract or Replicat failures (e.g., OGG-10556, ORA errors)
# ============================================================================
resource "oci_monitoring_alarm" "gg_process_health" {
  count                 = var.enable_monitoring && var.notification_topic_ocid != null ? 1 : 0
  compartment_id        = var.compartment_ocid
  display_name          = "GoldenGate Process ABENDED/STOPPED"
  is_enabled            = true
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_goldengate"
  severity              = "CRITICAL"
  message_format        = "ONS_OPTIMIZED"

  query = "DeploymentHealthState[5m]{deploymentId = \"${oci_golden_gate_deployment.gg.id}\"}.min() < 1"

  body = <<-EOB
CRITICAL: GoldenGate process health degraded.
Deployment: ${var.goldengate_display_name}
One or more Extract/Replicat processes may be ABENDED or STOPPED.
Check GoldenGate Console: ${oci_golden_gate_deployment.gg.deployment_url}
EOB

  pending_duration             = "PT3M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT15M"
  freeform_tags                = var.freeform_tags
}

# ============================================================================
# GOLDENGATE: Extract Process Count dropped (complementary to health)
# If ExtractProcessCount drops to 0 when processes should be running
# ============================================================================
resource "oci_monitoring_alarm" "gg_extract_count_zero" {
  count                 = var.enable_monitoring && var.notification_topic_ocid != null ? 1 : 0
  compartment_id        = var.compartment_ocid
  display_name          = "GoldenGate No Active Extracts"
  is_enabled            = true
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_goldengate"
  severity              = "WARNING"
  message_format        = "ONS_OPTIMIZED"

  query = "ExtractProcessCount[5m]{deploymentId = \"${oci_golden_gate_deployment.gg.id}\"}.max() < 1"
  body  = "No active GoldenGate Extract processes detected.\nDeployment: ${var.goldengate_display_name}\nCheck if Extracts are running."

  pending_duration             = "PT10M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT1H"
  freeform_tags                = var.freeform_tags
}

# ============================================================================
# GOLDENGATE: Replicat Process Count dropped
# ============================================================================
resource "oci_monitoring_alarm" "gg_replicat_count_zero" {
  count                 = var.enable_monitoring && var.notification_topic_ocid != null ? 1 : 0
  compartment_id        = var.compartment_ocid
  display_name          = "GoldenGate No Active Replicats"
  is_enabled            = true
  metric_compartment_id = var.compartment_ocid
  namespace             = "oci_goldengate"
  severity              = "WARNING"
  message_format        = "ONS_OPTIMIZED"

  query = "ReplicatProcessCount[5m]{deploymentId = \"${oci_golden_gate_deployment.gg.id}\"}.max() < 1"
  body  = "No active GoldenGate Replicat processes detected.\nDeployment: ${var.goldengate_display_name}\nCheck if Replicats are running."

  pending_duration             = "PT10M"
  destinations                 = [var.notification_topic_ocid]
  repeat_notification_duration = "PT1H"
  freeform_tags                = var.freeform_tags
}
