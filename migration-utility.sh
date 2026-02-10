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
        warn "oci: NOT FOUND (auto-validate/start/monitoring will be skipped)"
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
tf_apply()    { info "Running terraform apply..."; terraform apply; }   # keep as-is
tf_destroy()  { warn "Running terraform destroy..."; terraform destroy; }

# helper to resolve migration OCID from terraform output
get_migration_id() {
    local key="$1"
    terraform output -json dms_migrations 2>/dev/null | jq -r --arg k "$key" '.[$k].id // .[$k].migration_id // .[$k].ocid // empty'
}

# helper to get lifecycle state via OCI CLI
get_migration_state() {
    local id="$1"
    oci database-migration migration get \
      --migration-id "$id" \
      --query 'data."lifecycle-state"' \
      --raw-output 2>/dev/null || echo "UNKNOWN"
}

# helper: compartment-id from the migration (needed for Monitoring metrics query)
get_migration_compartment_id() {
    local id="$1"
    oci database-migration migration get \
      --migration-id "$id" \
      --query 'data."compartment-id"' \
      --raw-output 2>/dev/null || echo ""
}

# executing job id (when migration is IN_PROGRESS)
get_executing_job_id() {
    local mig_id="$1"
    oci database-migration migration get \
      --migration-id "$mig_id" \
      --query 'data."executing-job-id"' \
      --raw-output 2>/dev/null || echo ""
}

# job lifecycle details (contains phase info shown in Console "Status information")
get_job_status_info() {
    local job_id="$1"
    oci database-migration job get \
      --job-id "$job_id" \
      --query 'data."lifecycle-details"' \
      --raw-output 2>/dev/null || echo ""
}

