# Architecture — OCI Database Migration Terraform Package

## Component Overview

This package manages the following OCI resources through Terraform:

### Core Migration Resources

| Resource | File | Purpose |
|----------|------|---------|
| `oci_database_migration_connection` (source) | dms.tf | Source Oracle DB connection with private endpoint |
| `oci_database_migration_connection` (source_cdb) | dms.tf | CDB root connection for PDB sources < 21c |
| `oci_database_migration_connection` (target) | dms.tf | Target ADB connection with private endpoint |
| `oci_database_migration_migration` | dms.tf | Migration definition with online replication, Data Pump, and object selection |
| `null_resource` (validate_and_start) | dms.tf | Auto-validate and auto-start via OCI CLI |
| `local_file` (pre_cutover_script) | dms.tf | Generated pre-cutover validation scripts |

### GoldenGate Resources

| Resource | File | Purpose |
|----------|------|---------|
| `oci_golden_gate_deployment` | goldengate.tf | Managed GoldenGate deployment |
| `oci_golden_gate_connection` (adb) | goldengate.tf | GG connection to each target ADB |
| `oci_golden_gate_connection` (ext_oracle) | goldengate.tf | GG connection to each source Oracle DB |
| `oci_golden_gate_connection_assignment` | goldengate.tf | Links connections to the GG deployment |
| `oci_golden_gate_database_registration` | goldengate.tf | DB registrations for GG console visibility |
| `time_sleep` | goldengate.tf | Stabilization delay between connection creation and assignment |

### Supporting Infrastructure

| Resource | File | Purpose |
|----------|------|---------|
| `oci_core_network_security_group` | network.tf | NSG with Oracle DB (1521-1522) and HTTPS (443) rules |
| `oci_vault_secret` (multiple) | vault.tf | Encrypted credential storage in OCI Vault |
| `oci_monitoring_alarm` (multiple) | monitoring.tf | Two-tier alarms for DMS lag, GG health, CPU |
| `oci_events_rule` (multiple) | events.tf | Lifecycle notifications for DMS and GG |
| `oci_logging_log` (optional) | logging.tf | Operational logs for DMS and GG |

## Data Flow

```
Source Oracle DB (AWS/On-Prem)
    │
    ├── [DMS Connection: src-*] ──────── DMS Service
    │       │                               │
    │       │  ┌─ Data Pump Export ──────────┤
    │       │  │                             │
    │       │  └──→ Object Storage ──→ Data Pump Import
    │       │                               │
    │       └── GoldenGate Extract ─────────┤
    │           (CDC / Real-time)            │
    │                                       │
    │                                       ▼
    │                              Target ADB (OCI)
    │                              [DMS Connection: tgt-*]
    │
    └── [GG Connection: ext_oracle] ── GoldenGate Deployment
                                           │
                                    [GG Connection: adb]
                                           │
                                    (Reverse Replication
                                     if enabled)
```

## Variable Mapping (N:M)

```
source_databases          migrations               target_databases
┌─────────────────┐      ┌──────────────────┐      ┌─────────────────┐
│ aws_oracle_prod  │──┬──│ hr_migration     │──────│ adb_prod        │
│                  │  │  │   source: prod    │      │                 │
│                  │  │  │   target: prod    │      │                 │
│                  │  │  └──────────────────┘      │                 │
│                  │  │  ┌──────────────────┐      │                 │
│                  │  └──│ sales_migration  │──────│                 │
└─────────────────┘      │   source: prod    │      └─────────────────┘
                         │   target: prod    │
                         └──────────────────┘
                         ┌──────────────────┐      ┌─────────────────┐
                    ┌────│ archive_migration│──────│ adb_archive     │
                    │    │   source: prod    │      │                 │
                    │    │   target: archive │      └─────────────────┘
                    │    └──────────────────┘
```

Multiple migrations can share the same source or target — connections are created once per unique database key.

## Security Model

- All database credentials stored in **OCI Vault** as Base64-encoded secrets
- DMS connections use **private endpoints** within the VCN (no public IP)
- GoldenGate deployment runs in **private subnet** with NSG
- NSG rules restrict traffic to Oracle DB ports (1521-1522) and HTTPS (443) from within VCN
- Terraform state contains sensitive data — use remote backend with encryption

## Official References

- [OCI DMS Architecture](https://docs.oracle.com/en-us/iaas/database-migration/doc/overview-database-migration.html)
- [OCI GoldenGate Architecture](https://docs.oracle.com/en-us/iaas/goldengate/doc/overview-goldengate.html)
- [OCI Vault](https://docs.oracle.com/en-us/iaas/Content/KeyManagement/Concepts/keyoverview.htm)
- [OCI Monitoring](https://docs.oracle.com/en-us/iaas/Content/Monitoring/Concepts/monitoringoverview.htm)
