# ============================================================================
# Data Sources and Derived Locals
# ============================================================================

data "oci_identity_tenancy" "tenancy" {
  tenancy_id = var.tenancy_ocid
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_vcn" "vcn" {
  vcn_id = var.vcn_ocid
}

data "oci_core_subnet" "private_subnet" {
  subnet_id = var.private_subnet_ocid
}

data "oci_database_autonomous_database" "target_adb" {
  for_each               = var.target_databases
  autonomous_database_id = each.value.adb_ocid
}

data "oci_kms_vault" "vault" {
  vault_id = var.vault_ocid
}

data "oci_kms_key" "master_key" {
  key_id              = var.vault_key_ocid
  management_endpoint = data.oci_kms_vault.vault.management_endpoint
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_ocid
}

# ----------------------------------------------------------------------------
# Derived Locals
# ----------------------------------------------------------------------------
locals {
  # Object Storage namespace (auto-detect or user-provided)
  os_namespace = var.object_storage_namespace != "" ? var.object_storage_namespace : data.oci_objectstorage_namespace.ns.namespace

  # Enrich each migration with resolved source/target details
  enriched_migrations = {
    for k, m in var.migrations : k => merge(m, {
      source = var.source_databases[m.source_db_key]
      target = var.target_databases[m.target_db_key]
    })
  }

  # Migrations with reverse replication enabled
  gg_migrations = { for k, m in local.enriched_migrations : k => m if try(m.enable_reverse_replication, false) }


  # ONLINE migrations (for lag monitoring)
  online_migrations = {
    for k, m in local.enriched_migrations : k => m if m.migration_type == "ONLINE"
  }

  # Per-migration auto-validate (migration-level override or global default)
  auto_validate = { for k, m in var.migrations : k => coalesce(try(m.auto_validate, null), var.auto_validate_migration) }


  # Per-migration auto-start (migration-level override or global default)
  auto_start = { for k, m in var.migrations : k => coalesce(try(m.auto_start, null), var.auto_start_migration) }

  # Per-migration auto-start GG processes (migration-level override or global default)
  auto_start_gg = { for k, m in var.migrations : k => coalesce(try(m.auto_start_gg_processes, null), var.gg_auto_start_processes) }

}
