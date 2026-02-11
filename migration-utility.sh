#!/bin/bash
# ============================================================================
# OCI Database Migration Utility - Interactive deployment and operations menu
#
#  - Caches terraform outputs (no repeated terraform output calls per migration)
#  - Uses OCI CLI with hard timeout (prevents hangs)
#  - Lists jobs once per migration (no job list --all loops)
#  - NO job-output list (that endpoint can hang)
#
# Includes:
#  - List migrations (state + status + last jobs by type)
#  - Start migration (DMS)
#  - Resume migrations (Cut-over)
#  - Pre-cutover validation with GG fallback readiness check
#  - List GoldenGate by migration (extract/replicat status, fallback-only)
#  - Start GG fallback processes per migration
#  - terraform destroy before Exit and menu order adjusted
# ============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Performance / safety knobs
OCI_TIMEOUT_SEC="${OCI_TIMEOUT_SEC:-12}"          # hard timeout per OCI CLI call
OCI_TIMEOUT_LONG="${OCI_TIMEOUT_LONG:-30}"        # longer timeout for start/resume ops
DMS_LIST_JOBS_LIMIT="${DMS_LIST_JOBS_LIMIT:-50}"  # avoid --all unless needed

# ----------------------------------------------------------------------------
# Terraform outputs cache (avoid repeated terraform output calls)
# ----------------------------------------------------------------------------
_TF_CACHE_DMS_MIGRATIONS_JSON=""
_TF_CACHE_GG_DEPLOYMENT_JSON=""
_TF_CACHE_GG_FALLBACK_PROCESSES_JSON=""

tf_out_json() {
    local name="$1"
    case "$name" in
        dms_migrations)
            if [ -z "${_TF_CACHE_DMS_MIGRATIONS_JSON:-}" ]; then
                _TF_CACHE_DMS_MIGRATIONS_JSON="$(terraform output -json dms_migrations 2>/dev/null || true)"
            fi
            echo "$_TF_CACHE_DMS_MIGRATIONS_JSON"
            ;;
        gg_deployment)
            if [ -z "${_TF_CACHE_GG_DEPLOYMENT_JSON:-}" ]; then
                _TF_CACHE_GG_DEPLOYMENT_JSON="$(terraform output -json gg_deployment 2>/dev/null || true)"
            fi
            echo "$_TF_CACHE_GG_DEPLOYMENT_JSON"
            ;;
        gg_fallback_processes)
            if [ -z "${_TF_CACHE_GG_FALLBACK_PROCESSES_JSON:-}" ]; then
                _TF_CACHE_GG_FALLBACK_PROCESSES_JSON="$(terraform output -json gg_fallback_processes 2>/dev/null || true)"
            fi
            echo "$_TF_CACHE_GG_FALLBACK_PROCESSES_JSON"
            ;;
        *)
            terraform output -json "$name" 2>/dev/null || true
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Prereqs
# ----------------------------------------------------------------------------
check_prerequisites() {
    info "Checking prerequisites..."
    local missing=0
    for cmd in terraform jq timeout; do
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
        warn "oci: NOT FOUND (DMS start/state/status listing will be skipped)"
    fi

    if command -v md5sum &>/dev/null; then
        ok "md5sum: $(command -v md5sum)"
    else
        warn "md5sum: NOT FOUND (GG name computation fallback will fail if gg_fallback_processes output is missing)"
    fi

    if [ -f terraform.tfvars ]; then
        ok "terraform.tfvars: found"
    else
        err "terraform.tfvars: NOT FOUND (copy from terraform.tfvars.example)"
        missing=1
    fi
    return $missing
}

# ----------------------------------------------------------------------------
# Terraform wrappers
# ----------------------------------------------------------------------------
tf_init()     { info "Running terraform init..."; terraform init; _TF_CACHE_DMS_MIGRATIONS_JSON=""; _TF_CACHE_GG_DEPLOYMENT_JSON=""; _TF_CACHE_GG_FALLBACK_PROCESSES_JSON=""; }
tf_plan()     { info "Running terraform plan..."; terraform plan; }
tf_apply()    { info "Running terraform apply..."; terraform apply; _TF_CACHE_DMS_MIGRATIONS_JSON=""; _TF_CACHE_GG_DEPLOYMENT_JSON=""; _TF_CACHE_GG_FALLBACK_PROCESSES_JSON=""; }
tf_destroy()  { warn "Running terraform destroy..."; terraform destroy; _TF_CACHE_DMS_MIGRATIONS_JSON=""; _TF_CACHE_GG_DEPLOYMENT_JSON=""; _TF_CACHE_GG_FALLBACK_PROCESSES_JSON=""; }

