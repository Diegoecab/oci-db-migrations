# ============================================================================
# Variables - OCI Database Migration (DMS) + GoldenGate
# ============================================================================

# ----------------------------------------------------------------------------
# OCI Authentication
# ----------------------------------------------------------------------------
variable "tenancy_ocid" {
  description = "OCID of the OCI Tenancy"
  type        = string
}

variable "user_ocid" {
  description = "OCID of the OCI User"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the API Key"
  type        = string
}

variable "private_key_path" {
  description = "Path to the API private key file"
  type        = string
}

variable "region" {
  description = "OCI Region"
  type        = string
  default     = "us-ashburn-1"
}

variable "compartment_ocid" {
  description = "OCID of the Compartment for all resources"
  type        = string
}

# ----------------------------------------------------------------------------
# Network
# ----------------------------------------------------------------------------
variable "vcn_ocid" {
  description = "OCID of the VCN"
  type        = string
}

variable "private_subnet_ocid" {
  description = "OCID of the private subnet for DMS, GoldenGate, and ADB private endpoint"
  type        = string
}

variable "nsg_ids" {
  description = "List of NSG OCIDs to attach to DMS connections and GoldenGate deployment"
  type        = list(string)
  default     = []
}

# ----------------------------------------------------------------------------
# Vault and Encryption
# ----------------------------------------------------------------------------
variable "vault_ocid" {
  description = "OCID of the OCI Vault for storing secrets"
  type        = string
}

variable "vault_key_ocid" {
  description = "OCID of the Master Encryption Key in the Vault"
  type        = string
}

# ----------------------------------------------------------------------------
# Source Databases
#
# Define each unique source database ONCE. Migrations reference them by key.
# This avoids duplicating connection details when multiple schemas from the
# same source go to the same or different targets.
# ----------------------------------------------------------------------------
variable "source_databases" {
  description = <<-EOT
    Map of source databases. Each key is a unique identifier referenced by migrations.
    Supports multiple distinct source databases (different hosts/services).
  EOT

  type = map(object({
    display_name = string
    host         = string # IP or hostname for connection string
    hostname     = string # Resolvable FQDN (required by GoldenGate)
    port         = optional(number, 1521)
    service_name = string
    username     = string
    password     = string

    # SSH tunnel (optional, for AWS connectivity)
    ssh_host = optional(string, null)
    ssh_user = optional(string, null)
    ssh_key  = optional(string, null)

    # GoldenGate credentials on this source (for reverse replication)
    gg_username = optional(string, "GGADMIN")
    gg_password = optional(string, "")

    cdb_key = optional(string) # key para buscar en var.source_container_databases
    is_pdb  = optional(bool, true)
  }))
}

variable "source_container_databases" {
  description = "CDB (Container/Root) connections for multitenant Oracle sources"
  type = map(object({
    display_name = string
    host         = string
    port         = optional(number, 1521)
    service_name = string # e.g., "CDB$ROOT"
    username     = string # SYS or CDB admin (SYSDBA)
    password     = string
  }))
  default = {}
}

# ----------------------------------------------------------------------------
# Target Databases (ADB)
#
# Define each unique target ADB ONCE. Migrations reference them by key.
# All ADBs use private endpoints for secure connectivity.
# ----------------------------------------------------------------------------
variable "target_databases" {
  description = <<-EOT
    Map of target Autonomous Databases. Each key is a unique identifier.
    ADB private endpoint configuration is managed here.
  EOT

  type = map(object({
    display_name = string
    adb_ocid     = string
    username     = optional(string, "ADMIN")
    password     = string

    # ADB Wallet (for TLS connections)
    wallet_secret_id = optional(string, null)

    # GoldenGate credentials on this ADB (for reverse replication)
    gg_username = optional(string, "GGADMIN")
    gg_password = optional(string, "")
  }))
}

# ----------------------------------------------------------------------------
# Migrations
#
# Each migration references a source_db_key and target_db_key defined above,
# plus its own schema list. This allows N migrations across M sources and
# P targets with no duplication.
# ----------------------------------------------------------------------------
variable "migrations" {
  description = "DMS migrations definitions"
  type = map(object({
    display_name   = string
    migration_type = string


    database_combination = string

    source_db_key = string
    target_db_key = string

    include_allow_objects = optional(list(string), [])
    exclude_objects       = optional(list(string), [])

    # PDB online support
    source_cdb_key = optional(string)
    migration_mode = optional(string) # "ONLINE"/"OFFLINE"

    enable_reverse_replication = optional(bool, false)
    auto_start_gg_processes    = optional(bool) # si no viene, cae al default global gg_auto_start_processes
    auto_validate              = optional(bool) # si no viene, cae al default global
    auto_start                 = optional(bool) # si no viene, cae al default global
  }))
}



