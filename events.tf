# ============================================================================
# OCI Events - DMS and GoldenGate Lifecycle Notifications
# ============================================================================

resource "oci_events_rule" "dms_migration_events" {
  count          = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "dms-migration-lifecycle"
  description    = "DMS migration state changes: FAILED, NEEDS_ATTENTION, SUCCEEDED"
  is_enabled     = true

  condition = jsonencode({
    eventType = [
      "com.oraclecloud.databasemigration.migrationjob.migrationjob.begin",
      "com.oraclecloud.databasemigration.migrationjob.migrationjob.end",
      "com.oraclecloud.databasemigration.updatemigration",
    ]
    data = { compartmentId = [var.compartment_ocid] }
  })

  actions {
    actions {
      action_type = "ONS"
      is_enabled  = true
      topic_id    = var.notification_topic_ocid
      description = "Notify on DMS migration state change"
    }
  }
  freeform_tags = var.freeform_tags
}

resource "oci_events_rule" "dms_connection_events" {
  count          = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "dms-connection-lifecycle"
  description    = "DMS connection state changes"
  is_enabled     = true

  condition = jsonencode({
    eventType = [
      "com.oraclecloud.databasemigration.createconnection",
      "com.oraclecloud.databasemigration.updateconnection",
      "com.oraclecloud.databasemigration.deleteconnection",
    ]
    data = { compartmentId = [var.compartment_ocid] }
  })

  actions {
    actions {
      action_type = "ONS"
      is_enabled  = true
      topic_id    = var.notification_topic_ocid
      description = "Notify on DMS connection state change"
    }
  }
  freeform_tags = var.freeform_tags
}

resource "oci_events_rule" "gg_deployment_events" {
  count          = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "gg-deployment-lifecycle"
  description    = "GoldenGate deployment state changes"
  is_enabled     = true

  condition = jsonencode({
    eventType = [
      "com.oraclecloud.goldengate.updatedeployment",
      "com.oraclecloud.goldengate.changedeploymentcompartment",
    ]
    data = { compartmentId = [var.compartment_ocid] }
  })

  actions {
    actions {
      action_type = "ONS"
      is_enabled  = true
      topic_id    = var.notification_topic_ocid
      description = "Notify on GoldenGate deployment state change"
    }
  }
  freeform_tags = var.freeform_tags
}