# ----------------------------------------------------------------------------
# OCI CLI wrapper with timeout (prevents hangs)
# ----------------------------------------------------------------------------
oci_safe() {
    # Usage: oci_safe <oci ...args...>
    timeout "${OCI_TIMEOUT_SEC}"s oci "$@" 2>/dev/null || true
}

# Longer timeout for start/resume operations that take more time
oci_safe_long() {
    timeout "${OCI_TIMEOUT_LONG}"s oci "$@" 2>&1
}

# ----------------------------------------------------------------------------
# DMS helpers (OCI CLI)
# ----------------------------------------------------------------------------
get_migration_id() {
    local key="$1"
    tf_out_json dms_migrations | jq -r --arg k "$key" '.[$k].id // .[$k].migration_id // .[$k].ocid // empty'
}

get_migration_state() {
    local id="$1"
    local s
    s="$(oci_safe database-migration migration get --migration-id "$id" --query 'data."lifecycle-state"' --raw-output | tr -d '\r' || true)"
    echo "${s:-UNKNOWN}"
}

get_executing_job_id() {
    local mig_id="$1"
    oci_safe database-migration migration get \
      --migration-id "$mig_id" \
      --query 'data."executing-job-id"' \
      --raw-output | tr -d '\r' || echo ""
}

get_job_status_info() {
    local job_id="$1"
    oci_safe database-migration job get \
      --job-id "$job_id" \
      --query 'data."lifecycle-details"' \
      --raw-output | tr -d '\r' || echo ""
}

get_job_state() {
    local job_id="$1"
    oci_safe database-migration job get \
      --job-id "$job_id" \
      --query 'data."lifecycle-state"' \
      --raw-output | tr -d '\r' || echo ""
}

list_jobs_for_migration_json() {
    local mig_id="$1"
    oci_safe database-migration job list --migration-id "$mig_id" --limit "$DMS_LIST_JOBS_LIMIT"
}