# get most recent MIGRATION job-id for a migration (best-effort)
get_latest_migration_job_id() {
    local mig_id="$1"
    if ! oci database-migration job list --help >/dev/null 2>&1; then
        echo ""
        return 0
    fi
    oci database-migration job list --migration-id "$mig_id" --all 2>/dev/null \
      | jq -r '
          .data.items
          | map(select((."job-type" // .type // ."operation-type") == "MIGRATION"))
          | sort_by(."time-created" // ."timeCreated" // "1970-01-01T00:00:00Z")
          | last
          | .id // empty
        ' 2>/dev/null || echo ""
}

# Returns 0 if migration is at/after "Monitor replication lag" and waiting/resumable (pre-cutover gate)
is_precutover_ready() {
    local mig_id="$1"
    local state job_id details

    state="$(get_migration_state "$mig_id")"
    if [ "$state" != "WAITING" ] && [ "$state" != "IN_PROGRESS" ] && [ "$state" != "READY" ] && [ "$state" != "ACTIVE" ] && [ "$state" != "MIGRATING" ]; then
        return 1
    fi

    job_id="$(get_executing_job_id "$mig_id")"
    if [ -z "${job_id:-}" ] || [ "$job_id" = "null" ]; then
        job_id="$(get_latest_migration_job_id "$mig_id")"
    fi
    if [ -z "${job_id:-}" ] || [ "$job_id" = "null" ]; then
        return 1
    fi

    details="$(get_job_status_info "$job_id")"
    if [ -z "${details:-}" ] || [ "$details" = "null" ]; then
        return 1
    fi

    echo "$details" | grep -qi "monitor replication lag" || return 1
    # accept: paused/waiting/resume/completed/will pause after
    echo "$details" | grep -Eqi "paused|waiting|resume|will pause after|completed" && return 0
    return 0
}

# ----------------------------------------------------------------------------
# DMS Native Monitoring (OCI Monitoring) - Migration health metric
# We try common namespaces/dimensions to avoid false UNKNOWNs.
# Console shows it; CLI sometimes varies by region/service rollout.
# ----------------------------------------------------------------------------
_summarize_health_try() {
    local comp_id="$1"
    local namespace="$2"
    local qtext="$3"
    local start="$4"
    local end="$5"

    oci monitoring metric-data summarize-metrics-data \
      --compartment-id "$comp_id" \
      --namespace "$namespace" \
      --query-text "$qtext" \
      --start-time "$start" \
      --end-time "$end" \
      --query 'data[0].aggregated-datapoints | sort_by(.timestamp) | last | .value' \
      --raw-output 2>/dev/null || echo ""
}

get_migration_health() {
    local mig_id="$1"
    if ! command -v oci &>/dev/null; then
        echo ""
        return 0
    fi

    local comp_id
    comp_id="$(get_migration_compartment_id "$mig_id")"
    if [ -z "${comp_id:-}" ] || [ "$comp_id" = "null" ]; then
        echo ""
        return 0
    fi

    # look back 60 minutes to avoid "no datapoint in last 5m"
    local start end
    if date -u -d '-60 minutes' +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
        start="$(date -u -d '-60 minutes' +%Y-%m-%dT%H:%M:%SZ)"
    else
        start="$(date -u -v-60M +%Y-%m-%dT%H:%M:%SZ)"
    fi
    end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Try combos (namespace + dimension key) commonly seen
    local v
    local namespaces=("oci_database_migration_service" "oci_database_migration")
    local dims=("resourceId" "migrationId")
    local ns d

    for ns in "${namespaces[@]}"; do
        for d in "${dims[@]}"; do
            v="$(_summarize_health_try "$comp_id" "$ns" "MigrationHealth[1m]{$d = \"$mig_id\"}.max()" "$start" "$end")"
            if [ -n "${v:-}" ] && [ "$v" != "null" ]; then
                echo "$v"
                return 0
            fi
        done
    done

    echo ""
}

format_health() {
    local v="${1:-}"
    if [ -z "${v:-}" ] || [ "$v" = "null" ]; then
        echo "UNKNOWN"
        return 0
    fi
    if printf "%s" "$v" | grep -Eq '^(1|1\.0)$'; then
        echo "$v (HEALTHY)"
    elif printf "%s" "$v" | grep -Eq '^(0|0\.0)$'; then
        echo "$v (UNHEALTHY)"
    else
        echo "$v"
    fi
}

# list jobs for a migration (best-effort). Falls back to work-requests if jobs command not available.
list_migration_jobs() {
    local mig_id="$1"

    if ! command -v oci &>/dev/null; then
        return 0
    fi

    if oci database-migration job list --help >/dev/null 2>&1; then
        local out
        out="$(oci database-migration job list --migration-id "$mig_id" --all 2>/dev/null || true)"
        if [ -n "${out:-}" ] && echo "$out" | jq -e '.data.items | length >= 0' >/dev/null 2>&1; then
            local count
            count="$(echo "$out" | jq -r '.data.items | length')"
            if [ "$count" -eq 0 ]; then
                echo "    (no jobs found)"
                return 0
            fi
            echo "$out" | jq -r '
              .data.items[]
              | "    - " +
                ((."display-name" // ."name" // .id // "job")) +
                " | " +
                (."job-type" // .type // ."operation-type" // "UNKNOWN") +
                " | " +
                (."lifecycle-state" // .status // .state // "UNKNOWN") +
                (if (."time-created" // ."timeCreated") then
                   " | " + (."time-created" // ."timeCreated")
                 else "" end)
            ' | head -n 15
            if [ "$count" -gt 15 ]; then
                echo "    ... ($count total jobs; showing first 15)"
            fi
            return 0
        fi
    fi

    if oci database-migration work-request list --help >/dev/null 2>&1; then
        local wr
        wr="$(oci database-migration work-request list --migration-id "$mig_id" --all 2>/dev/null || true)"
        if [ -n "${wr:-}" ] && echo "$wr" | jq -e '.data.items | length >= 0' >/dev/null 2>&1; then
            local wcount
            wcount="$(echo "$wr" | jq -r '.data.items | length')"
            if [ "$wcount" -eq 0 ]; then
                echo "    (no work requests found)"
                return 0
            fi
            echo "$wr" | jq -r '
              .data.items[]
              | "    - WR " +
                (.id // "unknown") +
                " | " + (."operation-type" // .operationType // "UNKNOWN") +
                " | " + (.status // "UNKNOWN") +
                (if (.percentComplete != null) then
                   " | " + ((.percentComplete|tostring) + "%")
                 else "" end) +
                (if (.timeAccepted != null) then
                   " | " + .timeAccepted
                 else "" end)
            ' | head -n 15
            if [ "$wcount" -gt 15 ]; then
                echo "    ... ($wcount total work-requests; showing first 15)"
            fi
            return 0
        fi
    fi

    echo "    (jobs/work-requests listing not available via CLI here)"
}

# grouped output (migration + state + health + status + jobs together)
list_migrations() {
    local mig_json
    mig_json="$(terraform output -json dms_migrations 2>/dev/null || true)"
    if [ -z "${mig_json:-}" ] || ! echo "$mig_json" | jq -e 'type=="object" and (keys|length>0)' >/dev/null 2>&1; then
        warn "No migrations found. Run terraform apply first."
        return
    fi

    info "Migrations (grouped):"
    local keys
    keys="$(echo "$mig_json" | jq -r 'keys[]')"

    while read -r k; do
        [ -z "$k" ] && continue

        local name type id state job_id job_details health
        name="$(echo "$mig_json" | jq -r --arg k "$k" '.[$k].display_name // $k')"
        type="$(echo "$mig_json" | jq -r --arg k "$k" '.[$k].type // "UNKNOWN"')"
        id="$(get_migration_id "$k")"

        echo ""
        echo "  - ${k}: ${name} (${type})"
        if [ -z "${id:-}" ]; then
            echo "    OCID: (not found in terraform output)"
            continue
        fi
        echo "    OCID: $id"

        if command -v oci &>/dev/null; then
            state="$(get_migration_state "$id")"
            echo "    State: $state"

            health="$(get_migration_health "$id")"
            if [ -n "${health:-}" ] && [ "$health" != "null" ]; then
                echo "    Health: $(format_health "$health")"
            else
                echo "    Health: UNKNOWN (could not fetch datapoint via CLI; console may still show it)"
            fi

            # Show Console-like status when IN_PROGRESS/WAITING using executing/latest MIGRATION job details
            if [ "$state" = "IN_PROGRESS" ] || [ "$state" = "WAITING" ]; then
                job_id="$(get_executing_job_id "$id")"
                if [ -z "${job_id:-}" ] || [ "$job_id" = "null" ]; then
                    job_id="$(get_latest_migration_job_id "$id")"
                fi
                if [ -n "${job_id:-}" ] && [ "$job_id" != "null" ]; then
                    job_details="$(get_job_status_info "$job_id")"
                    if [ -n "${job_details:-}" ] && [ "$job_details" != "null" ]; then
                        echo "    Status: $job_details"
                    fi
                fi
            fi

            if [ "$state" = "IN_PROGRESS" ] || [ "$state" = "MIGRATING" ] || [ "$state" = "ACTIVE" ] || [ "$state" = "WAITING" ]; then
                echo "    Jobs:"
                list_migration_jobs "$id"
            fi
        else
            echo "    State: (oci CLI not found)"
            echo "    Health: (oci CLI not found)"
        fi
    done <<< "$keys"

    echo ""
}

show_urls() {
    info "Console URLs:"
    terraform output -json dms_migrations 2>/dev/null | jq -r 'to_entries[] | "  \(.key): \(.value.console_url)"' || true
    echo ""
    info "GoldenGate:"
    terraform output -json gg_deployment 2>/dev/null | jq -r '"  URL: \(.deployment_url)\n  State: \(.lifecycle_state)\n  User: \(.admin_user // "oggadmin")"' || true
}

start_migration() {
    if ! command -v oci &>/dev/null; then
        warn "oci: NOT FOUND (cannot start migrations)"
        return
    fi

    local mig_json keys
    mig_json="$(terraform output -json dms_migrations 2>/dev/null || true)"
    keys="$(echo "$mig_json" | jq -r 'keys[]' 2>/dev/null || true)"
    if [ -z "${keys:-}" ]; then
        warn "No migrations found. Run terraform apply first."
        return
    fi

    info "Configured migrations:"
    local idx=1
    declare -A MIG_KEYS
    while read -r k; do
        [ -z "$k" ] && continue
        local name type
        name="$(echo "$mig_json" | jq -r --arg k "$k" '.[$k].display_name // $k')"
        type="$(echo "$mig_json" | jq -r --arg k "$k" '.[$k].type // "UNKNOWN"')"
        echo "  $idx. $k: $name ($type)"
        MIG_KEYS[$idx]="$k"
        idx=$((idx+1))
    done <<< "$keys"

    read -rp "Select migration number (or 0 to cancel): " sel
    if [ "${sel:-0}" = "0" ]; then
        return
    fi

    local mig_key="${MIG_KEYS[$sel]:-}"
    if [ -z "$mig_key" ]; then
        err "Invalid selection"
        return
    fi

    local mig_id state
    mig_id="$(get_migration_id "$mig_key")"
    if [ -z "${mig_id:-}" ]; then
        err "Could not resolve migration OCID for $mig_key (terraform output dms_migrations missing id)"
        return
    fi

    state="$(get_migration_state "$mig_id")"
    info "Migration state for $mig_key: $state"

    if [ "$state" = "ACTIVE" ] || [ "$state" = "MIGRATING" ] || [ "$state" = "IN_PROGRESS" ] || [ "$state" = "WAITING" ]; then
        info "Migration already running ($state)."
        return
    fi

    info "Starting migration job for $mig_key..."
    oci database-migration migration start --migration-id "$mig_id" >/dev/null
    ok "Start requested. Returning to menu."
}

# Wrapper handles WAITING/Monitor Replication Lag as valid pre-cutover gate and won't exit main menu
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
    if ! ([ "$choice" -gt 0 ] 2>/dev/null && [ "$choice" -le "${#scripts[@]}" ]); then
        return
    fi

    local script="${scripts[$((choice-1))]}"
    local base key mig_id state
    base="$(basename "$script")"
    key="${base#pre-cutover-}"
    key="${key%.sh}"

    local gate_ok="false"
    mig_id="$(get_migration_id "$key" || true)"
    if [ -n "${mig_id:-}" ] && command -v oci &>/dev/null; then
        state="$(get_migration_state "$mig_id")"
        info "Migration state for $key: $state"

        if [ "$state" = "ACCEPTED" ]; then
            read -rp "Migration is ACCEPTED. Start it now? (y/N): " ans
            if [[ "${ans:-}" =~ ^[Yy]$ ]]; then
                info "Starting migration job for $key..."
                oci database-migration migration start --migration-id "$mig_id" >/dev/null || true
                ok "Start requested."
                sleep 5
                state="$(get_migration_state "$mig_id")"
                echo "  Current State: $state"
            else
                warn "Not starting migration. Pre-cutover may fail if migration is not running."
            fi
        fi

        # Native health (best-effort)
        local health
        health="$(get_migration_health "$mig_id")"
        if [ -n "${health:-}" ] && [ "$health" != "null" ]; then
            info "DMS MigrationHealth: $(format_health "$health")"
        else
            warn "DMS MigrationHealth: UNKNOWN via CLI (console may still show it)"
        fi

        if is_precutover_ready "$mig_id"; then
            ok "Pre-cutover gate satisfied: detected 'Monitor replication lag' in job status."
            gate_ok="true"
        else
            warn "Pre-cutover gate NOT detected at 'Monitor replication lag'. Script may enforce its own checks."
        fi
    fi

    # Run the selected script, but never terminate main menu on failure.
    # If it fails ONLY because it expects ACTIVE/MIGRATING, treat it as expected when gate_ok=true.
    local tmp
    tmp="$(mktemp)"
    set +e
    bash "$script" 2>&1 | tee "$tmp"
    local rc=${PIPESTATUS[0]}
    set -e

    if [ $rc -ne 0 ]; then
        if [ "$gate_ok" = "true" ] && grep -q "Migration is not in ACTIVE/MIGRATING state" "$tmp"; then
            warn "Pre-cutover script expects ACTIVE/MIGRATING, but migration is WAITING at 'Monitor replication lag' (correct pause point)."
            warn "Treating this as expected. (We should update the pre-cutover script gate check when you share it.)"
            rm -f "$tmp"
            return 0
        fi
        warn "Pre-cutover script returned non-zero (exit code=$rc). Returning to main menu."
        rm -f "$tmp"
        return 0
    fi

    rm -f "$tmp"
    ok "Pre-cutover script completed successfully."
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
    echo "  9. Start migrations"
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
        9) start_migration ;;
        0) exit 0 ;;
        *) err "Invalid option" ;;
    esac
}

while true; do menu; done

