#!/usr/bin/env bash
# ============================================================================
# gg_activate_fallback.sh - Activate GoldenGate Fallback Replication
# ============================================================================
#
# Post-cutover script that re-positions Extract/Replicat to current SCN
# and starts them. Run AFTER DMS forward replication is stopped.
#
# What it does:
#   1. Re-positions Extract to current SCN (ALTER EXTRACT BEGIN NOW)
#   2. Starts Extract
#   3. Re-positions Replicat to current SCN (ALTER REPLICAT BEGIN NOW)
#   4. Starts Replicat
#   5. Verifies both processes are RUNNING
#
# Prerequisites:
#   - Extract and Replicat already created (via Terraform) in STOPPED state
#   - DMS forward replication STOPPED
#   - Checkpoint table exists on source DB
#
# Usage:
#   ./gg_activate_fallback.sh <GG_URL> <GG_USER> <GG_PASS> <EXTRACT_NAME> <REPLICAT_NAME>
#
# Example:
#   ./gg_activate_fallback.sh \
#     https://awpo3giva3wa.deployment.goldengate.us-ashburn-1.oci.oraclecloud.com \
#     oggadmin 'SecureGGPassword123!' \
#     EXB2A23A RPE117EE
#
# Can also be called with env vars:
#   GG_URL=https://... GG_USER=oggadmin GG_PASS=... \
#   EXTRACT_NAME=EXB2A23A REPLICAT_NAME=RPE117EE \
#   ./gg_activate_fallback.sh
# ============================================================================

set -euo pipefail

# --- Parse args or env vars ---
GG_URL="${1:-${GG_URL:-}}"
GG_USER="${2:-${GG_USER:-}}"
GG_PASS="${3:-${GG_PASS:-}}"
EXTRACT_NAME="${4:-${EXTRACT_NAME:-}}"
REPLICAT_NAME="${5:-${REPLICAT_NAME:-}}"

GG_URL="${GG_URL%/}"

if [ -z "$GG_URL" ] || [ -z "$GG_USER" ] || [ -z "$GG_PASS" ] || [ -z "$EXTRACT_NAME" ] || [ -z "$REPLICAT_NAME" ]; then
  echo "Usage: $0 <GG_URL> <GG_USER> <GG_PASS> <EXTRACT_NAME> <REPLICAT_NAME>"
  echo ""
  echo "Or set env vars: GG_URL, GG_USER, GG_PASS, EXTRACT_NAME, REPLICAT_NAME"
  exit 1
fi

LOGFILE="gg_activate_fallback_$(date +%Y%m%d_%H%M%S).log"
echo "=== GoldenGate Fallback Activation ===" | tee "$LOGFILE"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$LOGFILE"
echo "GG_URL: $GG_URL" | tee -a "$LOGFILE"
echo "Extract: $EXTRACT_NAME" | tee -a "$LOGFILE"
echo "Replicat: $REPLICAT_NAME" | tee -a "$LOGFILE"
echo "" | tee -a "$LOGFILE"

# --- Helper functions ---
gg_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local resp http body

  if [ -n "$data" ]; then
    resp=$(curl -k -m 90 -s -w "\n%{http_code}" \
      -u "$GG_USER:$GG_PASS" \
      -H "Content-Type: application/json" -H "Accept: application/json" \
      -X "$method" "$GG_URL$endpoint" \
      -d "$data" 2>>"$LOGFILE" || true)
  else
    resp=$(curl -k -m 90 -s -w "\n%{http_code}" \
      -u "$GG_USER:$GG_PASS" \
      -H "Accept: application/json" \
      -X "$method" "$GG_URL$endpoint" \
      2>>"$LOGFILE" || true)
  fi

  http=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')
  echo "$method $endpoint -> HTTP $http" >> "$LOGFILE"
  echo "$body" >> "$LOGFILE"
  echo ""  >> "$LOGFILE"

  # Return body and http code
  echo "$body"
  return 0
}

