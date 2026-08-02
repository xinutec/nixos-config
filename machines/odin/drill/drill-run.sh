#!/usr/bin/env bash
# End-to-end drill orchestrator. Called by the systemd timer or
# manually. Runs the full sequence: seed → up → wait → verify → teardown.
#
# SCOPE (2026-07-14): this drills NEXTCLOUD ONLY. Every other backed-up app
# (recall, signal, life, health, coach, home, fleetwatch, mailu) has a restic
# backup but its restore has never been exercised. The amun reinstall plan leans
# on restore working, so extend coverage — recall first — before trusting it.
#
# Usage:
#   ./drill-run.sh                  # fast drill (weekly default)
#   ./drill-run.sh --full           # full drill via restic restore (monthly)
#   ./drill-run.sh --restore-only   # skip the preflight stages; see below
#
# --restore-only exists for `plan-run drill`, which owns the two preflight
# stages as facts of its own: DrillMatchesProduction and done:drill-dbload are
# both established before it ever chooses to restore. Running them again here
# would be a second description of a check that has already passed — and a second
# description is what this whole port is removing.
#
# It is NOT the flag to use by hand. Invoked without it, this script still does
# its own preflight, because a human running it directly has nothing else to.

set -euo pipefail

DRILL_DIR="$(cd "$(dirname "$0")" && pwd)" || {
  echo "BUG: could not cd to script directory" >&2; exit 99
}
readonly DRILL_DIR
cd "$DRILL_DIR"

readonly LOG="$DRILL_DIR/drill-run.log"
exec > >(tee "$LOG") 2>&1

# A loop rather than `case "$1"`, so the flags compose and an unknown one is
# refused. `case ... *)` silently accepted anything: `--preflight-only`, which
# plan/drill.dhall spent months believing in, fell through to the default and ran
# the entire fast drill.
MODE=fast
SEED_SCRIPT=./drill-seed-fast.sh
PREFLIGHT=yes
for arg in "$@"; do
  case "$arg" in
    --full)         MODE=full; SEED_SCRIPT=./drill-seed.sh ;;
    --restore-only) PREFLIGHT=no ;;
    *) echo "unknown option: $arg" >&2
       echo "usage: $0 [--full] [--restore-only]" >&2
       exit 64 ;;
  esac
done
readonly MODE SEED_SCRIPT PREFLIGHT

echo "=== drill-run ($MODE) starting $(date -u +%FT%TZ) ==="

# Stages 0 and 0b are the plan's when it calls with --restore-only: it has
# already established DrillMatchesProduction and done:drill-dbload as facts, and
# repeating them here would be the second description this port exists to
# delete. Kept for the by-hand path, which has no plan behind it.
if [ "$PREFLIGHT" = yes ]; then

# 0. Preflight: verify drill images match production
echo
echo "=== STAGE: preflight (version sync check) ==="
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
COMPOSE="$DRILL_DIR/docker-compose.yml"

prod_nc=$(ssh "${SSH_OPTS[@]}" root@isis.vpn \
  "kubectl -n nextcloud get deploy/nextcloud-server -o jsonpath='{.spec.template.spec.containers[?(@.name==\"nextcloud\")].image}'" 2>/dev/null || echo "UNKNOWN")
prod_db=$(ssh "${SSH_OPTS[@]}" root@isis.vpn \
  "kubectl -n nextcloud get deploy/nextcloud-db -o jsonpath='{.spec.template.spec.containers[0].image}'" 2>/dev/null || echo "UNKNOWN")

drill_nc=$(grep 'image:.*nextcloud:' "$COMPOSE" | awk '{print $2}')
drill_db=$(grep 'image:.*mariadb:' "$COMPOSE" | awk '{print $2}')

# An unreachable production is NOT a pass. This used to skip the comparison
# whenever the probe returned UNKNOWN, so a failed ssh printed
# "preflight ok: nc=UNKNOWN db=UNKNOWN" and waved the run through — which is
# exactly what happened on 2026-07-26, after production had moved to
# mariadb:12.3 and the drill was still on 11.8. The drill then spent 249 minutes
# restoring before dying on `ERROR 1805 ... mysql.proc ... Expected 21, found 22`,
# the very skew this stage exists to catch. A check that cannot see the thing it
# compares against has failed, not passed.
if [ "$prod_nc" = "UNKNOWN" ] || [ "$prod_db" = "UNKNOWN" ]; then
  echo "FATAL: could not read production images from isis.vpn"
  echo "  nextcloud: $prod_nc"
  echo "  database:  $prod_db"
  echo "Refusing to drill against unverified versions — fix connectivity and re-run."
  exit 2
