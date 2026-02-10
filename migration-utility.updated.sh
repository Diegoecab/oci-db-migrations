#!/bin/bash
# ============================================================================
# Migration Utility - Interactive deployment and operations menu
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

get_migration_id() {
    local key="$1"
    terraform output -json dms_migrations 2>/dev/null | jq -r --arg k "$key" '.[$k].id // .[$k].migration_id // .[$k].ocid // empty'
}

get_migration_state() {
    local mig_id="$1"
    if ! command -v oci &>/dev/null; then
        echo "OCI_CLI_NOT_FOUND"
        return 0
    fi
    oci database-migration migration get \
      --migration-id "$mig_id" \
      --query 'data."lifecycle-state"' \
      --raw-output 2>/dev/null || echo "UNKNOWN"
}

start_migration_if_accepted() {
    local key="$1"
    local mig_id state
    mig_id="$(get_migration_id "$key")"
    if [ -z "${mig_id}" ]; then
        warn "Could not determine migration OCID for '$key' (run terraform apply first)."
        return 1
    fi
    state="$(get_migration_state "$mig_id")"
    info "Migration state for $key: $state"
    if [ "$state" = "ACCEPTED" ]; then
        read -rp "Migration is ACCEPTED. Start it now? (y/N): " ans
        if [[ "${ans}" =~ ^[Yy]$ ]]; then
            info "Starting migration job for $key..."
            oci database-migration migration start --migration-id "$mig_id" >/dev/null
            ok "Start requested. Waiting for ACTIVE/MIGRATING/READY..."
            for _ in $(seq 1 60); do
                state="$(get_migration_state "$mig_id")"
                echo "  Current State: $state"
                if [ "$state" = "ACTIVE" ] || [ "$state" = "MIGRATING" ] || [ "$state" = "READY" ]; then
                    ok "Migration reached state: $state"
                    return 0
                fi
                sleep 10
            done
            warn "Migration did not reach ACTIVE/MIGRATING/READY within 10 minutes. You can retry pre-cutover later."
            return 1
        fi
    fi
    return 0
}


check_prerequisites() {
    info "Checking prerequisites..."
    local missing=0
    for cmd in terraform jq; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd: $(command -v "$cmd")"
        else
            err "$cmd: NOT FOUND"
            missing=1
        fi
    done
    if command -v oci &>/dev/null; then
        ok "oci: $(command -v oci)"
    else
        warn "oci: NOT FOUND (auto-validate/start will be skipped)"
    fi
    if [ -f terraform.tfvars ]; then
        ok "terraform.tfvars: found"
    else
        err "terraform.tfvars: NOT FOUND (copy from terraform.tfvars.example)"
        missing=1
    fi
    return $missing
}

tf_init()     { info "Running terraform init..."; terraform init; }
tf_plan()     { info "Running terraform plan..."; terraform plan; }
tf_apply()    { info "Running terraform apply..."; terraform apply; }
tf_destroy()  { warn "Running terraform destroy..."; terraform destroy; }

list_migrations() {
    info "Configured migrations:"
    local json
    json="$(terraform output -json dms_migrations 2>/dev/null)" || { warn "No migrations found. Run terraform apply first."; return; }

    echo "$json" | jq -r 'to_entries[] | "  \(.key): \(.value.display_name) (\(.value.type))"' || true

    if command -v oci &>/dev/null; then
        echo ""
        info "Migration states:"
        echo "$json" | jq -r 'to_entries[] | "\(.key) \(.value.id // .value.migration_id // .value.ocid // "")"' | while read -r k id; do
            if [ -n "$id" ]; then
                st="$(get_migration_state "$id")"
                echo "  $k: $st"
            else
                echo "  $k: UNKNOWN (no OCID in terraform output)"
            fi
        done
    fi
}

show_urls() {
    info "Console URLs:"
    terraform output -json dms_migrations 2>/dev/null | jq -r 'to_entries[] | "  \(.key): \(.value.console_url)"' || true
    echo ""
    info "GoldenGate:"
    terraform output -json gg_deployment 2>/dev/null | jq -r '"  URL: \(.deployment_url)\n  State: \(.lifecycle_state)"' || true
}

run_pre_cutover() {
    info "Available pre-cutover scripts:"
    local scripts=(gg-config/pre-cutover-*.sh)
    if [ ${#scripts[@]} -eq 0 ]; then
        warn "No pre-cutover scripts found. Run terraform apply first."
        return
    fi
    for i in "${!scripts[@]}"; do
        echo "  $((i+1)). ${scripts[$i]}"
    done
    read -rp "Select script number (or 0 to cancel): " choice
    if [ "$choice" -gt 0 ] 2>/dev/null && [ "$choice" -le "${#scripts[@]}" ]; then
        local script="${scripts[$((choice-1))]}"
        local base key
        base="$(basename "$script")"
        key="${base#pre-cutover-}"
        key="${key%.sh}"

        # If migration is still ACCEPTED, offer to start it so the pre-cutover checks can run.
        start_migration_if_accepted "$key" || true

        bash "$script"
    fi
}

menu() {
    echo ""
    echo "========================================"
    echo " OCI Database Migration Utility"
    echo "========================================"
    echo "  1. Check prerequisites"
    echo "  2. terraform init"
    echo "  3. terraform plan"
    echo "  4. terraform apply"
    echo "  5. List migrations"
    echo "  6. Show console URLs"
    echo "  7. Run pre-cutover validation"
    echo "  8. terraform destroy"
    echo "  0. Exit"
    echo "========================================"
    read -rp "Select option: " opt
    case $opt in
        1) check_prerequisites ;;
        2) tf_init ;;
        3) tf_plan ;;
        4) tf_apply ;;
        5) list_migrations ;;
        6) show_urls ;;
        7) run_pre_cutover ;;
        8) tf_destroy ;;
        0) exit 0 ;;
        *) err "Invalid option" ;;
    esac
}

while true; do menu; done
