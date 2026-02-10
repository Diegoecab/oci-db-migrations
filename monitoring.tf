# ============================================================================
# OCI Monitoring - Enterprise-Grade Alarms
# Two-tier alerting: WARNING and CRITICAL thresholds
# ============================================================================

# --- DMS Lag (per ONLINE migration) ---
resource "oci_monitoring_alarm" "dms_lag_warn" {
  for_each                     = var.enable_monitoring ? local.online_migrations : {}
  compartment_id               = var.compartment_ocid
  display_name                 = "DMS Lag WARNING - ${each.key}"
  is_enabled                   = true
  metric_compartment_id        = var.compartment_ocid
  namespace                    = "oci_database_migration"
  severity                     = "WARNING"
  query                        = "MigrationLag[1m]{migrationId = \"${oci_database_migration_migration.migration[each.key].id}\"}.max() > ${var.lag_threshold_seconds}"
  body                         = "DMS lag for ${each.value.display_name} exceeded ${var.lag_threshold_seconds}s (WARNING).\nMigration: ${oci_database_migration_migration.migration[each.key].id}"
  destinations                 = [for d in [var.notification_topic_ocid] : d if d != null && d != ""]
  repeat_notification_duration = "PT1H"
  freeform_tags                = var.freeform_tags
}

resource "oci_monitoring_alarm" "dms_lag_crit" {
  for_each                     = var.enable_monitoring ? local.online_migrations : {}
  compartment_id               = var.compartment_ocid
  display_name                 = "DMS Lag CRITICAL - ${each.key}"
  is_enabled                   = true
  metric_compartment_id        = var.compartment_ocid
  namespace                    = "oci_database_migration"
  severity                     = "CRITICAL"
  query                        = "MigrationLag[1m]{migrationId = \"${oci_database_migration_migration.migration[each.key].id}\"}.max() > ${var.lag_critical_threshold_seconds}"
  body                         = "DMS lag for ${each.value.display_name} exceeded ${var.lag_critical_threshold_seconds}s (CRITICAL).\nMigration: ${oci_database_migration_migration.migration[each.key].id}\nImmediate attention required."
  destinations                 = [for d in [var.notification_topic_ocid] : d if d != null && d != ""]
  repeat_notification_duration = "PT15M"
  freeform_tags                = var.freeform_tags
}

# --- GoldenGate Deployment Health ---
resource "oci_monitoring_alarm" "gg_health" {
  count                        = var.enable_monitoring ? 1 : 0
  compartment_id               = var.compartment_ocid
  display_name                 = "GoldenGate Deployment Health CRITICAL"
  is_enabled                   = true
  metric_compartment_id        = var.compartment_ocid
  namespace                    = "oci_goldengate"
  severity                     = "CRITICAL"
  query                        = "DeploymentHealth[1m]{resourceId = \"${oci_golden_gate_deployment.gg.id}\"}.mean() < 1"
  body                         = "GoldenGate deployment ${var.goldengate_display_name} is unhealthy.\nID: ${oci_golden_gate_deployment.gg.id}"
  destinations                 = [for d in [var.notification_topic_ocid] : d if d != null && d != ""]
  repeat_notification_duration = "PT15M"
  freeform_tags                = var.freeform_tags
}

# --- GoldenGate Extract Lag ---
resource "oci_monitoring_alarm" "gg_extract_lag_warn" {
  count                        = var.enable_monitoring ? 1 : 0
  compartment_id               = var.compartment_ocid
  display_name                 = "GoldenGate Extract Lag WARNING"
  is_enabled                   = true
  metric_compartment_id        = var.compartment_ocid
  namespace                    = "oci_goldengate"
  severity                     = "WARNING"
  query                        = "ExtractLag[1m]{deploymentId = \"${oci_golden_gate_deployment.gg.id}\"}.max() > ${var.lag_threshold_seconds}"
  body                         = "GoldenGate extract lag exceeded ${var.lag_threshold_seconds}s."
  destinations                 = [for d in [var.notification_topic_ocid] : d if d != null && d != ""]
  repeat_notification_duration = "PT1H"
  freeform_tags                = var.freeform_tags
}