fi

mismatch=0
if [ "$prod_nc" != "$drill_nc" ]; then
  echo "MISMATCH: nextcloud image"
  echo "  production: $prod_nc"
  echo "  drill:      $drill_nc"
  mismatch=1
fi
if [ "$prod_db" != "$drill_db" ]; then
  echo "MISMATCH: database image"
  echo "  production: $prod_db"
  echo "  drill:      $drill_db"
  mismatch=1
fi
if [ $mismatch -ne 0 ]; then
  echo
  echo "FATAL: drill images out of sync with production."
  echo "Update $COMPOSE to match, then re-run."
  exit 2
fi
echo "preflight ok: nc=$prod_nc db=$prod_db"

# 0b. Preflight: prove the dump actually loads, before paying for the restore.
# Matching image tags (above) is not the same as a loadable dump — a truncated
# dump, a rejected mysqldump flag, or a schema feature the image lacks all fail
# at the import, and the import is the LAST thing the drill reaches. Spending
# five minutes here converts that whole class of failure from a wasted 2.5–4h
# into an immediate answer. `set -e` aborts the drill if it fails.
echo
echo "=== STAGE: preflight (dump loads) ==="
./drill-dbload-check.sh

else
  echo
  echo "=== STAGE: preflight (skipped — the plan established it) ==="
fi

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
for i in $(seq 1 60); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:8443/status.php 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then
    echo "Nextcloud ready after $((i*10))s"
    break
  fi
  printf "  %3ds: HTTP %s\n" "$((i*10))" "$code"
  sleep 10
  if [ "$i" -eq 60 ]; then
    echo "TIMEOUT (600s) waiting for Nextcloud" >&2
    echo "=== HTTP 500 response body ===" >&2
    curl -sS http://127.0.0.1:8443/status.php 2>&1 >&2 || true
    echo >&2
    echo "=== nextcloud.log (app errors) ===" >&2
    docker exec drill-nextcloud cat /var/www/html/data/nextcloud.log 2>/dev/null | tail -20 >&2 || echo "(no nextcloud.log)" >&2
    echo "=== nextcloud container stderr ===" >&2
    docker logs --tail 20 drill-nextcloud >&2
    echo "=== db container logs ===" >&2
    docker logs --tail 10 drill-db >&2
    ./drill-smoke.sh teardown
    exit 1
  fi
done

# 4. Verify (must not let set -e kill us before teardown)
echo
echo "=== STAGE: verify ==="
./drill-verify.sh && VERIFY_RC=0 || VERIFY_RC=$?

# 5. Teardown (always, even if verify failed)
echo
echo "=== STAGE: teardown ==="
./drill-smoke.sh teardown

if [ "$VERIFY_RC" -ne 0 ]; then
  echo
  echo "=== drill-run FAILED (verify exit $VERIFY_RC) $(date -u +%FT%TZ) ==="
  exit 1
fi

echo
echo "=== drill-run PASSED $(date -u +%FT%TZ) ==="

# Dead-man's-switch ping. The check ID is a bearer capability — holding it is
# enough to mark this check UP and silence the alarm — and this repo is public,
# so it comes from agenix rather than from this line. Only the base URL, which
# is documentation rather than a capability, is still spelled out.
#
# This script runs from /etc/nixos under drill-weekly.service, not from the Nix
# store, so the path is literal; the secret is declared in ../backups.nix beside
# the unit. Root-only (0400), which this unit already is.
#
# `|| true` on the whole thing, as before: the drill has already passed by the
# time we get here, and a monitor that cannot be reached is a monitoring
# problem, not a failed restore. If the ping is lost the switch fires anyway,
# which is the safe direction to fail in.
{
  hc_id="$(cat /run/agenix/hc-ping-drill)"
  curl -fsS "https://hc-ping.com/$hc_id" >/dev/null 2>&1
} || true
