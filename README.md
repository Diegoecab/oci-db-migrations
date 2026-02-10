# Terraform - OCI Database Migration (DMS) + GoldenGate

Infrastructure-as-code for migrating Oracle databases from AWS EC2 (or OCI Base DB) to OCI Autonomous Database using OCI Database Migration Service and GoldenGate.

Supports multi-database, multi-schema migrations with enterprise monitoring, private networking, and automated execution.

---

## Features

- **Multi-database, multi-schema**: Define N source databases and M target ADBs independently; migrations reference them by key with per-migration schema lists, no duplication
- **Private networking**: GoldenGate deploys in a private subnet with NSG; DMS connections use private endpoints; ADB uses private endpoint
- **GG reverse replication derived**: GG connections are derived from DMS source/target; only GG credentials needed
- **GoldenGate license**: Defaults to BYOL
- **Automated execution**: Auto-validate and auto-start per migration (configurable), pre-cutover validation scripts generated automatically
- **Enterprise monitoring**: Two-tier alarms (WARNING + CRITICAL), OCI Events for lifecycle notifications, optional OCI Logging
- **OCI provider >= 6.0**: Compatible with current provider (v6.x / v7.x), Terraform >= 1.5
- **GitHub-ready**: Architecture diagrams (Mermaid), CI-friendly structure, .gitignore included

---

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed diagrams (Mermaid renders natively on GitHub).

**Summary**: Source DBs on AWS connect via VPN/FastConnect to an OCI VCN. DMS and GoldenGate run in a private subnet with NSG protection. Target ADBs use private endpoints in the same subnet. All credentials are stored in OCI Vault. Monitoring alarms and event rules send notifications via ONS.

---

## Project Structure

```
.
├── README.md
├── QUICKSTART.md
├── AUTHENTICATION_TROUBLESHOOTING.md
├── .gitignore
├── provider.tf                  # OCI provider >= 6.0, Terraform >= 1.5
├── variables.tf                 # All variables with defaults
├── terraform.tfvars.example     # Complete example configuration
├── data.tf                      # Data sources and derived locals
├── network.tf                   # NSG for migration traffic
├── vault.tf                     # Vault secrets per source/target/GG
├── dms.tf                       # DMS connections, migrations, auto-exec
├── goldengate.tf                # GG deployment (private), derived connections
├── events.tf                    # OCI Events rules for notifications
├── monitoring.tf                # Two-tier alarms (WARNING + CRITICAL)
├── logging.tf                   # OCI Logging for DMS/GG
├── outputs.tf                   # Comprehensive outputs
├── templates/
│   ├── extract.prm.tpl          # GG Extract parameter template
│   └── replicat.prm.tpl         # GG Replicat parameter template
├── docs/
│   └── ARCHITECTURE.md          # Mermaid diagrams (GitHub-native)
├── scripts/
│   └── dms-db-prep-v2.sh        # Oracle DB preparation (KB50125)
├── gg-config/                   # Generated: param files, pre-cutover scripts
├── migration-utility.sh         # Interactive deployment menu
└── configure-dms-advanced.sh    # Post-deploy DMS settings helper
```

---

## Prerequisites

### Tools

- Terraform >= 1.5.0
- OCI CLI >= 3.50 (for auto-validate/start and pre-cutover scripts)
- Bash >= 4.4

### Pre-existing OCI Resources

- VCN with a **private subnet** (no public IP assignment)
- Service Gateway (for Oracle Services Network access)
- NAT Gateway or DRG/VPN/FastConnect (for AWS connectivity)
- Autonomous Database(s) with **private endpoint** enabled
- OCI Vault with Master Encryption Key
- Notification Topic (recommended)
- Log Group (optional, for OCI Logging)

### Database Preparation

Run the official Oracle preparation script before deploying:

```bash
cd scripts && ./dms-db-prep-v2.sh
```

Execute generated SQL on source and target databases.
Reference: Oracle KB50125 (Feb 3, 2026).

---

## IAM Policies