check_status() {
  local type="$1"    # extracts or replicats
  local name="$2"
  local body

  body=$(gg_api "GET" "/services/v2/$type/$name")
  local status=$(echo "$body" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response',{}).get('status','unknown'))" 2>/dev/null || echo "unknown")
  echo "$status"
}

wait_for_status() {
  local type="$1"
  local name="$2"
  local expected="$3"
  local max_wait="${4:-30}"
  local elapsed=0

  while [ $elapsed -lt $max_wait ]; do
    local status=$(check_status "$type" "$name")
    if [ "$status" = "$expected" ]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

# ============================================================================
# Step 1: Verify processes exist
# ============================================================================
echo "[1/6] Verifying Extract $EXTRACT_NAME exists..." | tee -a "$LOGFILE"
EXT_STATUS=$(check_status "extracts" "$EXTRACT_NAME")
if [ "$EXT_STATUS" = "unknown" ]; then
  echo "ERROR: Extract $EXTRACT_NAME not found." | tee -a "$LOGFILE"
  exit 1
fi
echo "  Current status: $EXT_STATUS" | tee -a "$LOGFILE"

echo "[2/6] Verifying Replicat $REPLICAT_NAME exists..." | tee -a "$LOGFILE"
REP_STATUS=$(check_status "replicats" "$REPLICAT_NAME")
if [ "$REP_STATUS" = "unknown" ]; then
  echo "ERROR: Replicat $REPLICAT_NAME not found." | tee -a "$LOGFILE"
  exit 1
fi
echo "  Current status: $REP_STATUS" | tee -a "$LOGFILE"

# ============================================================================
# Step 2: Re-position Extract to current SCN and stop
# ============================================================================
echo "" | tee -a "$LOGFILE"
echo "[3/6] Re-positioning Extract $EXTRACT_NAME to current SCN (BEGIN NOW)..." | tee -a "$LOGFILE"

# If running, need to stop first
if [ "$EXT_STATUS" = "running" ]; then
  echo "  Extract is running. Stopping first..." | tee -a "$LOGFILE"
  gg_api "PATCH" "/services/v2/extracts/$EXTRACT_NAME" '{"status":"stopped"}' > /dev/null
  sleep 5
fi

RESULT=$(gg_api "PATCH" "/services/v2/extracts/$EXTRACT_NAME" '{"begin":"now","status":"stopped"}')
if echo "$RESULT" | grep -q "OGG-08100"; then
  echo "  OK: Extract re-positioned to current SCN." | tee -a "$LOGFILE"
else
  echo "  WARNING: Unexpected response. Check log." | tee -a "$LOGFILE"
  echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"
fi

# ============================================================================
# Step 3: Start Extract
# ============================================================================
echo "[4/6] Starting Extract $EXTRACT_NAME..." | tee -a "$LOGFILE"
RESULT=$(gg_api "PATCH" "/services/v2/extracts/$EXTRACT_NAME" '{"status":"running"}')
if echo "$RESULT" | grep -q "OGG-15426\|started"; then
  echo "  OK: Extract started." | tee -a "$LOGFILE"
else
  echo "  WARNING: Unexpected response." | tee -a "$LOGFILE"
  echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"
fi

# Wait for Extract to be running before starting Replicat
echo "  Waiting for Extract to stabilize..." | tee -a "$LOGFILE"
sleep 5

# ============================================================================
# Step 4: Re-position Replicat to current SCN and stop
# ============================================================================
echo "[5/6] Re-positioning Replicat $REPLICAT_NAME to current SCN (BEGIN NOW)..." | tee -a "$LOGFILE"

if [ "$REP_STATUS" = "running" ]; then
  echo "  Replicat is running. Stopping first..." | tee -a "$LOGFILE"
  gg_api "PATCH" "/services/v2/replicats/$REPLICAT_NAME" '{"status":"stopped"}' > /dev/null
  sleep 5
fi

RESULT=$(gg_api "PATCH" "/services/v2/replicats/$REPLICAT_NAME" '{"begin":"now","status":"stopped"}')
if echo "$RESULT" | grep -q "OGG-08100\|altered"; then
  echo "  OK: Replicat re-positioned to current SCN." | tee -a "$LOGFILE"
else
  echo "  WARNING: Unexpected response. Check log." | tee -a "$LOGFILE"
  echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"
fi

# ============================================================================
# Step 5: Start Replicat
# ============================================================================
echo "[6/6] Starting Replicat $REPLICAT_NAME..." | tee -a "$LOGFILE"
RESULT=$(gg_api "PATCH" "/services/v2/replicats/$REPLICAT_NAME" '{"status":"running"}')
if echo "$RESULT" | grep -q "OGG-15445\|OGG-00975\|started"; then
  echo "  OK: Replicat started." | tee -a "$LOGFILE"
else
  echo "  WARNING: Unexpected response." | tee -a "$LOGFILE"
  echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"
fi

# ============================================================================
# Step 6: Verify final status
# ============================================================================
echo "" | tee -a "$LOGFILE"
echo "=== Final Status Check ===" | tee -a "$LOGFILE"
sleep 5

EXT_FINAL=$(check_status "extracts" "$EXTRACT_NAME")
REP_FINAL=$(check_status "replicats" "$REPLICAT_NAME")

echo "Extract  $EXTRACT_NAME:  $EXT_FINAL" | tee -a "$LOGFILE"
echo "Replicat $REPLICAT_NAME: $REP_FINAL" | tee -a "$LOGFILE"

if [ "$EXT_FINAL" = "running" ] && [ "$REP_FINAL" = "running" ]; then
  echo "" | tee -a "$LOGFILE"
  echo "SUCCESS: Fallback replication is ACTIVE." | tee -a "$LOGFILE"
  echo "  Extract captures from ADB and writes to trail." | tee -a "$LOGFILE"
  echo "  Replicat reads trail and applies to on-prem source." | tee -a "$LOGFILE"
  exit 0
else
  echo "" | tee -a "$LOGFILE"
  echo "WARNING: One or more processes not running. Check logs:" | tee -a "$LOGFILE"
  echo "  $LOGFILE" | tee -a "$LOGFILE"
  echo "  GG Deployment Console: $GG_URL" | tee -a "$LOGFILE"
  exit 1
fi