resource "oci_monitoring_alarm" "gg_extract_lag_crit" {
  count                        = var.enable_monitoring ? 1 : 0
  compartment_id               = var.compartment_ocid
  display_name                 = "GoldenGate Extract Lag CRITICAL"
  is_enabled                   = true
  metric_compartment_id        = var.compartment_ocid
  namespace                    = "oci_goldengate"
  severity                     = "CRITICAL"
  query                        = "ExtractLag[1m]{deploymentId = \"${oci_golden_gate_deployment.gg.id}\"}.max() > ${var.lag_critical_threshold_seconds}"
  body                         = "GoldenGate extract lag exceeded ${var.lag_critical_threshold_seconds}s. CRITICAL."
  destinations                 = [for d in [var.notification_topic_ocid] : d if d != null && d != ""]
  repeat_notification_duration = "PT15M"
  freeform_tags                = var.freeform_tags
}

# --- GoldenGate Replicat Lag ---
resource "oci_monitoring_alarm" "gg_replicat_lag_warn" {
  count                        = var.enable_monitoring ? 1 : 0
  compartment_id               = var.compartment_ocid
  display_name                 = "GoldenGate Replicat Lag WARNING"
  is_enabled                   = true
  metric_compartment_id        = var.compartment_ocid
  namespace                    = "oci_goldengate"
  severity                     = "WARNING"
  query                        = "ReplicatLag[1m]{deploymentId = \"${oci_golden_gate_deployment.gg.id}\"}.max() > ${var.lag_threshold_seconds}"
  body                         = "GoldenGate replicat lag exceeded ${var.lag_threshold_seconds}s."
  destinations                 = [for d in [var.notification_topic_ocid] : d if d != null && d != ""]
  repeat_notification_duration = "PT1H"
  freeform_tags                = var.freeform_tags
}

resource "oci_monitoring_alarm" "gg_replicat_lag_crit" {
  count                        = var.enable_monitoring ? 1 : 0
  compartment_id               = var.compartment_ocid
  display_name                 = "GoldenGate Replicat Lag CRITICAL"
  is_enabled                   = true
  metric_compartment_id        = var.compartment_ocid
  namespace                    = "oci_goldengate"
  severity                     = "CRITICAL"
  query                        = "ReplicatLag[1m]{deploymentId = \"${oci_golden_gate_deployment.gg.id}\"}.max() > ${var.lag_critical_threshold_seconds}"
  body                         = "GoldenGate replicat lag exceeded ${var.lag_critical_threshold_seconds}s. CRITICAL."
  destinations                 = [for d in [var.notification_topic_ocid] : d if d != null && d != ""]
  repeat_notification_duration = "PT15M"
  freeform_tags                = var.freeform_tags
}

# --- GoldenGate CPU ---
resource "oci_monitoring_alarm" "gg_cpu_warn" {
  count                        = var.enable_monitoring ? 1 : 0
  compartment_id               = var.compartment_ocid
  display_name                 = "GoldenGate CPU WARNING"
  is_enabled                   = true
  metric_compartment_id        = var.compartment_ocid
  namespace                    = "oci_goldengate"
  severity                     = "WARNING"
  query                        = "CpuUtilization[5m]{resourceId = \"${oci_golden_gate_deployment.gg.id}\"}.mean() > 80"
  body                         = "GoldenGate CPU above 80%. Consider scaling up."
  destinations                 = [for d in [var.notification_topic_ocid] : d if d != null && d != ""]
  repeat_notification_duration = "PT2H"
  freeform_tags                = var.freeform_tags
}

resource "oci_monitoring_alarm" "gg_cpu_crit" {
  count                        = var.enable_monitoring ? 1 : 0
  compartment_id               = var.compartment_ocid
  display_name                 = "GoldenGate CPU CRITICAL"
  is_enabled                   = true
  metric_compartment_id        = var.compartment_ocid
  namespace                    = "oci_goldengate"
  severity                     = "CRITICAL"
  query                        = "CpuUtilization[5m]{resourceId = \"${oci_golden_gate_deployment.gg.id}\"}.mean() > 95"
  body                         = "GoldenGate CPU above 95%. CRITICAL. Scale up immediately."
  destinations                 = [for d in [var.notification_topic_ocid] : d if d != null && d != ""]
  repeat_notification_duration = "PT30M"
  freeform_tags                = var.freeform_tags
}