Minimum IAM policies required for the Terraform user/group. Replace `<compartment_name>` with your compartment.

### DMS Policies

```
Allow group MigrationAdmins to manage database-migration-family in compartment <compartment_name>
Allow group MigrationAdmins to manage database-migration-connections in compartment <compartment_name>
Allow group MigrationAdmins to read database-family in compartment <compartment_name>
Allow group MigrationAdmins to read autonomous-database-family in compartment <compartment_name>
```

### GoldenGate Policies

```
Allow group MigrationAdmins to manage goldengate-family in compartment <compartment_name>
Allow group MigrationAdmins to manage goldengate-deployment in compartment <compartment_name>
Allow group MigrationAdmins to manage goldengate-connection in compartment <compartment_name>
```

### Network Policies

```
Allow group MigrationAdmins to manage virtual-network-family in compartment <compartment_name>
Allow group MigrationAdmins to use subnets in compartment <compartment_name>
Allow group MigrationAdmins to use network-security-groups in compartment <compartment_name>
Allow group MigrationAdmins to use vnics in compartment <compartment_name>
```

### Vault Policies

```
Allow group MigrationAdmins to manage secret-family in compartment <compartment_name>
Allow group MigrationAdmins to use vaults in compartment <compartment_name>
Allow group MigrationAdmins to use keys in compartment <compartment_name>
```

### Monitoring and Events Policies

```
Allow group MigrationAdmins to manage alarms in compartment <compartment_name>
Allow group MigrationAdmins to read metrics in compartment <compartment_name>
Allow group MigrationAdmins to manage cloudevents-rules in compartment <compartment_name>
Allow group MigrationAdmins to use ons-topics in compartment <compartment_name>
```

### Logging Policies (if enable_log_analytics = true)

```
Allow group MigrationAdmins to manage log-groups in compartment <compartment_name>
Allow group MigrationAdmins to manage log-content in compartment <compartment_name>
```

### Object Storage Policies (if using staging bucket)

```
Allow group MigrationAdmins to manage objects in compartment <compartment_name>
Allow group MigrationAdmins to manage buckets in compartment <compartment_name>
```

### Service Policies (required for DMS and GG to operate)

```
Allow service database-migration to manage virtual-network-family in compartment <compartment_name>
Allow service database-migration to manage secret-family in compartment <compartment_name>
Allow service database-migration to read autonomous-database-family in compartment <compartment_name>
Allow service database-migration to manage objects in compartment <compartment_name>
Allow service goldengate to use subnets in compartment <compartment_name>
Allow service goldengate to use network-security-groups in compartment <compartment_name>
Allow service goldengate to manage virtual-network-family in compartment <compartment_name>
```

---

## Configuration

### 1. Copy and edit

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 2. Data model

The configuration uses three interconnected maps:

**source_databases**: Each unique source Oracle database defined once.

```hcl
source_databases = {
  aws_prod = {
    display_name = "AWS Oracle Prod"
    host         = "10.0.1.100"
    hostname     = "oracledb.example.com"  # FQDN for GG
    service_name = "ORCL"
    username     = "dms_admin"
    password     = "..."
    gg_username  = "GGADMIN"
    gg_password  = "..."
  }
}
```

**target_databases**: Each unique Autonomous Database defined once.

```hcl
target_databases = {
  adb_prod = {
    display_name = "ADB Prod"
    adb_ocid     = "ocid1.autonomousdatabase..."
    password     = "..."
    gg_username  = "GGADMIN"
    gg_password  = "..."
  }
}
```

**migrations**: Each references a source and target by key.

```hcl
migrations = {
  hr_migration = {
    display_name       = "HR Schema"
    migration_type     = "ONLINE"
    source_db_key      = "aws_prod"
    target_db_key      = "adb_prod"
    schemas_to_migrate = ["HR"]
    enable_reverse_replication = true
  }
  sales_migration = {
    display_name       = "Sales + Inventory"
    migration_type     = "ONLINE"
    source_db_key      = "aws_prod"      # Same source, different schemas
    target_db_key      = "adb_prod"
    schemas_to_migrate = ["SALES", "INVENTORY"]
    enable_reverse_replication = true
  }
}
```

