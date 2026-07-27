#!/usr/bin/env bash
# Restore drill for nocodb: seed from staging -> run the real image against the
# restored data -> assert the RESTORED CONTENT is there -> teardown.
#
# Why this exists: backup-prepare.sh takes a consistent sqlite snapshot of
# nocodb's DB, and that snapshot is verified to open and pass integrity_check.
# That is NOT the same as proving it restores. The restore has a step no
# integrity check can exercise: the staged tree holds the PVC rsync (data/) with
# the live DB deliberately EXCLUDED, plus the good snapshot alongside it
# (noco.db). Restoring means laying the snapshot over the rsync'd directory.
# Restore only data/ and you get a nocodb with no database; restore only
# noco.db and you get a database with no attachments. This drill performs that
# assembly the way a real restore must, so the procedure itself is tested.
#
# ⚠ THE FAILURE MODE THIS GUARDS AGAINST: point nocodb at an empty or wrong
# directory and it does not error — it initialises a BRAND NEW empty noco.db and
# reports itself perfectly healthy. An HTTP 200 therefore proves nothing. Every
# check below asserts restored CONTENT, and compares it against LIVE production.
#
# nocodb is slated for retirement once its data has been migrated out. Until
# that happens it holds real data, so its restore path is drilled like any other.
#
# ⚠ THE CONTAINER RUNS ON amun, NOT ON odin, AND THAT IS A FINDING NOT A CHOICE.
# odin is an Intel Atom N2800: baseline x86-64 with no SSE4.2, no POPCNT, no AVX.
# nocodb 0.257.2 dies there with "Illegal instruction (core dumped)" moments
# after NocoModule initialises — its bundled node v20.15.1 runs fine on odin, so
# it is a native module (the sqlite binding) built for x86-64-v2+. Discovered by
# this drill on 2026-07-27, first time it was ever run.
#
# The DR consequence outlives nocodb: odin holds the backups but CANNOT be the
# emergency run-host for every app it stores. Restoring nocodb requires a
# v2-capable machine (amun's Xeon E3-1245 V2, isis). Do not assume "restore onto
# odin" is a viable recovery plan without checking the image against that CPU.
#
# So: seed and assert on odin (that is where the backup lives), execute on amun
# (that is where nocodb can actually run, and where it runs in production).
#
# Usage: ./drill-nocodb.sh            # full cycle, tears down after
#        ./drill-nocodb.sh --keep     # leave it running for manual poking:
#                                     #   ssh -L 8449:127.0.0.1:8449 amun.xinutec.org

set -euo pipefail

DRILL_DIR="$(cd "$(dirname "$0")" && pwd)" || {
  echo "BUG: could not cd to script directory" >&2; exit 99
}
readonly DRILL_DIR
cd "$DRILL_DIR"

readonly SRC=/var/backup-staging/amun/nocodb
readonly DEST="$DRILL_DIR/volumes/nocodb"
readonly CONTAINER=drill-nocodb
# 8443 is the Nextcloud drill's; keep off it so both can run in one weekly pass.
readonly PORT=8449
readonly SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
# Where the container runs (see the CPU note in the header). Everything under
# RUNDIR on that host is created and destroyed by this script.
readonly RUNHOST=amun.vpn
readonly RUNDIR=/tmp/drill-nocodb

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

