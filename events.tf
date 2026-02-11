# ============================================================================
# OCI Events - Mirrors DMS Console "Quickstart" Notification Templates
# ============================================================================
#
# These 5 event rules replicate EXACTLY the templates shown in the DMS
# Console under Migration > Monitoring > Notifications > Quickstart:
#
#   1. Evaluation or Migration job status has changed
#   2. Evaluation or Migration job completed successfully
#   3. Evaluation or Migration job failed to complete
#   4. Migration job went into a waiting state
#   5. A phase completed for an Evaluation or Migration job
#
# Template #6 ("Replication latency exceeds 5 seconds") is a METRIC alarm,
# not an event rule. It is defined in monitoring.tf.
#
# PREREQUISITE: ONS subscription must be in ACTIVE state (confirmed).
#   oci ons subscription list --compartment-id $COMPARTMENT_ID \
#     --topic-id $TOPIC_OCID \
#     --query 'data[].{email:endpoint, state:"lifecycle-state"}' \
#     --output table
# ============================================================================

# --- Template 1: Evaluation or Migration job status has changed ---
resource "oci_events_rule" "dms_job_status_changed" {
  count          = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "dms-job-status-changed"
  description    = "Evaluation or Migration job status has changed"
  is_enabled     = true

  condition = jsonencode({
    eventType = [
      "com.oraclecloud.databasemigration.startmigration.end",
      "com.oraclecloud.databasemigration.evaluatemigration.end",
      "com.oraclecloud.databasemigration.abortmigration.end",
      "com.oraclecloud.databasemigration.resumemigration.end",
    ]
  })

  actions {
    actions {
      action_type = "ONS"
      is_enabled  = true
      topic_id    = var.notification_topic_ocid
      description = "Notify when job status changes"
    }
  }
  freeform_tags = var.freeform_tags
}

# --- Template 2: Evaluation or Migration job completed successfully ---
resource "oci_events_rule" "dms_job_succeeded" {
  count          = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "dms-job-succeeded"
  description    = "Evaluation or Migration job completed successfully"
  is_enabled     = true

  condition = jsonencode({
    eventType = [
      "com.oraclecloud.databasemigration.startmigration.end",
      "com.oraclecloud.databasemigration.evaluatemigration.end",
    ]
    data = {
      additionalDetails = {
        jobStatus = ["SUCCEEDED"]
      }
    }
  })

  actions {
    actions {
      action_type = "ONS"
      is_enabled  = true
      topic_id    = var.notification_topic_ocid
      description = "Notify when job completes successfully"
    }
  }
  freeform_tags = var.freeform_tags
}

# --- Template 3: Evaluation or Migration job failed to complete ---
resource "oci_events_rule" "dms_job_failed" {
  count          = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "dms-job-failed"
  description    = "Evaluation or Migration job failed to complete"
  is_enabled     = true

  condition = jsonencode({
    eventType = [
      "com.oraclecloud.databasemigration.startmigration.end",
      "com.oraclecloud.databasemigration.evaluatemigration.end",
    ]
    data = {
      additionalDetails = {
        jobStatus = ["FAILED"]
      }
    }
  })

  actions {
    actions {
      action_type = "ONS"
      is_enabled  = true
      topic_id    = var.notification_topic_ocid
      description = "Notify when job fails"
    }
  }
  freeform_tags = var.freeform_tags
}

# --- Template 4: Migration job went into a waiting state ---
resource "oci_events_rule" "dms_job_waiting" {
  count          = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "dms-job-waiting"
  description    = "Migration job went into a waiting state"
  is_enabled     = true

  condition = jsonencode({
    eventType = [
      "com.oraclecloud.databasemigration.startmigration.end",
    ]
    data = {
      additionalDetails = {
        jobStatus = ["WAITING"]
      }
    }
  })

  actions {
    actions {
      action_type = "ONS"
      is_enabled  = true
      topic_id    = var.notification_topic_ocid
      description = "Notify when job enters waiting state"
    }
  }
  freeform_tags = var.freeform_tags
}

# --- Template 5: A phase completed for an Evaluation or Migration job ---
resource "oci_events_rule" "dms_phase_completed" {
  count          = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "dms-phase-completed"
  description    = "A phase completed for an Evaluation or Migration job"
  is_enabled     = true

  condition = jsonencode({
    eventType = [
      "com.oraclecloud.databasemigration.startmigration.end",
      "com.oraclecloud.databasemigration.evaluatemigration.end",
    ]
    data = {
      additionalDetails = {
        phaseStatus = ["COMPLETED"]
      }
    }
  })

  actions {
    actions {
      action_type = "ONS"
      is_enabled  = true
      topic_id    = var.notification_topic_ocid
      description = "Notify when a migration phase completes"
    }
  }
  freeform_tags = var.freeform_tags
}
