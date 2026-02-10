#!/bin/bash
# ============================================================================
# Configure DMS Advanced Settings
# Post-terraform helper for settings not supported by the Terraform provider.
# ============================================================================
set -euo pipefail

echo "============================================"
echo " DMS Advanced Settings Configuration"
echo "============================================"
echo ""
echo "The following settings must be configured in OCI Console"
echo "or via OCI CLI AFTER terraform apply:"
echo ""
echo "  1. Data Pump parallelism (recommended: 4-8 for large schemas)"
echo "  2. Data Pump compression (METADATA_ONLY or ALL)"
echo "  3. GoldenGate extract/replicat performance tuning"
echo "  4. Object Storage staging bucket assignment"
echo "  5. Tablespace remapping (if source/target differ)"
echo ""

if ! command -v oci &>/dev/null; then
    echo "[WARN] OCI CLI not found. Use OCI Console instead."
    echo ""
    echo "Console URL:"
    terraform output -json dms_migrations 2>/dev/null | jq -r 'to_entries[] | "  \(.key): \(.value.console_url)"' || echo "  Run terraform apply first."
    exit 0
fi

echo "Migrations:"
terraform output -json dms_migrations 2>/dev/null | jq -r 'to_entries[] | "  \(.key): \(.value.id)"' || { echo "  No migrations found."; exit 1; }

echo ""
echo "Open each migration in OCI Console to configure advanced settings."
echo "Documentation: https://docs.oracle.com/en-us/iaas/database-migration/"
