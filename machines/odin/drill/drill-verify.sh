#!/usr/bin/env bash
# Automated verification of a running drill Nextcloud stack.
# Exits 0 if all checks pass, non-zero on any failure.
# Called by drill-run.sh after the stack is up.

set -euo pipefail

cd "$(dirname "$0")"

log() { printf '[drill-verify] %s\n' "$*"; }
fail() { log "FAIL: $*"; exit 1; }

# 1. HTTP health endpoint
log "checking /status.php..."
STATUS=$(curl -sS http://127.0.0.1:8443/status.php 2>/dev/null) || fail "curl /status.php failed"
echo "$STATUS" | grep -q '"installed":true' || fail "not installed: $STATUS"
echo "$STATUS" | grep -q '"maintenance":false' || fail "in maintenance mode: $STATUS"
echo "$STATUS" | grep -q '"needsDbUpgrade":false' || fail "needs DB upgrade: $STATUS"
log "status.php: ok ($(echo "$STATUS" | grep -o '"versionstring":"[^"]*"'))"

# 2. Core file integrity
log "running occ integrity:check-core..."
INTEGRITY=$(docker exec drill-nextcloud \
  su -s /bin/sh www-data -c "php /var/www/html/occ integrity:check-core" 2>&1)
RC=$?
if [ $RC -ne 0 ]; then
  fail "integrity:check-core exit $RC: $INTEGRITY"
fi
if [ -n "$INTEGRITY" ]; then
  fail "integrity:check-core reported issues: $INTEGRITY"
fi
log "integrity:check-core: ok (exit 0, no output = clean)"

# 3. File scan — all users
log "running occ files:scan --all (this takes ~15 min on odin)..."
SCAN=$(docker exec drill-nextcloud \
  su -s /bin/sh www-data -c "php /var/www/html/occ files:scan --all" 2>&1)
RC=$?
if [ $RC -ne 0 ]; then
  fail "files:scan exit $RC: $SCAN"
fi
# Extract error count from the table output
ERRORS=$(echo "$SCAN" | grep -oP 'Errors[^|]*\|\s*\K[0-9]+' || echo "?")
if [ "$ERRORS" != "0" ]; then
  fail "files:scan found $ERRORS errors: $SCAN"
fi
log "files:scan: ok ($ERRORS errors)"
echo "$SCAN" | tail -5

log "ALL CHECKS PASSED"