This creates two migrations sharing one DMS source connection and one target connection, eliminating duplication.

### 3. DMS execution control

Global defaults with per-migration overrides:

```hcl
# Global defaults
auto_validate_migration = true   # Auto-validate after creation
auto_start_migration    = false  # Require manual start

# Per-migration override (in migrations map)
hr_migration = {
  # ...
  auto_validate = true
  auto_start    = true  # Override: auto-start this specific migration
}
```

---

## Deployment

### Interactive

```bash
chmod +x migration-utility.sh configure-dms-advanced.sh
./migration-utility.sh
```

### Manual

```bash
terraform init
terraform plan
terraform apply
```

### Post-apply

1. If `auto_validate_migration = true`, validation runs automatically. Check Console for results.
2. Configure advanced DMS settings in Console (Data Pump parallelism, compression).
3. Start migrations (manual or auto).
4. Monitor via alarms and event notifications.

---

## Operations

### Pre-cutover validation

Auto-generated scripts verify migration health before switchover:

```bash
./gg-config/pre-cutover-hr_migration.sh
```

Checks migration state, replication lag, and connection health.

### Manual commands

```bash
# Validate
oci database-migration migration validate \
  --migration-id $(terraform output -json dms_migrations | jq -r '.hr_migration.id')

# Start
oci database-migration migration start \
  --migration-id $(terraform output -json dms_migrations | jq -r '.hr_migration.id')

# GoldenGate console
terraform output -json gg_deployment | jq -r '.deployment_url'
```

---

## Monitoring

### Alarms (metric-based, two tiers)

| Alarm | WARNING | CRITICAL |
|-------|---------|----------|
| DMS Lag (per migration) | > 60s | > 300s |
| GG Extract Lag | > 60s | > 300s |
| GG Replicat Lag | > 60s | > 300s |
| GG CPU | > 80% | > 95% |
| GG Deployment Health | - | < 1 |

Thresholds configurable via `lag_threshold_seconds` and `lag_critical_threshold_seconds`.

### Events (lifecycle-based)

Captures DMS migration and connection state changes, GG deployment updates.
Notifications sent to ONS topic (email, Slack, PagerDuty, HTTPS webhook).

### Logging (optional)

OCI Logging for DMS and GoldenGate operational/audit logs.
Enable with `enable_log_analytics = true` and provide `log_group_ocid`.

---

## Troubleshooting

### Connection failed

Verify NSG allows port 1521 from the private subnet. Test connectivity:

```bash
nc -zv <host> 1521
```

### GoldenGate FQDN error

GG requires a hostname, not IP. Add DNS or `/etc/hosts`:

```
10.0.1.100  oracledb.example.com
```

### ADB private endpoint not reachable

Ensure ADB is configured with private endpoint in the same VCN/subnet. Verify Service Gateway exists for Oracle Services Network.

### Auto-validation failed

Check OCI Console for validation details. Common causes: missing database privileges, network connectivity, incorrect credentials.

### High lag

Scale GoldenGate OCPUs, increase Data Pump parallelism, or reduce source database load.

---

## Cleanup

```bash
terraform destroy
```

---

## References

- [Oracle KB50125: Database Preparation Utility](https://support.oracle.com) (Feb 3, 2026)
- [OCI DMS Documentation](https://docs.oracle.com/en-us/iaas/database-migration/)
- [OCI GoldenGate Documentation](https://docs.oracle.com/en-us/iaas/goldengate/)
- [OCI Events Service](https://docs.oracle.com/en-us/iaas/Content/Events/Concepts/eventsoverview.htm)
- [OCI Monitoring](https://docs.oracle.com/en-us/iaas/Content/Monitoring/Concepts/monitoringoverview.htm)
- [Terraform OCI Provider](https://registry.terraform.io/providers/oracle/oci/latest/docs)

---

## License

See individual file headers. Oracle DB prep script: Universal Permissive License v 1.0.