log()  { printf '[drill-nocodb] %s\n' "$*"; }
fail() { printf '[drill-nocodb] FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC2029  # $1 IS the remote command: expanding it here, so
# ssh receives the finished string, is the whole point of the helper.
on_run() { ssh "${SSH_OPTS[@]}" "root@$RUNHOST" "$1"; }

teardown() {
  on_run "docker rm -f $CONTAINER >/dev/null 2>&1 || true; rm -rf $RUNDIR" >/dev/null 2>&1 || true
}
# Tear down on ANY exit path, including the fail()s below: a failed drill that
# left the container running would hold the port and make the NEXT run fail on
# something unrelated to the actual defect — and would leave a copy of real data
# sitting in /tmp on a production host.
[ "$KEEP" -eq 1 ] || trap teardown EXIT

# sqlite3 comes from odin's systemPackages (machines/odin/backups.nix).
q() { sqlite3 "file:$1?mode=ro" "$2"; }
# Same query, against the restored copy on the run host.
q_run() { on_run "sqlite3 'file:$1?mode=ro' \"$2\"" | tr -d '\r'; }

log "=== preflight ==="
# Drill the image production actually runs. nocodb migrates its schema on
# startup, so a newer image can silently succeed where the real one would not —
# which would make a green drill actively misleading.
prod_image=$(ssh "${SSH_OPTS[@]}" root@amun.vpn \
  "kubectl -n nocodb get deploy/nocodb-server -o jsonpath='{.spec.template.spec.containers[?(@.name==\"nocodb\")].image}'" \
  2>/dev/null || echo "")
[ -n "$prod_image" ] || fail "could not read the live nocodb image from amun (a drill that cannot check itself against production is not evidence)"
log "image: $prod_image"

[ -f "$SRC/noco.db" ] || fail "$SRC/noco.db missing — has backup-prepare.sh run?"
[ -d "$SRC/data" ]    || fail "$SRC/data missing — has backup-prepare.sh run?"

# What production holds right now. The restored copy is compared against this,
# so an empty-init masquerading as healthy cannot pass.
prod_pvc=$(ssh "${SSH_OPTS[@]}" root@amun.vpn \
  "ls -d /var/lib/rancher/k3s/storage/*_nocodb_nocodb-storage 2>/dev/null" | tr -d '\r')
[ -n "$prod_pvc" ] || fail "could not resolve nocodb's PVC on amun"
# shellcheck disable=SC2029  # $prod_pvc IS resolved here and substituted in
# deliberately: it was just read off amun, and the remote shell has no such var.
prod_bases=$(ssh "${SSH_OPTS[@]}" root@amun.vpn \
  "sqlite3 'file:$prod_pvc/server-data/noco.db?mode=ro' 'SELECT count(*) FROM nc_bases_v2'" | tr -d '\r')
log "production bases: $prod_bases"
[ "${prod_bases:-0}" -gt 0 ] || fail "production reports 0 bases — refusing to drill against a meaningless baseline"

log "=== seed (assemble the restore: PVC rsync + snapshot overlay) ==="
teardown
rm -rf "$DEST"
mkdir -p "$DEST"

# Step 1: the PVC contents as rsync'd. nocodb's data lives under server-data/ in
# the PVC and is mounted at /usr/app/data via subPath, so that subdir IS the
# volume root here.
[ -d "$SRC/data/server-data" ] || \
  fail "$SRC/data/server-data missing — staged layout changed and the restore procedure below is now wrong"
cp -a "$SRC/data/server-data/." "$DEST/"

# Step 2: overlay the consistent snapshot. The rsync deliberately excluded the
# live DB (a torn copy is worse than none), so without this step the restore has
# every attachment and no database at all.
cp -a "$SRC/noco.db" "$DEST/noco.db"
# Stale sidecars would let sqlite try to replay a journal against a snapshot it
# does not belong to.
rm -f "$DEST/noco.db-journal" "$DEST/noco.db-wal" "$DEST/noco.db-shm"
chmod 600 "$DEST/noco.db"
log "seeded $(du -sh "$DEST" | cut -f1) into $DEST"

# What the SNAPSHOT claims, read before nocodb ever touches it.
snap_bases=$(q "$SRC/noco.db" "SELECT count(*) FROM nc_bases_v2")
snap_objects=$(q "$SRC/noco.db" "SELECT count(*) FROM sqlite_master")
log "snapshot: $snap_bases bases, $snap_objects schema objects"
[ "$snap_bases" = "$prod_bases" ] || \
  fail "snapshot has $snap_bases bases but production has $prod_bases — the backup is stale or partial"

log "=== ship the restored tree to $RUNHOST ==="
teardown
on_run "mkdir -p $RUNDIR" || fail "could not create $RUNDIR on $RUNHOST"
rsync -a --delete "$DEST/" "root@$RUNHOST:$RUNDIR/" || fail "rsync to $RUNHOST failed"

log "=== up (on $RUNHOST) ==="
# Bound to 127.0.0.1 on the run host: this is a production machine and the drill
# must not put an unauthenticated copy of real data on a reachable port.
on_run "docker run -d --name $CONTAINER \
  -p 127.0.0.1:$PORT:8080 \
  -v $RUNDIR:/usr/app/data \
  $prod_image" >/dev/null || fail "docker run on $RUNHOST failed"

log "waiting for nocodb on $RUNHOST:127.0.0.1:$PORT ..."
ready=0
for i in $(seq 1 60); do
  code=$(on_run "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/dashboard 2>/dev/null || echo 000" | tr -d '\r')
  case "$code" in
    200|302) log "responding after $((i*5))s (HTTP $code)"; ready=1; break ;;
  esac
  sleep 5
done
if [ "$ready" -ne 1 ]; then
  echo "=== container logs ===" >&2
  on_run "docker logs --tail 40 $CONTAINER" >&2 || true
  fail "nocodb did not respond within 300s"
fi

log "=== verify (content, not liveness) ==="
# nocodb has now opened the DB and may have run migrations against it, so read
# the file back from disk rather than trusting the pre-start numbers.
live_bases=$(q_run "$RUNDIR/noco.db" "SELECT count(*) FROM nc_bases_v2")
live_objects=$(q_run "$RUNDIR/noco.db" "SELECT count(*) FROM sqlite_master")
log "restored instance: $live_bases bases, $live_objects schema objects"

# THE check: a fresh empty init reports 0 bases while serving HTTP 200 happily.
[ "$live_bases" = "$prod_bases" ] || \
  fail "restored instance has $live_bases bases, production has $prod_bases — nocodb did not open the restored DB (a fresh empty init would look exactly like this)"

# Migrations may ADD schema objects, so this is a floor, not equality.
[ "$live_objects" -ge "$snap_objects" ] || \
  fail "restored DB lost schema objects ($snap_objects -> $live_objects)"

# The DB must still be structurally sound after the container has written to it.
ic=$(q_run "$RUNDIR/noco.db" "PRAGMA integrity_check")
[ "$ic" = "ok" ] || fail "restored DB failed integrity_check after startup: $ic"

log "ALL CHECKS PASSED — $live_bases bases restored and served by $prod_image on $RUNHOST"
if [ "$KEEP" -eq 1 ]; then
  log "left running on $RUNHOST 127.0.0.1:$PORT (--keep)"
  log "  reach it with: ssh -L $PORT:127.0.0.1:$PORT ${RUNHOST%.vpn}.xinutec.org"
  log "  clean up with: ssh root@$RUNHOST 'docker rm -f $CONTAINER; rm -rf $RUNDIR'"
fi
