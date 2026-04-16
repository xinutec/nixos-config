#!/usr/bin/env bash
# End-to-end drill orchestrator. Called by the systemd timer or
# manually. Runs the full sequence: seed → up → wait → verify → teardown.
#
# Usage:
#   ./drill-run.sh              # fast drill (weekly default)
#   ./drill-run.sh --full       # full drill via restic restore (monthly)

set -euo pipefail

DRILL_DIR="$(cd "$(dirname "$0")" && pwd)" || {
  echo "BUG: could not cd to script directory" >&2; exit 99
}
readonly DRILL_DIR
cd "$DRILL_DIR"

readonly LOG="$DRILL_DIR/drill-run.log"
exec > >(tee "$LOG") 2>&1

MODE=${1:-fast}
case "$MODE" in
  --full) SEED_SCRIPT=./drill-seed.sh ;;
  *)      SEED_SCRIPT=./drill-seed-fast.sh ;;
esac

echo "=== drill-run ($MODE) starting $(date -u +%FT%TZ) ==="

# Ensure any previous drill is cleaned up
./drill-smoke.sh teardown >/dev/null 2>&1 || true

# 1. Seed
echo
echo "=== STAGE: seed ==="
"$SEED_SCRIPT"

# 2. Bring stack up
echo
echo "=== STAGE: up ==="
./drill-smoke.sh up

# 3. Wait for Nextcloud to be ready (FPM init after existing-install
#    detection is fast, but give it up to 5 minutes)
echo
echo "=== STAGE: wait for nextcloud ==="
for i in $(seq 1 30); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/status.php 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then
    echo "Nextcloud ready after $((i*10))s"
    break
  fi
  printf "  %3ds: HTTP %s\n" "$((i*10))" "$code"
  sleep 10
  if [ "$i" -eq 30 ]; then
    echo "TIMEOUT waiting for Nextcloud" >&2
    docker logs --tail 30 drill-nextcloud >&2
    ./drill-smoke.sh teardown
    exit 1
  fi
done

# 4. Verify
echo
echo "=== STAGE: verify ==="
./drill-verify.sh
VERIFY_RC=$?

# 5. Teardown (always, even if verify failed)
echo
echo "=== STAGE: teardown ==="
./drill-smoke.sh teardown

if [ $VERIFY_RC -ne 0 ]; then
  echo
  echo "=== drill-run FAILED (verify exit $VERIFY_RC) $(date -u +%FT%TZ) ==="
  exit 1
fi

echo
echo "=== drill-run PASSED $(date -u +%FT%TZ) ==="
