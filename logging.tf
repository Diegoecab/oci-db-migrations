# ============================================================================
# OCI Logging - DMS and GoldenGate Operational/Audit Logs
# ============================================================================

resource "oci_logging_log" "dms_operational" {
  count = var.enable_log_analytics && var.log_group_ocid != null ? 1 : 0

  display_name = "dms-operational-log"
  log_group_id = var.log_group_ocid
  log_type     = "SERVICE"
  is_enabled   = true

  configuration {
    compartment_id = var.compartment_ocid
    source {
      category    = "all"
      resource    = var.compartment_ocid
      service     = "database-migration"
      source_type = "OCISERVICE"
    }
  }

  retention_duration = 90
  freeform_tags      = var.freeform_tags
}

resource "oci_logging_log" "gg_operational" {
  count = var.enable_log_analytics && var.log_group_ocid != null ? 1 : 0

  display_name = "gg-operational-log"
  log_group_id = var.log_group_ocid
  log_type     = "SERVICE"
  is_enabled   = true

  configuration {
    compartment_id = var.compartment_ocid
    source {
      category    = "all"
      resource    = oci_golden_gate_deployment.gg.id
      service     = "goldengate"
      source_type = "OCISERVICE"
    }
  }

  retention_duration = 90
  freeform_tags      = var.freeform_tags
}
