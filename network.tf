# network.tf

# ============================================================================
# Network Security - NSG for DMS and GoldenGate Private Traffic
# ============================================================================


resource "oci_core_network_security_group_security_rule" "egress_oracle_services" {
  network_security_group_id = oci_core_network_security_group.migration_nsg.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}


resource "oci_core_network_security_group" "migration_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_ocid
  display_name   = "migration-nsg"
  freeform_tags  = var.freeform_tags
}

# Ingress: Oracle DB port from within VCN
resource "oci_core_network_security_group_security_rule" "ingress_oracle_db" {
  network_security_group_id = oci_core_network_security_group.migration_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = data.oci_core_vcn.vcn.cidr_block
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 1521
      max = 1522
    }
  }
}

# Ingress: GoldenGate HTTPS management from within VCN
resource "oci_core_network_security_group_security_rule" "ingress_gg_https" {
  network_security_group_id = oci_core_network_security_group.migration_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = data.oci_core_vcn.vcn.cidr_block
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# Egress: All traffic to VCN (DMS/GG to databases)
resource "oci_core_network_security_group_security_rule" "egress_all_vcn" {
  network_security_group_id = oci_core_network_security_group.migration_nsg.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = data.oci_core_vcn.vcn.cidr_block
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}


# Resolved NSG list: user-provided + auto-created
locals {
  all_nsg_ids = concat(var.nsg_ids, [oci_core_network_security_group.migration_nsg.id])
}

