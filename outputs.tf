# ============================================================================
# Outputs
# ============================================================================

# --- DMS ---
output "dms_migrations" {
  description = "DMS migration details"
  value = {
    for k, m in oci_database_migration_migration.migration : k => {
      id           = m.id
      display_name = m.display_name
      type         = m.type
      source_conn  = m.source_database_connection_id
      target_conn  = m.target_database_connection_id
      console_url  = "https://cloud.oracle.com/database-migration/migrations/${m.id}?region=${var.region}"
    }
  }
}

output "dms_source_connections" {
  description = "DMS source connection IDs (one per source database)"
  value       = { for k, c in oci_database_migration_connection.source : k => c.id }
}

output "dms_target_connections" {
  description = "DMS target connection IDs (one per target database)"
  value       = { for k, c in oci_database_migration_connection.target : k => c.id }
}

# --- GoldenGate ---
output "gg_deployment" {
  description = "GoldenGate deployment details"
  value = {
    id             = oci_golden_gate_deployment.gg.id
    deployment_url = oci_golden_gate_deployment.gg.deployment_url
    state          = oci_golden_gate_deployment.gg.state
    subnet_id      = oci_golden_gate_deployment.gg.subnet_id
  }
}

output "gg_reverse_replication" {
  description = "GoldenGate reverse replication resources"
  value = {
    adb_registrations        = { for k, r in oci_golden_gate_database_registration.adb : k => r.id }
    ext_oracle_registrations = { for k, r in oci_golden_gate_database_registration.ext_oracle : k => r.id }
    adb_connections          = { for k, c in oci_golden_gate_connection.adb : k => c.id }
    ext_oracle_connections   = { for k, c in oci_golden_gate_connection.ext_oracle : k => c.id }
    adb_assignments          = { for k, a in oci_golden_gate_connection_assignment.adb : k => a.id }
    ext_oracle_assignments   = { for k, a in oci_golden_gate_connection_assignment.ext_oracle : k => a.id }
  }
}

output "gg_config_files" {
  description = "Generated GoldenGate parameter files for fallback migrations"
  value = {
    for k in setunion(keys(local_file.extract_params), keys(local_file.replicat_params)) : k => {
      extract_params  = try(local_file.extract_params[k].filename, null)
      replicat_params = try(local_file.replicat_params[k].filename, null)
    }
  }
}

# --- Network ---
output "migration_nsg_id" {
  description = "OCID of the auto-created migration NSG"
  value       = oci_core_network_security_group.migration_nsg.id
}

# --- Monitoring ---
output "monitoring" {
  description = "Monitoring alarm and event rule IDs"
  value = {
    # Alarms (from monitoring.tf)
    dms_health_alarms          = { for k, a in oci_monitoring_alarm.dms_health : k => a.id }
    dms_replication_lag_warn   = { for k, a in oci_monitoring_alarm.dms_replication_lag_warn : k => a.id }
    dms_replication_lag_crit   = { for k, a in oci_monitoring_alarm.dms_replication_lag_crit : k => a.id }
    gg_cpu_warn_alarm          = var.enable_monitoring && var.notification_topic_ocid != null ? oci_monitoring_alarm.gg_cpu_warn[0].id : null
    gg_cpu_critical_alarm      = var.enable_monitoring && var.notification_topic_ocid != null ? oci_monitoring_alarm.gg_cpu_critical[0].id : null
    gg_extract_lag_alarm       = var.enable_monitoring && var.notification_topic_ocid != null ? oci_monitoring_alarm.gg_extract_lag[0].id : null
    gg_replicat_lag_alarm      = var.enable_monitoring && var.notification_topic_ocid != null ? oci_monitoring_alarm.gg_replicat_lag[0].id : null

    # Event rules (from events.tf - mirrors DMS Console quickstart templates)
    event_rules = {
      job_status_changed = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? oci_events_rule.dms_job_status_changed[0].id : null
      job_succeeded      = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? oci_events_rule.dms_job_succeeded[0].id : null
      job_failed         = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? oci_events_rule.dms_job_failed[0].id : null
      job_waiting        = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? oci_events_rule.dms_job_waiting[0].id : null
      phase_completed    = var.enable_dms_event_notifications && var.notification_topic_ocid != null ? oci_events_rule.dms_phase_completed[0].id : null
    }
  }
}

# --- Secrets (sensitive) ---
output "secret_ocids" {
  description = "Vault secret OCIDs"
  sensitive   = true
  value = {
    source_db = { for k, s in oci_vault_secret.source_db_password : k => s.id }
    target_db = { for k, s in oci_vault_secret.target_db_password : k => s.id }
    gg_admin  = oci_vault_secret.gg_admin_password.id
  }
}

# --- Post-Apply Summary ---
output "next_steps" {
  description = "Post-deployment summary and next steps"
  value       = <<-EOT

    ================================================================
    DEPLOYMENT COMPLETE
    ================================================================

    MIGRATIONS:
    %{for k, m in oci_database_migration_migration.migration~}
      ${k}: ${m.display_name}
        ID: ${m.id}
        URL: https://cloud.oracle.com/database-migration/migrations/${m.id}?region=${var.region}
    %{endfor~}

    GOLDENGATE:
      URL: ${oci_golden_gate_deployment.gg.deployment_url}
      User: ${var.goldengate_admin_username}
      State: ${oci_golden_gate_deployment.gg.state}

    VALIDATION: ${var.auto_validate_migration ? "AUTO (check Console for results)" : "MANUAL required"}
    START: ${var.auto_start_migration ? "AUTO (after validation)" : "MANUAL required"}
    NOTIFICATIONS: ${var.notification_topic_ocid != null ? "ENABLED (5 event rules + 7 alarms)" : "DISABLED (set notification_topic_ocid)"}

    ================================================================
  EOT
}
