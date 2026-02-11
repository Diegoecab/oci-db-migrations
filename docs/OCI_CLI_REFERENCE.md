# OCI CLI Reference — Database Migration Operations

This document provides the OCI CLI equivalent commands for every operation automated by this Terraform package. Use these for manual execution, debugging, or when Terraform is not available.

> All commands assume OCI CLI is configured (`oci setup config`) and `jq` is installed.

---

## Table of Contents

1. [Environment Variables](#1-environment-variables)
2. [Vault and Secrets](#2-vault-and-secrets)
3. [DMS Connections](#3-dms-connections)
4. [GoldenGate Deployment](#4-goldengate-deployment)
5. [GoldenGate Connections and Assignments](#5-goldengate-connections-and-assignments)
6. [DMS Migrations](#6-dms-migrations)
7. [Migration Operations (Validate, Start, Monitor, Switchover)](#7-migration-operations)
8. [Monitoring and Notifications](#8-monitoring-and-notifications)
9. [Troubleshooting Commands](#9-troubleshooting-commands)

---

## 1. Environment Variables

Set these once per session to simplify subsequent commands:

```bash
export COMPARTMENT_ID="ocid1.compartment.oc1..xxx"
export VAULT_ID="ocid1.vault.oc1.iad.xxx"
export KEY_ID="ocid1.key.oc1.iad.xxx"
export SUBNET_ID="ocid1.subnet.oc1.iad.xxx"
export REGION="us-ashburn-1"
export ADB_ID="ocid1.autonomousdatabase.oc1.iad.xxx"
export BUCKET_NAME="migration-dms-bucket"
export TOPIC_ID="ocid1.onstopic.oc1.iad.xxx"
```

---

## 2. Vault and Secrets

### Create a Secret

```bash
oci vault secret create-base64 \
  --compartment-id $COMPARTMENT_ID \
  --vault-id $VAULT_ID \
  --key-id $KEY_ID \
  --secret-name "dms-source-password" \
  --secret-content-content "$(echo -n 'MyPassword123!' | base64)"
```

### List Secrets

```bash
oci vault secret list \
  --compartment-id $COMPARTMENT_ID \
  --vault-id $VAULT_ID \
  --query 'data[].{"name":"secret-name", id:id, state:"lifecycle-state"}' \
  --output table
```

---

## 3. DMS Connections

### Create Source Connection

```bash
oci database-migration connection create \
  --compartment-id $COMPARTMENT_ID \
  --display-name "src-aws-oracle-prod" \
  --connection-type ORACLE \
  --technology-type ORACLE_DATABASE \
  --username "GGADMIN" \
  --password "MyPassword123!" \
  --replication-username "GGADMIN" \
  --replication-password "MyPassword123!" \
  --connection-string '(description=(address=(protocol=tcp)(port=1521)(host=10.0.1.48))(connect_data=(service_name=MY_PDB.example.com)))' \
  --vault-id $VAULT_ID \
  --key-id $KEY_ID \
  --subnet-id $SUBNET_ID \
  --wait-for-state ACTIVE \
  --max-wait-seconds 600
```

### Create Target Connection (ADB)

```bash
oci database-migration connection create \
  --compartment-id $COMPARTMENT_ID \
  --display-name "tgt-adb-prod" \
  --connection-type ORACLE \
  --technology-type OCI_AUTONOMOUS_DATABASE \
  --username "ADMIN" \
  --password "ADBPassword123!" \
  --replication-username "GGADMIN" \
  --replication-password "GGPassword123!" \
  --database-id $ADB_ID \
  --vault-id $VAULT_ID \
  --key-id $KEY_ID \
  --subnet-id $SUBNET_ID \
  --wait-for-state ACTIVE \
  --max-wait-seconds 600
```

### Create CDB Connection (for PDB sources < 21c)

```bash
oci database-migration connection create \
  --compartment-id $COMPARTMENT_ID \
  --display-name "src-cdb-root" \
  --connection-type ORACLE \
  --technology-type ORACLE_DATABASE \
  --username "SYSTEM" \
  --password "SystemPassword!" \
  --connection-string '(description=(address=(protocol=tcp)(port=1521)(host=10.0.1.48))(connect_data=(service_name=CDB_SERVICE.example.com)))' \
  --vault-id $VAULT_ID \
  --key-id $KEY_ID \
  --subnet-id $SUBNET_ID
```

### List DMS Connections

```bash
oci database-migration connection list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data.items[].{"display-name":"display-name", id:id, state:"lifecycle-state", type:"technology-type"}' \
  --output table
```

### Test Connection

```bash
oci database-migration connection get \
  --connection-id <CONNECTION_OCID> \
  --query 'data.{state:"lifecycle-state","ingress-ips":"ingress-ips"}' \
  --output json
```

---

## 4. GoldenGate Deployment

### Create GoldenGate Deployment

```bash
oci goldengate deployment create \
  --compartment-id $COMPARTMENT_ID \
  --display-name "oci-gg-deployment" \
  --license-model BRING_YOUR_OWN_LICENSE \
  --subnet-id $SUBNET_ID \
  --cpu-core-count 1 \
  --is-auto-scaling-enabled false \
  --deployment-type DATABASE_ORACLE \
  --ogg-data '{"adminUsername":"oggadmin","adminPassword":"GGAdminPass!","deploymentName":"oci_gg_deployment"}' \
  --wait-for-state ACTIVE \
  --max-wait-seconds 1800
```

### Get Deployment URL

```bash
oci goldengate deployment get \
  --deployment-id <GG_DEPLOYMENT_OCID> \
  --query 'data.{"url":"deployment-url", state:"lifecycle-state", cpu:"cpu-core-count"}' \
  --output table
```

---

## 5. GoldenGate Connections and Assignments

### Create GG Connection (ADB Target)

```bash
oci goldengate connection create \
  --compartment-id $COMPARTMENT_ID \
  --display-name "gg-adb-conn" \
  --connection-type ORACLE \
  --technology-type OCI_AUTONOMOUS_DATABASE \
  --database-id $ADB_ID \
  --username "GGADMIN" \
  --password "GGPassword!" \
  --routing-method DEDICATED_ENDPOINT \
  --subnet-id $SUBNET_ID \
  --vault-id $VAULT_ID \
  --key-id $KEY_ID
```

### Create GG Connection (External Oracle Source)

```bash
oci goldengate connection create \
  --compartment-id $COMPARTMENT_ID \
  --display-name "gg-ext-oracle-conn" \
  --connection-type ORACLE \
  --technology-type ORACLE_DATABASE \
  --username "GGADMIN" \
  --password "GGPassword!" \
  --connection-string '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=10.0.1.48)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=MY_PDB.example.com)))' \
  --routing-method DEDICATED_ENDPOINT \
  --subnet-id $SUBNET_ID \
  --vault-id $VAULT_ID \
  --key-id $KEY_ID
```

### Assign Connection to Deployment

```bash
oci goldengate connection-assignment create \
  --connection-id <GG_CONNECTION_OCID> \
  --deployment-id <GG_DEPLOYMENT_OCID> \
  --wait-for-state ACTIVE \
  --max-wait-seconds 600
```

### List Assignments

```bash
oci goldengate connection-assignment list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data.items[].{"connection-id":"connection-id", "deployment-id":"deployment-id", state:"lifecycle-state"}' \
  --output table
```

---

## 6. DMS Migrations

### Create Online Migration with Object Storage

```bash
oci database-migration migration create \
  --compartment-id $COMPARTMENT_ID \
  --display-name "HR Schema Migration" \
  --type ONLINE \
  --database-combination ORACLE \
  --source-database-connection-id <SOURCE_CONN_OCID> \
  --target-database-connection-id <TARGET_CONN_OCID> \
  --source-container-database-connection-id <CDB_CONN_OCID> \
  --data-transfer-medium-details '{"type":"OBJECT_STORAGE","objectStorageBucket":{"namespace":"<NS>","bucket":"migration-dms-bucket"},"source":{"kind":"CURL","walletLocation":"/u01/app/oracle/wallet"}}' \
  --initial-load-settings '{"jobMode":"SCHEMA","exportDirectoryObject":{"name":"DATA_PUMP_DIR","path":"/u01/app/oracle/admin/ORCL/dpdump"}}' \
  --ggs-details '{"acceptableLag":30}' \
  --include-objects '[{"owner":"HR","objectName":".*","type":"ALL"}]' \
  --wait-for-state ACTIVE \
  --max-wait-seconds 300
```

### List Migrations

```bash
oci database-migration migration list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data.items[].{"display-name":"display-name", id:id, state:"lifecycle-state", type:type}' \
  --output table
```

---

## 7. Migration Operations

### Validate Migration

```bash
WORK_ID=$(oci database-migration migration evaluate \
  --migration-id <MIGRATION_OCID> \
  --query 'opc-work-request-id' \
  --raw-output)

echo "Work Request: $WORK_ID"

oci database-migration work-request get \
  --work-request-id $WORK_ID \
  --wait-for-state SUCCEEDED \
  --wait-for-state FAILED \
  --wait-interval-seconds 10 \
  --max-wait-seconds 1800
```

### Start Migration

```bash
oci database-migration migration start \
  --migration-id <MIGRATION_OCID>
```

### Monitor Migration Job

```bash
# Get current job
JOB_ID=$(oci database-migration migration get \
  --migration-id <MIGRATION_OCID> \
  --query 'data."executing-job-id"' --raw-output)

# Check job phases
oci database-migration job get \
  --job-id $JOB_ID \
  --query 'data.{state:"lifecycle-state", phases:phases}' \
  --output json
```

### Check Replication Lag

```bash
oci database-migration migration get \
  --migration-id <MIGRATION_OCID> \
  --query 'data.{state:"lifecycle-state","wait-after":"wait-after"}' \
  --output table
```

### Resume/Switchover

```bash
# Resume after Monitor Replication Lag phase
oci database-migration migration resume \
  --migration-id <MIGRATION_OCID>
```

### Abort Migration

```bash
oci database-migration migration abort \
  --migration-id <MIGRATION_OCID>
```

---

## 8. Monitoring and Notifications

### Create ONS Topic Subscription

```bash
oci ons subscription create \
  --compartment-id $COMPARTMENT_ID \
  --topic-id $TOPIC_ID \
  --protocol EMAIL \
  --subscription-endpoint ops-team@company.com
```

### List Subscriptions

```bash
oci ons subscription list \
  --compartment-id $COMPARTMENT_ID \
  --topic-id $TOPIC_ID \
  --query 'data[].{endpoint:endpoint, state:"lifecycle-state", protocol:protocol}' \
  --output table
```

### List Active Alarms

```bash
oci monitoring alarm list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data[].{"display-name":"display-name", severity:severity, "is-enabled":"is-enabled"}' \
  --output table
```

### List Events Rules

```bash
oci events rule list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data[].{"display-name":"display-name", "is-enabled":"is-enabled"}' \
  --output table
```

---

## 9. Troubleshooting Commands

### Check Work Request Errors

```bash
oci database-migration work-request-error list \
  --work-request-id <WORK_REQUEST_ID>
```

### Check Work Request Logs

```bash
oci database-migration work-request-log-entry list \
  --work-request-id <WORK_REQUEST_ID> --limit 100
```

### List All DMS Resources in Compartment

```bash
echo "=== Connections ==="
oci database-migration connection list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data.items[].{"name":"display-name",id:id,state:"lifecycle-state"}' --output table

echo "=== Migrations ==="
oci database-migration migration list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data.items[].{"name":"display-name",id:id,state:"lifecycle-state"}' --output table

echo "=== GoldenGate Deployments ==="
oci goldengate deployment list \
  --compartment-id $COMPARTMENT_ID \
  --query 'data.items[].{"name":"display-name",id:id,state:"lifecycle-state"}' --output table
```

### Delete a DMS Migration

```bash
oci database-migration migration delete \
  --migration-id <MIGRATION_OCID> \
  --wait-for-state DELETED
```

### Import Resource into Terraform State

```bash
# Example: import a DMS connection
terraform import 'oci_database_migration_connection.source["aws_oracle_prod"]' <CONNECTION_OCID>

# Example: import a GoldenGate deployment
terraform import 'oci_golden_gate_deployment.gg' <DEPLOYMENT_OCID>
```

---

## Official References

- [OCI CLI Command Reference](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/)
- [DMS CLI Reference](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/database-migration.html)
- [GoldenGate CLI Reference](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/goldengate.html)
