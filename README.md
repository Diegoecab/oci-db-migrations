# OCI Database Migration Terraform Package

**Automated Oracle Database Migration from AWS (or On-Premises) to OCI Autonomous Database using Terraform, OCI Database Migration Service (DMS), and OCI GoldenGate.**

---

## Overview

This Terraform package provisions and orchestrates a complete Oracle database migration pipeline using OCI's fully managed services. Define your source databases, target ADBs, and schema lists in `terraform.tfvars` — Terraform handles everything else: networking, secrets, GoldenGate deployment, DMS connections, online replication, monitoring, and notifications.

### What Gets Created

1. **DMS Connections** — source Oracle DB + target ADB with private endpoints and replication credentials
2. **OCI GoldenGate Deployment** — managed deployment with connections assigned for replication and fallback
3. **Online Migrations** — Data Pump initial load via Object Storage + GoldenGate continuous replication (CDC)
4. **Enterprise Monitoring** — two-tier alarms (WARNING + CRITICAL) for lag, CPU, and deployment health
5. **Event Notifications** — OCI Events rules for DMS/GG lifecycle changes → ONS Topic → email/PagerDuty
6. **Vault Secrets** — all credentials stored securely in OCI Vault
7. **Auto-validate and auto-start** — migrations kick off automatically via OCI CLI provisioners
8. **Pre-cutover validation scripts** — generated per migration for safe switchover

### Key Benefits

