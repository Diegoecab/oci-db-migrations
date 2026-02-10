# Quick Start Guide

Estimated time: 30-45 minutes (excludes database preparation).

---

## Checklist

- [ ] Terraform >= 1.5.0 installed
- [ ] OCI CLI installed and configured
- [ ] API key uploaded to OCI Console
- [ ] VCN, private subnet, Service Gateway exist
- [ ] ADB created with private endpoint enabled
- [ ] Vault and Master Key created
- [ ] Database preparation script executed on source and target
- [ ] Source database accessible from OCI (VPN/FastConnect)

---

## 1. Configure (5 minutes)

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: fill in OCIDs, credentials, migration definitions
```

---

## 2. Deploy (10-15 minutes)

```bash
terraform init
terraform plan    # Review resource count
terraform apply   # Confirm with 'yes'
```

---

## 3. Post-Apply

If `auto_validate_migration = true` (default), validation runs automatically.

Check results:

```bash
terraform output -json dms_migrations | jq '.[] | {display_name, console_url}'
```

Configure advanced DMS settings if needed:

```bash
./configure-dms-advanced.sh
```

---

## 4. Start Migration

If `auto_start_migration = false` (default), start manually:

```bash
oci database-migration migration start \
  --migration-id $(terraform output -json dms_migrations | jq -r '.<migration_key>.id')
```

---

## 5. Pre-Cutover and Switchover

When replication is caught up, run the pre-cutover check:

```bash
./gg-config/pre-cutover-<migration_key>.sh
```

Then execute switchover in the OCI Console.

---

## 6. Verify

```bash
terraform output gg_deployment
terraform output monitoring
```