# ----------------------------------------------------------------------------
# GoldenGate Deployment (shared, private subnet)
# ----------------------------------------------------------------------------
variable "goldengate_display_name" {
  description = "Display name for the GoldenGate Deployment"
  type        = string
  default     = "oci-gg-deployment"
}

variable "goldengate_admin_username" {
  description = "Admin username for GoldenGate"
  type        = string
  default     = "oggadmin"
}

variable "goldengate_admin_password" {
  description = "Admin password for GoldenGate"
  type        = string
  sensitive   = true
}

variable "goldengate_license_model" {
  description = "BRING_YOUR_OWN_LICENSE or LICENSE_INCLUDED"
  type        = string
  default     = "BRING_YOUR_OWN_LICENSE"
}

variable "goldengate_cpu_core_count" {
  description = "Number of OCPUs for GoldenGate deployment"
  type        = number
  default     = 1
}

variable "goldengate_is_auto_scaling_enabled" {
  description = "Enable auto-scaling for GoldenGate"
  type        = bool
  default     = false
}

variable "goldengate_deployment_type" {
  description = "GoldenGate deployment type"
  type        = string
  default     = "DATABASE_ORACLE"
}

# ----------------------------------------------------------------------------
# GoldenGate Extract / Replicat
# ----------------------------------------------------------------------------
variable "extract_config" {
  description = "GoldenGate Extract process configuration"
  type = object({
    extract_name  = string
    extract_type  = string
    begin_time    = string
    trail_name    = string
    trail_size_mb = number
  })
  default = {
    extract_name  = "EXTADB"
    extract_type  = "INTEGRATED"
    begin_time    = "NOW"
    trail_name    = "EA"
    trail_size_mb = 500
  }
}

variable "replicat_config" {
  description = "GoldenGate Replicat process configuration"
  type = object({
    replicat_name   = string
    replicat_type   = string
    map_parallelism = number
    bulk_applies    = bool
  })
  default = {
    replicat_name   = "REPAWS"
    replicat_type   = "PARALLEL"
    map_parallelism = 4
    bulk_applies    = true
  }
}

variable "gg_schemas_to_replicate" {
  description = "Schemas to replicate with GoldenGate (reverse replication)"
  type        = list(string)
  default     = []
}

variable "gg_exclude_tables" {
  description = "Table patterns to exclude from GoldenGate replication"
  type        = list(string)
  default     = ["*.TMP_%", "*.TEMP_%", "*.LOG_%"]
}

variable "gg_process_rerun_token" {
  description = "Change this value to force re-running GG process creation (null_resource)."
  type        = string
  default     = ""
}


# ----------------------------------------------------------------------------
# Object Storage
# ----------------------------------------------------------------------------
variable "object_storage_bucket" {
  description = "Object Storage bucket for Data Pump staging (null to skip)"
  type        = string
  default     = null
}

variable "object_storage_namespace" {
  description = "Object Storage namespace"
  type        = string
  default     = ""
}


# ----------------------------------------------------------------------------
# Data Pump / Object Storage (to match Console "Create migration")
# ----------------------------------------------------------------------------
variable "source_export_directory_object_name" {
  description = "Source DB directory object name used by Data Pump export (e.g., DATA_PUMP_DIR)"
  type        = string
  default     = "DATA_PUMP_DIR"
}

variable "source_export_directory_object_path" {
  description = "Absolute path on source DB server for the export directory object (matches Console field)"
  type        = string
  default     = null
}

variable "source_db_ssl_wallet_path" {
  description = "Source DB server filesystem SSL wallet path for HTTPS upload to Object Storage (Console field)"
  type        = string
  default     = "/u01/app/oracle/wallet"
}

variable "target_db_ssl_wallet_path" {
  description = "Target side SSL wallet path (used by provider for dump transfer; keep default if not needed)"
  type        = string
  default     = "/u01/app/oracle/wallet"
}

# ----------------------------------------------------------------------------
# DMS Execution Control (global defaults, overridable per migration)
# ----------------------------------------------------------------------------
variable "auto_validate_migration" {
  description = "Auto-validate migrations after creation (requires OCI CLI)"
  type        = bool
  default     = true
}

variable "auto_start_migration" {
  description = "Auto-start migrations after successful validation (requires OCI CLI)"
  type        = bool
  default     = false
}

variable "force_rerun_validate_start" {
  description = "Change this value (e.g. increment) to force re-execution of validate/start on next apply"
  type        = string
  default     = "1"
}

