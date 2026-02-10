# ============================================================================
# Terraform and Provider Configuration
# ============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9.0"
    }
  }

  # Uncomment ONE backend for shared/remote state:
  # backend "s3" {
  #   bucket   = "tf-state-bucket"
  #   key      = "oci-migration/terraform.tfstate"
  #   region   = "us-east-1"
  #   encrypt  = true
  # }
  # backend "http" {
  #   address        = "https://objectstorage.<region>.oraclecloud.com/p/<par>/n/<ns>/b/<bucket>/o/terraform.tfstate"
  #   update_method  = "PUT"
  # }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}