latest_job_id_from_jobs_json() {
    local jobs_json="$1"
    local job_type="$2"
    echo "$jobs_json" | jq -r --arg jt "$job_type" '
      (.data.items // .data // [])
      | map(select((."job-type" // .type // ."operation-type") == $jt))
      | sort_by(."time-created" // ."timeCreated" // "1970-01-01T00:00:00Z")
      | last
      | .id // empty
    ' 2>/dev/null || echo ""
}

job_summary_line() {
    local job_id="$1"
    local fallback_type="$2"  # MIGRATION/EVALUATION
    if [ -z "${job_id:-}" ] || [ "$job_id" = "null" ]; then
        echo ""
        return 0
    fi

    local j jtype jstate jcreated
    j="$(oci_safe database-migration job get --job-id "$job_id")"
    if [ -z "${j:-}" ]; then
        echo "    - $job_id | $fallback_type | (job get timed out/failed)"
        return 0
    fi

    jtype="$(echo "$j" | jq -r '.data."job-type" // .data.type // .data."operation-type" // $t' --arg t "$fallback_type")"
    jstate="$(echo "$j" | jq -r '.data."lifecycle-state" // .data.status // .data.state // "UNKNOWN"')"
    jcreated="$(echo "$j" | jq -r '.data."time-created" // .data.timeCreated // ""')"
    echo "    - $job_id | $jtype | $jstate${jcreated:+ | $jcreated}"
}

# Resolve the executing or latest MIGRATION job id for a migration
resolve_job_id_for_migration() {
    local mig_id="$1"
    local job_id

    # First try executing-job-id (active job)
    job_id="$(get_executing_job_id "$mig_id")"
    if [ -n "${job_id:-}" ] && [ "$job_id" != "null" ] && [ "$job_id" != "None" ]; then
        echo "$job_id"
        return 0
    fi

    # Fallback: find latest MIGRATION job from job list
    local jobs_json
    jobs_json="$(list_jobs_for_migration_json "$mig_id")"
    job_id="$(latest_job_id_from_jobs_json "$jobs_json" "MIGRATION")"
    if [ -n "${job_id:-}" ] && [ "$job_id" != "null" ]; then
        echo "$job_id"
        return 0
    fi

    echo ""
}

# Pre-cutover gate: uses job.lifecycle-details
is_precutover_ready() {
    local mig_id="$1"
    local state job_id details

    state="$(get_migration_state "$mig_id")"
    if [ "$state" != "WAITING" ] && [ "$state" != "IN_PROGRESS" ] && [ "$state" != "READY" ] && [ "$state" != "ACTIVE" ] && [ "$state" != "MIGRATING" ]; then
        return 1
    fi

    job_id="$(resolve_job_id_for_migration "$mig_id")"
    if [ -z "${job_id:-}" ]; then
        return 1
    fi

    details="$(get_job_status_info "$job_id")"
    if [ -z "${details:-}" ] || [ "$details" = "null" ]; then
        return 1
    fi

    echo "$details" | grep -qi "monitor replication lag" || return 1
    echo "$details" | grep -Eqi "paused|waiting|resume|will pause after|completed" && return 0
    return 0
}

# ----------------------------------------------------------------------------
# GoldenGate helpers (Admin Service REST)
# ----------------------------------------------------------------------------
gg_compute_extract_name() {
    local key="$1"
    local h
    h="$(printf "%s" "$key" | md5sum | awk '{print $1}' | cut -c1-6)"
    echo "EX$(printf "%s" "$h" | tr '[:lower:]' '[:upper:]')"
}

gg_compute_replicat_name() {
    local key="$1"
    local h
    h="$(printf "%s" "$key" | md5sum | awk '{print $1}' | cut -c1-6)"
    echo "RP$(printf "%s" "$h" | tr '[:lower:]' '[:upper:]')"
}

migration_requires_fallback_key() {
    local key="$1"

    local j
    j="$(tf_out_json gg_fallback_processes)"
    if [ -n "${j:-}" ] && echo "$j" | jq -e --arg k "$key" 'type=="object" and .[$k] != null' >/dev/null 2>&1; then
        return 0
    fi

    if [ -f "gg-config/fallback-${key}.json" ]; then
        return 0
    fi

    if [ -f "gg-config/extract-${key}.prm" ] || [ -f "gg-config/replicat-${key}.prm" ]; then
        return 0
    fi

    return 1
}

load_gg_connection() {
    local gg_json
    gg_json="$(tf_out_json gg_deployment)"
    if [ -z "${gg_json:-}" ]; then
        err "terraform output gg_deployment not found. Run terraform apply first."
        return 1
    fi

    GG_URL="$(echo "$gg_json" | jq -r '.deployment_url // .url // empty' 2>/dev/null || true)"
    GG_USER="$(echo "$gg_json" | jq -r '.admin_user // "oggadmin"' 2>/dev/null || echo "oggadmin")"

    if [ -z "${GG_URL:-}" ] || [ "$GG_URL" = "null" ]; then
        err "Could not resolve GG deployment_url from terraform output gg_deployment"
        return 1
    fi
    GG_URL="${GG_URL%/}"

    if [ -z "${GG_PASS:-}" ]; then
        read -rsp "Enter GoldenGate password for user '${GG_USER}': " GG_PASS
        echo ""
    fi
    if [ -z "${GG_PASS:-}" ]; then
        err "GG_PASS is empty."
        return 1
    fi
    return 0
}

gg_api_get() {
    local path="$1"
    curl -k -sS -u "$GG_USER:$GG_PASS" \
      -H "Accept: application/json" \
      "$GG_URL$path"
}

gg_api_post() {
    local path="$1"
    local body="${2:-{}}"
    curl -k -sS -u "$GG_USER:$GG_PASS" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -X POST "$GG_URL$path" \
      -d "$body"
}

gg_get_named() {
    local kind="$1" # extracts / replicats
    local name="$2"

    local resp
    resp="$(gg_api_get "/services/adminsrvr/v2/${kind}/${name}" 2>/dev/null || true)"
    if echo "$resp" | jq -e 'type=="object" and (has("code")|not)' >/dev/null 2>&1; then
        echo "$resp"
        return 0
    fi

    resp="$(gg_api_get "/services/v2/${kind}/${name}" 2>/dev/null || true)"
    echo "$resp"
}

gg_status_from_json() {
    local j="$1"
    echo "$j" | jq -r '
      .status
      // .state
      // .processStatus
      // .processState
      // .lifecycleState
      // .lifecycle_state
      // .registrationStatus
      // .response.status
      // .response.state
      // "UNKNOWN"
    ' 2>/dev/null || echo "UNKNOWN"
}

gg_start() {
    local kind="$1"
    local name="$2"
    gg_api_post "/services/adminsrvr/v2/${kind}/${name}/commands/start" "{}"
}

get_fallback_extract_name() {
    local key="$1"
    local j v

    j="$(tf_out_json gg_fallback_processes)"
    v="$(echo "$j" | jq -r --arg k "$key" '.[$k].extract // .[$k].extract_name // empty' 2>/dev/null || true)"
    if [ -n "${v:-}" ]; then echo "$v"; return 0; fi

    if [ -f "gg-config/fallback-${key}.json" ]; then
        v="$(jq -r '.extract // .extract_name // empty' "gg-config/fallback-${key}.json" 2>/dev/null || true)"
        if [ -n "${v:-}" ]; then echo "$v"; return 0; fi
    fi

    gg_compute_extract_name "$key"
}

get_fallback_replicat_name() {
    local key="$1"
    local j v

    j="$(tf_out_json gg_fallback_processes)"
    v="$(echo "$j" | jq -r --arg k "$key" '.[$k].replicat // .[$k].replicat_name // empty' 2>/dev/null || true)"
    if [ -n "${v:-}" ]; then echo "$v"; return 0; fi

    if [ -f "gg-config/fallback-${key}.json" ]; then
        v="$(jq -r '.replicat // .replicat_name // empty' "gg-config/fallback-${key}.json" 2>/dev/null || true)"
        if [ -n "${v:-}" ]; then echo "$v"; return 0; fi
    fi

    gg_compute_replicat_name "$key"
}

gg_validate_fallback_ready_for_key() {
    local key="$1"

    if ! load_gg_connection; then
        return 1
    fi

    local ex rp
    ex="$(get_fallback_extract_name "$key")"
    rp="$(get_fallback_replicat_name "$key")"

    info "Validating GG fallback processes for '$key'..."
    info "  Extract:  $ex"
    info "  Replicat: $rp"

    local exj rpj
    exj="$(gg_get_named "extracts" "$ex")"
    rpj="$(gg_get_named "replicats" "$rp")"

    if ! echo "$exj" | jq -e 'type=="object" and (has("code")|not)' >/dev/null 2>&1; then
        err "GG Extract not found or not accessible: $ex"
        return 1
    fi
    if ! echo "$rpj" | jq -e 'type=="object" and (has("code")|not)' >/dev/null 2>&1; then
        err "GG Replicat not found or not accessible: $rp"
        return 1
    fi

    ok "GG fallback processes exist (ready to start when needed)."
    return 0
}

gg_start_fallback_for_key() {
    local key="$1"

    if ! migration_requires_fallback_key "$key"; then
        warn "Migration '$key' is not marked as fallback-required. Nothing to start."
        return 0
    fi

    if ! load_gg_connection; then
        return 1
    fi

    local ex rp
    ex="$(get_fallback_extract_name "$key")"
    rp="$(get_fallback_replicat_name "$key")"

    info "Starting GG fallback processes for '$key'..."
    info "  POST start Extract:  $ex"
    gg_start "extracts" "$ex" | jq . || true

    info "  POST start Replicat: $rp"
    gg_start "replicats" "$rp" | jq . || true

    ok "Start commands issued."
}

# ----------------------------------------------------------------------------
# Menu actions
# ----------------------------------------------------------------------------
list_migrations() {
    local mig_json
    mig_json="$(tf_out_json dms_migrations)"
    if [ -z "${mig_json:-}" ] || ! echo "$mig_json" | jq -e 'type=="object" and (keys|length>0)' >/dev/null 2>&1; then
        warn "No migrations found. Run terraform apply first."
        return
    fi

    info "Migrations (grouped):"
    local keys
    keys="$(echo "$mig_json" | jq -r 'keys[]')"

    while read -r k; do
        [ -z "$k" ] && continue

        local name type id state
        name="$(echo "$mig_json" | jq -r --arg kk "$k" '.[$kk].display_name // $kk')"
        type="$(echo "$mig_json" | jq -r --arg kk "$k" '.[$kk].type // "UNKNOWN"')"
        id="$(echo "$mig_json" | jq -r --arg kk "$k" '.[$kk].id // .[$kk].migration_id // .[$kk].ocid // empty')"

        echo ""
        echo "  - ${k}: ${name} (${type})"
        if [ -z "${id:-}" ] || [ "$id" = "null" ]; then
            echo "    OCID: (not found in terraform output)"
            continue
        fi
        echo "    OCID: $id"

        if ! command -v oci &>/dev/null; then
            echo "    State: (oci CLI not found)"
            continue
        fi

        state="$(get_migration_state "$id")"
        [ -z "${state:-}" ] && state="UNKNOWN"
        echo "    State: $state"

        local jobs_json last_mig_job last_eval_job
        jobs_json="$(list_jobs_for_migration_json "$id")"
        last_mig_job="$(latest_job_id_from_jobs_json "$jobs_json" "MIGRATION")"
        last_eval_job="$(latest_job_id_from_jobs_json "$jobs_json" "EVALUATION")"

        if [ "$state" = "IN_PROGRESS" ] || [ "$state" = "WAITING" ]; then
            local job_id job_details
            job_id="$(get_executing_job_id "$id")"
            if [ -z "${job_id:-}" ] || [ "$job_id" = "null" ]; then
                job_id="$last_mig_job"
            fi
            if [ -n "${job_id:-}" ] && [ "$job_id" != "null" ]; then
                job_details="$(get_job_status_info "$job_id")"
                if [ -n "${job_details:-}" ] && [ "$job_details" != "null" ]; then
                    echo "    Status: $job_details"
                fi
            fi
        fi

        echo "    Jobs (last by type):"
        if [ -n "${last_mig_job:-}" ] && [ "$last_mig_job" != "null" ]; then
            job_summary_line "$last_mig_job" "MIGRATION"
        else
            if [ "$state" = "ACCEPTED" ]; then
                echo "    - (no MIGRATION jobs found; migration not started yet)"
            else
                echo "    - (no MIGRATION jobs found)"
            fi
        fi

        if [ -n "${last_eval_job:-}" ] && [ "$last_eval_job" != "null" ]; then
            job_summary_line "$last_eval_job" "EVALUATION"
        else
            echo "    - (no EVALUATION jobs found)"
        fi

    done <<< "$keys"

    echo ""
}

list_goldengate_by_migration() {
    local mig_json keys
    mig_json="$(tf_out_json dms_migrations)"
    if [ -z "${mig_json:-}" ] || ! echo "$mig_json" | jq -e 'type=="object" and (keys|length>0)' >/dev/null 2>&1; then
        warn "No migrations found. Run terraform apply first."
        return
    fi

    if ! load_gg_connection; then
        return
    fi

    keys="$(echo "$mig_json" | jq -r 'keys[]')"
    info "GoldenGate processes by migration (fallback/reverse replication):"
    echo ""

    local any=0
    while read -r k; do
        [ -z "$k" ] && continue
        if ! migration_requires_fallback_key "$k"; then
            continue
        fi
        any=1

        local name type ex rp
        name="$(echo "$mig_json" | jq -r --arg kk "$k" '.[$kk].display_name // $kk')"
        type="$(echo "$mig_json" | jq -r --arg kk "$k" '.[$kk].type // "UNKNOWN"')"

        ex="$(get_fallback_extract_name "$k")"
        rp="$(get_fallback_replicat_name "$k")"

        echo "  - $k: $name ($type)"
        echo "    Extract:  $ex"
        echo "    Replicat: $rp"

        local exj rpj
        exj="$(gg_get_named "extracts" "$ex")"
        rpj="$(gg_get_named "replicats" "$rp")"

        if echo "$exj" | jq -e 'type=="object" and (has("code")|not)' >/dev/null 2>&1; then
            echo "    Extract status:  $(gg_status_from_json "$exj")"
        else
            echo "    Extract status:  NOT_FOUND/NO_ACCESS"
        fi

        if echo "$rpj" | jq -e 'type=="object" and (has("code")|not) and (has("message")|not or (.message|tostring|test("NotAuthorized|NotFound")|not))' >/dev/null 2>&1; then
            echo "    Replicat status: $(gg_status_from_json "$rpj")"
        else
            echo "    Replicat status: NOT_FOUND/NO_ACCESS"
        fi

        echo ""
    done <<< "$keys"

    if [ "$any" -eq 0 ]; then
        warn "No fallback/reverse-replication migrations detected."
    fi
}

show_urls() {
    info "Console URLs:"
    tf_out_json dms_migrations | jq -r 'to_entries[] | "  \(.key): \(.value.console_url)"' || true
    echo ""
    info "GoldenGate:"
    tf_out_json gg_deployment | jq -r '"  URL: \(.deployment_url)\n  State: \(.lifecycle_state)\n  User: \(.admin_user // "oggadmin")"' || true
}

start_migration() {
    if ! command -v oci &>/dev/null; then
        warn "oci: NOT FOUND (cannot start migrations)"
        return
    fi

    local mig_json keys
    mig_json="$(tf_out_json dms_migrations)"
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
        name="$(echo "$mig_json" | jq -r --arg kk "$k" '.[$kk].display_name // $kk')"
        type="$(echo "$mig_json" | jq -r --arg kk "$k" '.[$kk].type // "UNKNOWN"')"
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
    local result
    result="$(oci_safe_long database-migration migration start --migration-id "$mig_id" 2>&1)" || true

    if [ -n "${result:-}" ]; then
        # Check if it contains an error
        if echo "$result" | grep -qi "error\|ServiceError\|NotAuthorized\|InvalidParameter"; then
            err "Start failed: $result"
            return
        fi
    fi

    ok "Start requested. Returning to menu."
}

resume_migration_cutover() {
    if ! command -v oci &>/dev/null; then
        warn "oci: NOT FOUND (cannot resume migrations)"
        return
    fi

    local mig_json keys
    mig_json="$(tf_out_json dms_migrations)"
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
        name="$(echo "$mig_json" | jq -r --arg kk "$k" '.[$kk].display_name // $kk')"
        type="$(echo "$mig_json" | jq -r --arg kk "$k" '.[$kk].type // "UNKNOWN"')"
        echo "  $idx. $k: $name ($type)"
        MIG_KEYS[$idx]="$k"
        idx=$((idx+1))
    done <<< "$keys"

    read -rp "Select migration number to RESUME (Cut-over) (or 0 to cancel): " sel
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
        err "Could not resolve migration OCID for $mig_key"
        return
    fi

    state="$(get_migration_state "$mig_id")"
    info "Migration state for $mig_key: $state"

    # --- FIX: Resume operates on the JOB, not the migration ---
    # The DMS API requires: oci database-migration job resume --job-id <JOB_OCID>
    # NOT: oci database-migration migration resume --migration-id <MIG_OCID>

    local job_id
    job_id="$(resolve_job_id_for_migration "$mig_id")"

    if [ -z "${job_id:-}" ]; then
        err "Could not find an active or recent MIGRATION job for $mig_key."
        err "The migration may not have been started yet, or the job list timed out."
        info "Try running 'List migrations' (option 5) to see job details."
        return
    fi

    local job_state
    job_state="$(get_job_state "$job_id")"
    info "Job ID: $job_id"
    info "Job state: $job_state"

    if [ "$job_state" != "WAITING" ] && [ "$state" != "WAITING" ]; then
        warn "Neither migration ($state) nor job ($job_state) are in WAITING state."
        read -rp "Proceed with resume anyway? (y/N): " confirm
        if [ "${confirm:-n}" != "y" ] && [ "${confirm:-n}" != "Y" ]; then
            info "Cancelled."
            return
        fi
    fi

    info "Issuing RESUME for job $job_id (cut-over)..."
    local result
    result="$(oci_safe_long database-migration job resume --job-id "$job_id" 2>&1)" || true

    if [ -n "${result:-}" ]; then
        if echo "$result" | grep -qi "error\|ServiceError\|NotAuthorized\|InvalidParameter"; then
            err "Resume failed: $result"
            return
        fi
        # Show the response (may contain job details)
        info "API response:"
        echo "$result" | jq . 2>/dev/null || echo "$result"
    fi

    ok "Resume requested for job $job_id. Check Console for status."
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
            warn "Migration is ACCEPTED. Run 'Start migration' first."
        fi

        if is_precutover_ready "$mig_id"; then
            ok "Pre-cutover gate satisfied: detected 'Monitor replication lag' in job status."
            gate_ok="true"
        else
            warn "Pre-cutover gate NOT detected at 'Monitor replication lag'. Script may enforce its own checks."
        fi
    fi

    if migration_requires_fallback_key "$key"; then
        info "Migration '$key' requires GoldenGate fallback: validating Extract/Replicat readiness..."
        if ! gg_validate_fallback_ready_for_key "$key"; then
            warn "GoldenGate fallback validation FAILED. Returning to menu."
            return
        fi
    fi

    local tmp
    tmp="$(mktemp)"
    set +e
    bash "$script" 2>&1 | tee "$tmp"
    local rc=${PIPESTATUS[0]}
    set -e

    if [ $rc -ne 0 ]; then
        if [ "$gate_ok" = "true" ] && grep -q "Migration is not in ACTIVE/MIGRATING state" "$tmp"; then
            warn "Pre-cutover script expects ACTIVE/MIGRATING, but migration is WAITING at 'Monitor replication lag' (correct pause point)."
            warn "Treating this as expected."
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

start_gg_fallback_menu() {
    local mig_json keys
    mig_json="$(tf_out_json dms_migrations)"
    keys="$(echo "$mig_json" | jq -r 'keys[]' 2>/dev/null || true)"
    if [ -z "${keys:-}" ]; then
        warn "No migrations found. Run terraform apply first."
        return
    fi

    info "Configured migrations (fallback-required only):"
    local idx=1
    declare -A MIG_KEYS
    while read -r k; do
        [ -z "$k" ] && continue
        if migration_requires_fallback_key "$k"; then
            local name type
            name="$(echo "$mig_json" | jq -r --arg kk "$k" '.[$kk].display_name // $kk')"
            type="$(echo "$mig_json" | jq -r --arg kk "$k" '.[$kk].type // "UNKNOWN"')"
            echo "  $idx. $k: $name ($type)"
            MIG_KEYS[$idx]="$k"
            idx=$((idx+1))
        fi
    done <<< "$keys"

    if [ "$idx" -eq 1 ]; then
        warn "No fallback/reverse-replication migrations detected."
        return
    fi

    read -rp "Select migration number (or 0 to cancel): " sel
    if [ "${sel:-0}" = "0" ]; then
        return
    fi

    local mig_key="${MIG_KEYS[$sel]:-}"
    if [ -z "$mig_key" ]; then
        err "Invalid selection"
        return
    fi

    gg_start_fallback_for_key "$mig_key"
}

# ----------------------------------------------------------------------------
# Menu
# ----------------------------------------------------------------------------
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
    echo "  6. List GoldenGate by migration (extract/replicat)"
    echo "  7. Show console URLs"
    echo "  8. Start migration"
    echo "  9. Resume migrations (Cut-over)"
    echo " 10. Run pre-cutover validation (includes GG fallback readiness check)"
    echo " 11. Start GoldenGate fallback processes (per migration)"
    echo " 12. terraform destroy"
    echo "  0. Exit"
    echo "========================================"
    read -rp "Select option: " opt
    case $opt in
        1) check_prerequisites ;;
        2) tf_init ;;
        3) tf_plan ;;
        4) tf_apply ;;
        5) list_migrations ;;
        6) list_goldengate_by_migration ;;
        7) show_urls ;;
        8) start_migration ;;
        9) resume_migration_cutover ;;
       10) run_pre_cutover ;;
       11) start_gg_fallback_menu ;;
       12) tf_destroy ;;
        0) exit 0 ;;
        *) err "Invalid option" ;;
    esac
}

while true; do menu; done