variable "gg_auto_start_processes" {
  description = <<-EOT
    Start Extract/Replicat immediately after creation.

    false (default, RECOMMENDED): Creates processes in STOPPED state.
      Post-cutover, run gg_activate_fallback.sh to re-position SCN
      to current time and start both processes. This avoids accumulating
      stale redo logs between Terraform apply and actual cutover.

    true: Start immediately (for testing or when cutover is imminent).
  EOT
  type    = bool
  default = false
}

# ----------------------------------------------------------------------------
# Pre-Cutover Validation
# ----------------------------------------------------------------------------
variable "pre_cutover_validation_enabled" {
  description = "Run automated pre-cutover validation checks before switchover"
  type        = bool
  default     = true
}

variable "pre_cutover_max_lag_seconds" {
  description = "Maximum acceptable lag (seconds) for pre-cutover validation to pass"
  type        = number
  default     = 30
}

# ----------------------------------------------------------------------------
# Monitoring and Notifications (Enterprise)
# ----------------------------------------------------------------------------
variable "enable_monitoring" {
  description = "Enable OCI Monitoring alarms"
  type        = bool
  default     = true
}

variable "enable_dms_event_notifications" {
  description = "Enable OCI Events rules for DMS/GG state change notifications"
  type        = bool
  default     = true
}

variable "lag_threshold_seconds" {
  description = "Lag threshold (seconds) for WARNING alarms"
  type        = number
  default     = 60
}

variable "lag_critical_threshold_seconds" {
  description = "Lag threshold (seconds) for CRITICAL alarms"
  type        = number
  default     = 300
}

variable "notification_topic_ocid" {
  description = "OCID of the Notification Topic (null to disable)"
  type        = string
  default     = null
}

variable "enable_log_analytics" {
  description = "Enable OCI Logging for DMS and GoldenGate audit/operational logs"
  type        = bool
  default     = false
}

variable "log_group_ocid" {
  description = "OCID of the OCI Log Group for DMS/GG logs (required if enable_log_analytics = true)"
  type        = string
  default     = null
}

variable "gg_exclude_users" {
  description = <<-EOT
    List of database users to TRANLOGOPTIONS EXCLUDEUSER in fallback Extract.
    Prevents replication loops when running fallback Extract in parallel
    with DMS forward replication. DMS applies changes as GGADMIN on target,
    so excluding GGADMIN prevents the fallback Extract from capturing
    those DMS-applied changes and sending them back to source.
    Set to [] to disable EXCLUDEUSER (not recommended during parallel run).
  EOT
  type    = list(string)
  default = ["GGADMIN"]
}

variable "gg_auto_start_processes" {
  description = <<-EOT
    Start Extract/Replicat immediately after creation.
    
    false (default, RECOMMENDED): Creates processes in STOPPED state.
      Post-cutover, run gg_activate_fallback.sh to re-position SCN
      to current time and start both processes. This avoids accumulating
      stale redo logs between Terraform apply and actual cutover.
    
    true: Start immediately (for testing or when cutover is imminent).
  EOT
  type    = bool
  default = false
}

variable "gg_checkpoint_table" {
  description = <<-EOT
    Checkpoint table for Replicat recovery tracking.
    Uses GGADMIN schema to avoid polluting business/app schemas.
    Auto-created on source DB via REST API before Replicat creation.
  EOT
  type    = string
  default = "GGADMIN.GG_CHECKPOINT"
}

variable "gg_auto_create_checkpoint" {
  description = <<-EOT
    Automatically create the checkpoint table on source DB before Replicat.
    Requires Python 3.8+ (installed via miniconda if needed) and network
    access from Terraform host to source DB.
    If false, you must create the table manually via AdminClient:
      DBLOGIN USERIDALIAS <alias> DOMAIN OracleGoldenGate
      ADD CHECKPOINTTABLE GGADMIN.GG_CHECKPOINT
  EOT
  type    = bool
  default = true
}

variable "oracle_home" {
  description = <<-EOT
    Path to ORACLE_HOME on the Terraform host (for oracledb thick mode).
    Required only if the source DB uses Native Network Encryption (NNE).
    Example: "/u01/app/oracle/product/19c/dbhome_1"
    Leave empty to use thin mode (no Oracle Client needed).
  EOT
  type    = string
  default = ""
}

# ----------------------------------------------------------------------------
# Tags
# ----------------------------------------------------------------------------
variable "freeform_tags" {
  description = "Freeform tags for all resources"
  type        = map(string)
  default = {
    "Project"   = "database-migration"
    "ManagedBy" = "terraform"
  }
}

variable "defined_tags" {
  description = "Defined tags for all resources"
  type        = map(string)
  default     = {}
}