| Benefit | Detail |
|---------|--------|
| **Zero-cost DMS** | [OCI Database Migration Service is free](https://docs.oracle.com/en-us/iaas/database-migration/doc/overview-database-migration.html) |
| **Fully managed** | No infrastructure to maintain — DMS and GoldenGate are OCI services |
| **Minimal downtime** | Online migration keeps source available during the entire process |
| **Fallback ready** | OCI GoldenGate provides reverse replication capability back to source |
| **Repeatable** | Terraform IaC = identical deployments across environments |
| **N:M migrations** | Multiple schemas, sources, and targets in a single configuration |
| **Reduced operations** | No manual console clicks — configure variables, run `terraform apply` |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              OCI Tenancy                                     │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐  │
│  │                        Private Subnet (VCN)                             │  │
│  │                                                                         │  │
│  │   ┌────────────┐      ┌──────────────┐      ┌────────────────────┐     │  │
│  │   │  DMS        │      │  GoldenGate  │      │  Autonomous DB     │     │  │
│  │   │  Service    │──────│  Deployment  │──────│  (Target)          │     │  │
│  │   │  (Free)     │      │  (Managed)   │      │  Private Endpoint  │     │  │
│  │   └──────┬──────┘      └──────┬───────┘      └────────────────────┘     │  │
│  │          │      NSG (1521-1522, 443)                                    │  │
│  └──────────┼──────────────────────┼───────────────────────────────────────┘  │
│             │                      │                                          │
│  ┌──────────┴──────────────────────┴───────────────────────────────────────┐  │
│  │  OCI Vault │ OCI Events │ OCI Monitoring │ ONS Topic → Email/Slack     │  │
│  └─────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────┬───────────────────────────────────────────────┘
                               │ VPN / FastConnect / Peering
                      ┌────────┴─────────┐
                      │  Source Oracle DB │
                      │  (AWS / On-Prem)  │
                      └──────────────────┘
```

### Migration Flow

1. `terraform apply` → creates all OCI resources
2. **DMS Validate** → checks connectivity and CPAT compatibility
3. **DMS Start** → Data Pump export → Object Storage → import (Initial Load)
4. **GoldenGate CDC** → continuous replication of changes
5. **Monitor Replication Lag** → DMS pauses for confirmation
6. **Pre-cutover validation** → run generated script
7. **Switchover** → resume DMS to finalize

## Migration and Cutover Flow

```
 (1) Terraform Apply
    │
    ▼
(2) DMS Migration Created
    │
    ├─ Optional Auto-Validate
    │     ├─ Success → Optional Auto-Start
    │     └─ Failure → Event + Notification
    │
    ▼
(3) Initial Load (Data Pump)
    Source → Object Storage → Target ADB
    │
    ▼
(4) Forward CDC (Online Replication)
    Source ───────────────► Target
    │
    ▼
(5) Pre-Cutover Validation
    │
    ▼
(6) Optional Reverse Replication Activation
    Target ───────────────► Source
    (GoldenGate fallback path)
    │
    ▼
(7) Cutover (Resume Migration)
    │
    ▼
(8) Post-Cutover Monitoring


```
---
## Security Model

- All database credentials stored in **OCI Vault** as Base64-encoded secrets
- DMS connections use **private endpoints** within the VCN (no public IP)
- GoldenGate deployment runs in **private subnet** with NSG
- NSG rules restrict traffic to Oracle DB ports (1521-1522) and HTTPS (443) from within VCN
- Terraform state contains sensitive data — use remote backend with encryption

## Prerequisites

### Tools

- [Terraform](https://www.terraform.io/downloads) >= 1.5.0
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) (for auto-validate/start)
- `jq` (for migration-utility.sh)

### OCI Resources (pre-existing)

- VCN with private subnet and connectivity to source DB
- OCI Vault with Master Encryption Key
- Object Storage Bucket for Data Pump staging
- Autonomous Database (target) with private endpoint
- ONS Notification Topic (optional, for alerts)

### Source and target Database Preparation

```bash
./scripts/dms-db-prep-v2.sh
```

This configures GGADMIN, supplemental logging, archive log mode, and Data Pump directories.
You can download the prep script from [Download & Use Database Preparation Utility to Prepare Your Databases for Migration ](https://support.oracle.com/support/?anchorId=&kmContentId=2953866&page=sptemplate&sptemplate=km-article)
> **Reference**: [Preparing an Oracle Source Database](https://docs.oracle.com/en-us/iaas/database-migration/doc/preparing-oracle-source-database.html)

---

## Quick Start

```bash
# 1. Clone and configure
git clone https://github.com/<your-org>/oci-database-migration-terraform.git
cd oci-database-migration-terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your OCIDs, credentials, and schema definitions

# 2. Deploy
terraform init
terraform plan
terraform apply

# 3. Monitor (OCI CLI)
oci database-migration migration get \
  --migration-id <MIGRATION_OCID> \
  --query 'data.{state:"lifecycle-state",type:type}' --output table

# 4. Switchover
./gg-config/pre-cutover-<migration_key>.sh
oci database-migration migration resume --migration-id <MIGRATION_OCID>
```

---

## Configuration

### Include/Exclude Object Rules

| Format | Effect | DMS API |
|--------|--------|---------|
| `"HR.*"` | Entire schema | `owner=HR, object=.*, type=ALL` |
| `"SALES.ORDERS"` | Specific table | `owner=SALES, object=ORDERS, type=TABLE` |

> **Reference**: [Selecting Objects for Migration](https://docs.oracle.com/en-us/iaas/database-migration/doc/selecting-objects-oracle-migration.html)

### File Structure

```
├── provider.tf              # Terraform + OCI provider
├── variables.tf             # All input variables
├── terraform.tfvars.example # Template configuration
├── data.tf                  # Data sources + derived locals
├── network.tf               # NSG with migration rules
├── vault.tf                 # OCI Vault secrets
├── goldengate.tf            # GG deployment + connections + assignments
├── dms.tf                   # DMS connections + migrations + auto-start
├── monitoring.tf            # Two-tier alarms
├── events.tf                # OCI Events notifications
├── logging.tf               # Optional OCI Logging
├── outputs.tf               # Post-deploy summary
├── import-state.sh          # State recovery script
├── migration-utility.sh     # Interactive operations menu
├── scripts/dms-db-prep-v2.sh
├── templates/               # GG Extract/Replicat templates
└── docs/
    ├── ARCHITECTURE.md
    └── OCI_CLI_REFERENCE.md
```

---

## GoldenGate Fallback Strategy

This package deploys OCI GoldenGate alongside DMS to provide a **fallback path**:

1. **DMS manages forward migration** (Source → Target) using GoldenGate internally
2. **Standalone GoldenGate deployment** is provisioned with connections to both databases
3. If rollback is needed, configure **reverse replication** (Target → Source) via the GG console

Set `enable_reverse_replication = true` per migration. Access GoldenGate:

```bash
terraform output -json gg_deployment | jq -r '.deployment_url'
# Login: oggadmin / <goldengate_admin_password>
```

> **Reference**: [OCI GoldenGate](https://docs.oracle.com/en-us/iaas/goldengate/doc/overview-goldengate.html)

---

## Monitoring

| Alarm | Severity | Default Threshold |
|-------|----------|-------------------|
| DMS Replication Lag | WARNING | > 60s |
| DMS Replication Lag | CRITICAL | > 300s |
| GoldenGate Health | CRITICAL | Deployment unhealthy |
| GoldenGate Extract/Replicat Lag | WARNING / CRITICAL | Configurable |
| GoldenGate CPU | WARNING / CRITICAL | > 80% / > 95% |

Events route through the ONS Topic. Add email subscribers:

```bash
oci ons subscription create \
  --compartment-id <COMPARTMENT_OCID> \
  --topic-id <TOPIC_OCID> \
  --protocol EMAIL \
  --subscription-endpoint your-email@company.com
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `409-Conflict` on create | State lost — run `import-state.sh` |
| `FQDN cannot be IP` | Use valid hostname in `hostname` field |
| `objectName must not be null` | Use `"SCHEMA.*"` format |
| `objectType SCHEMA not valid` | Use `type=ALL` (automatic with `.*` pattern) |
| `LimitExceeded` | Request limit increase or delete unused migrations |
| Replication "Disabled" | `ggs_details` block required for ONLINE migrations |
| OCI Provider v8 errors | Pin to `~> 7.0` in provider.tf |

---

## Official Oracle References

- [OCI Database Migration Service](https://docs.oracle.com/en-us/iaas/database-migration/doc/overview-database-migration.html)
- [Creating Oracle Migrations](https://docs.oracle.com/en-us/iaas/database-migration/doc/creating-migrations.html)
- [Selecting Objects for Migration](https://docs.oracle.com/en-us/iaas/database-migration/doc/selecting-objects-oracle-migration.html)
- [DMS Known Issues](https://docs.oracle.com/en/cloud/paas/database-migration/known-issues/index.html)
- [OCI GoldenGate](https://docs.oracle.com/en-us/iaas/goldengate/doc/overview-goldengate.html)
- [Terraform OCI Provider - DMS](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/database_migration_migration)
- [Terraform OCI Provider - GoldenGate](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/golden_gate_deployment)
