#!/bin/bash
# ============================================================================
# TERRAFORM STATE IMPORT SCRIPT (V2 - Safe & Idempotent)
# ============================================================================

set -e

echo "============================================================"
echo " Importing existing resources into Terraform state"
echo "============================================================"

# Función para importar solo si el recurso NO está en el estado
smart_import() {
    local RESOURCE_ADDR=$1
    local OCID=$2
    
    if terraform state list | grep -q "^${RESOURCE_ADDR}$"; then
        echo "  [SKIP] $RESOURCE_ADDR already in state."
    else
        echo "  [IMPORTING] $RESOURCE_ADDR..."
        terraform import "$RESOURCE_ADDR" "$OCID" || echo "  [WARN] Failed to import $RESOURCE_ADDR"
    fi
}

# -------------------------------------------------------
# 1. VAULT SECRETS (Sincronizados con tus logs)
# -------------------------------------------------------
echo "[1/12] Vault Secrets..."

smart_import 'oci_vault_secret.source_db_password["aws_oracle_prod"]' "ocid1.vaultsecret.oc1.iad.amaaaaaarsnyneyab5qaolopkxwokasfumjr2tzigm5miqmm42gug57y7ota"
smart_import 'oci_vault_secret.target_db_password["adb_prod"]' "ocid1.vaultsecret.oc1.iad.amaaaaaarsnyneyagm3vo633xwrfm3nxa47skvvmtdrmuezsgikb65zrre7a"
smart_import 'oci_vault_secret.gg_admin_password' "ocid1.vaultsecret.oc1.iad.amaaaaaarsnyneyacfj75bobky4bznjnohpi3nnuhy2gjewyorjfkijwv5pq"
smart_import 'oci_vault_secret.gg_adb_password["adb_prod"]' "ocid1.vaultsecret.oc1.iad.amaaaaaarsnyneyauriy7oayjsccxzmefffyb2da7l4calz3okhgqxw24thq"
smart_import 'oci_vault_secret.gg_source_password["aws_oracle_prod"]' "ocid1.vaultsecret.oc1.iad.amaaaaaarsnyneyaiphtgcn2ngby5r5mnb2ranfgu4zsft5zdetiebeykkcq"

# -------------------------------------------------------
# 2. NETWORK (NSG)
# -------------------------------------------------------
echo "[2/12] Network Security Group..."
smart_import 'oci_core_network_security_group.migration_nsg' "ocid1.networksecuritygroup.oc1.iad.aaaaaaaad7snlpjfliurk3gwe44qvmqxyt3uygk6fwlbgipay5efdzcya3xq"

# -------------------------------------------------------
# 3. GOLDENGATE DEPLOYMENT (ID corregido según tu log)
# -------------------------------------------------------
echo "[3/12] GoldenGate Deployment..."
smart_import 'oci_golden_gate_deployment.gg' "ocid1.goldengatedeployment.oc1.iad.amaaaaaarsnyneyawanghexbsszqszvaf4dfipmy2xh7hnbjw7gkl4phbk2a"

# -------------------------------------------------------
# 4. GOLDENGATE REGISTRATIONS
# -------------------------------------------------------
echo "[4/12] GoldenGate Database Registrations..."
smart_import 'oci_golden_gate_database_registration.adb["adb_prod"]' "ocid1.goldengatedatabaseregistration.oc1.iad.amaaaaaarsnyneyarlcqdkq2lbb5yub6dhfiktvjlyjop2wpm7da4gmmg4eq"
smart_import 'oci_golden_gate_database_registration.ext_oracle["aws_oracle_prod"]' "ocid1.goldengatedatabaseregistration.oc1.iad.amaaaaaarsnyneyat7fkq537dlcpebl5l7pcw46hqjciepcaxmnbwpg2pfjq"

# -------------------------------------------------------
# 5. GOLDENGATE CONNECTIONS (IDs corregidos - No son los mismos que Registration)
# -------------------------------------------------------
echo "[5/12] GoldenGate Connections..."
# ID de la conexión ADB según tu log: ...wetrv44lwr5x3nw6q6xghqzvhx5v5rgsnsuujilbcnka
smart_import 'oci_golden_gate_connection.adb["adb_prod"]' "ocid1.goldengateconnection.oc1.iad.amaaaaaarsnyneyawetrv44lwr5x3nw6q6xghqzvhx5v5rgsnsuujilbcnka"

# ID de la conexión Ext Oracle según tu log: ...eoi5tim246xv3xm3givihejp356ny3gtz5geqwq7xtpa
smart_import 'oci_golden_gate_connection.ext_oracle["aws_oracle_prod"]' "ocid1.goldengateconnection.oc1.iad.amaaaaaarsnyneyaeoi5tim246xv3xm3givihejp356ny3gtz5geqwq7xtpa"

# -------------------------------------------------------
# 6. DMS CONNECTIONS
# -------------------------------------------------------
echo "[6/12] DMS Connections..."
smart_import 'oci_database_migration_connection.source["aws_oracle_prod"]' "ocid1.odmsconnection.oc1.iad.amaaaaaarsnyneyaxdph2amtu4w5ziyko2m3c6gzrnoxg5ta5npigee6kciq"
smart_import 'oci_database_migration_connection.target["adb_prod"]' "ocid1.odmsconnection.oc1.iad.amaaaaaarsnyneya32fy4r6sk7tta6whhtw4dq5rkjqtl2mcogow6ghy7rqq"

# -------------------------------------------------------
# 7. DMS MIGRATIONS
# -------------------------------------------------------
echo "[7/12] DMS Migrations..."
smart_import 'oci_database_migration_migration.migration["hr_migration"]' "ocid1.odmsmigration.oc1.iad.amaaaaaarsnyneyatwwd5matvhff5r5jda6vpl6tqxpkz4f5vqpvtu42h4rq"
smart_import 'oci_database_migration_migration.migration["sales_migration"]' "ocid1.odmsmigration.oc1.iad.amaaaaaarsnyneyay477jlk4tuqzx4iayc5qq72j62qjigptstlshgfsviya"

echo ""
echo "============================================================"
echo " Import safe-run complete!"
echo " Now run: terraform plan"
echo "============================================================"


terraform untaint 'oci_golden_gate_connection.adb["adb_prod"]'
terraform untaint 'oci_golden_gate_connection.ext_oracle["aws_oracle_prod"]'

