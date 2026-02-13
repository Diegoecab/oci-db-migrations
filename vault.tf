# ============================================================================
# OCI Vault - Secrets Management
# ============================================================================

# Source DB passwords (one per source database)
resource "oci_vault_secret" "source_db_password" {
  for_each       = var.source_databases
  compartment_id = var.compartment_ocid
  vault_id       = var.vault_ocid
  key_id         = var.vault_key_ocid
  secret_name    = "dms-source-p1-${each.key}"
  description    = "Source DB password: ${each.value.display_name}"
  secret_content {
    content_type = "BASE64"
    content      = base64encode(each.value.password)
  }
  freeform_tags = merge(var.freeform_tags, { "Database" = each.key, "Role" = "Source" })
}

# Target ADB passwords (one per target database)
resource "oci_vault_secret" "target_db_password" {
  for_each       = var.target_databases
  compartment_id = var.compartment_ocid
  vault_id       = var.vault_ocid
  key_id         = var.vault_key_ocid
  secret_name    = "dms-target-p1-${each.key}"
  description    = "Target ADB password: ${each.value.display_name}"
  secret_content {
    content_type = "BASE64"
    content      = base64encode(each.value.password)
  }
   lifecycle {
    ignore_changes = [secret_content]
    # If secret already exists, import it instead of recreating
  }
  freeform_tags = merge(var.freeform_tags, { "Database" = each.key, "Role" = "Target" })
}

# GoldenGate admin password (shared)
resource "oci_vault_secret" "gg_admin_password" {
  compartment_id = var.compartment_ocid
  vault_id       = var.vault_ocid
  key_id         = var.vault_key_ocid
  secret_name    = "gg-admin-p1"
  description    = "GoldenGate deployment admin password"
  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.goldengate_admin_password)
  }
   lifecycle {
    ignore_changes = [secret_content]
    # If secret already exists, import it instead of recreating
  }
  freeform_tags = merge(var.freeform_tags, { "Role" = "GoldenGateAdmin" })
}

# GG password on ADB (per target DB with GG enabled)
resource "oci_vault_secret" "gg_adb_password" {
  for_each = {
    for k, v in var.target_databases : k => v if v.gg_password != ""
  }
  compartment_id = var.compartment_ocid
  vault_id       = var.vault_ocid
  key_id         = var.vault_key_ocid
  secret_name    = "gg-adb-p1-${each.key}"
  description    = "GG password on ADB: ${each.value.display_name}"
  secret_content {
    content_type = "BASE64"
    content      = base64encode(each.value.gg_password)
  }
   lifecycle {
    ignore_changes = [secret_content]
    # If secret already exists, import it instead of recreating
  }
  freeform_tags = merge(var.freeform_tags, { "Database" = each.key, "Role" = "GoldenGateADB" })
}

# GG password on external Oracle (per source DB with GG enabled)
resource "oci_vault_secret" "gg_source_password" {
  for_each = {
    for k, v in var.source_databases : k => v if v.gg_password != ""
  }
  compartment_id = var.compartment_ocid
  vault_id       = var.vault_ocid
  key_id         = var.vault_key_ocid
  secret_name    = "gg-extoracle-p1-${each.key}"
  description    = "GG password on external Oracle: ${each.value.display_name}"
  secret_content {
    content_type = "BASE64"
    content      = base64encode(each.value.gg_password)
  }
   lifecycle {
    ignore_changes = [secret_content]
    # If secret already exists, import it instead of recreating
  }
  freeform_tags = merge(var.freeform_tags, { "Database" = each.key, "Role" = "GoldenGateExtOracle" })
}
