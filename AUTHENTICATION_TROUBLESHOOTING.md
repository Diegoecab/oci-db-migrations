# Authentication Troubleshooting

## API Key Setup

### 1. Generate API Key

```bash
mkdir -p ~/.oci
openssl genrsa -out ~/.oci/oci_api_key.pem 2048
chmod 600 ~/.oci/oci_api_key.pem
openssl rsa -pubout -in ~/.oci/oci_api_key.pem -out ~/.oci/oci_api_key_public.pem
```

### 2. Upload Public Key

OCI Console -> Identity -> Users -> Your User -> API Keys -> Add API Key -> Paste Public Key

### 3. Get Fingerprint

```bash
openssl rsa -pubout -outform DER -in ~/.oci/oci_api_key.pem | openssl md5 -c
```

### 4. Find OCIDs

- **Tenancy OCID**: OCI Console -> Administration -> Tenancy Details
- **User OCID**: OCI Console -> Identity -> Users -> Your User
- **Compartment OCID**: OCI Console -> Identity -> Compartments

---

## Common Errors

### "401 NotAuthenticated"

Verify fingerprint matches uploaded key. Re-upload if needed.

### "404 NotAuthorizedOrNotFound"

Check compartment OCID and IAM policies (see README.md IAM section).

### "Service error: InvalidParameter"

Usually wrong OCID format. Verify all OCIDs start with `ocid1.`.

---

## Debug Mode

```bash
export TF_LOG=DEBUG
export OCI_GO_SDK_DEBUG=1
terraform plan 2>&1 | tee tf-debug.log
```
