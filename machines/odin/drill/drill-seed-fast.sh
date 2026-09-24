#!/usr/bin/env bash
# Fast drill seed: populate /var/lib/drill/volumes/ from
# /var/backup-staging/isis/nextcloud/ without `restic restore`, so it does not
# exercise the restic pipeline. The full drill (drill-seed.sh, via
# `drill-run.sh --full`) restores from restic and is the run that proves the
# backup; this one is for the routine drill and for iteration.
#
# The nextcloud tree is overlaid, not copied: staging is the read-only lower
# layer and the scratch's .nc-upper takes every write. Copying ~560G took most
# of the drill's time budget and proved nothing the fast drill needs.
#
# The lower layer is the live isis mirror that restic backs up. Three things
# protect it; keep all three:
#   1. overlayfs never writes to a lower layer, even when the drill modifies a
#      file that exists in staging;
#   2. `drill-smoke.sh teardown`, the only deletion of the scratch, unmounts
#      first and refuses to delete if the overlay is still mounted;
#   3. both scratch wipes (teardown's `rm` and the plan's ClearUnder) refuse to
#      cross a filesystem boundary, so a surviving mount is not deleted through.

set -euo pipefail

# Anchor to the script's directory. If cd fails, abort immediately.
DRILL_DIR="$(cd "$(dirname "$0")" && pwd)" || {
  echo "BUG: could not cd to script directory" >&2; exit 99
}
readonly DRILL_DIR
cd "$DRILL_DIR"

# Always log to a file so a broken ssh stream doesn't hide failures.
readonly LOG="$DRILL_DIR/drill-seed-fast.log"
exec > >(tee "$LOG") 2>&1

echo "=== drill-seed-fast starting $(date -u +%FT%TZ) ==="

readonly SRC=/var/backup-staging/isis/nextcloud

# Not under $DRILL_DIR: that is the /etc/nixos checkout, and the scratch must
# not put a 560G deletable tree in a git working copy around the scripts that
# delete it. The `drill.dir` waiver (nix-root-exec-mutable-etc) covers scripts,
# which must be current, not data. See #1487.
readonly SCRATCH=/var/lib/drill/volumes
readonly NC_MNT="$SCRATCH/nextcloud"
readonly NC_UPPER="$SCRATCH/.nc-upper"
readonly NC_WORK="$SCRATCH/.nc-work"

log() { printf '[drill-seed-fast] %s\n' "$*"; }

# --- overlay teardown ---
# Returns 0 only when NC_MNT is genuinely not a mountpoint afterwards.
unmount_nextcloud() {
  mountpoint -q "$NC_MNT" || return 0
  umount "$NC_MNT" 2>/dev/null && return 0
  # A container still holding the tree is the usual reason: stop the stack and
  # retry. `stop`, never `teardown`, which deletes, and the tree is still
  # mounted over the isis mirror here.
  ./drill-smoke.sh stop >/dev/null 2>&1 || true
  umount "$NC_MNT" 2>/dev/null || return 1
}

# --- sanity checks ---
for cmd in docker zstd mount umount mountpoint systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd" >&2; exit 1; }
done

if [ ! -d "$SRC/server-data" ] || [ ! -f "$SRC/mysql-all.sql.zst" ] || [ ! -f "$SRC/redis.rdb" ]; then
  log "staging tree missing expected files at $SRC"
  log "contents:"
  ls -la "$SRC" >&2 || true
  log "did the latest restic-backups-cluster.service run complete?"
  log "if in doubt, run the full drill (./drill-seed.sh) instead"
  exit 1
fi

# --- cleanup trap ---
cleanup() {
  local rc=$?
  # Read the container's state and logs before removing it: they are the only
  # record of why it failed (#1471).
  if docker inspect drill-seed-db >/dev/null 2>&1; then
    if [ $rc -ne 0 ]; then
      log "drill-seed-db state: $(docker inspect \
        -f 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} started={{.State.StartedAt}}' \
        drill-seed-db 2>&1 || echo unreadable)"
      log "drill-seed-db logs (last 50):"
      docker logs --tail 50 drill-seed-db 2>&1 | sed 's/^/    /' || log "  (no logs)"
    fi
    docker stop drill-seed-db >/dev/null 2>&1 || true
    docker rm -f drill-seed-db >/dev/null 2>&1 || true
  fi
  if [ $rc -ne 0 ]; then
    # Leave nothing mounted over staging for the next run to trip on.
    unmount_nextcloud || log "WARNING: $NC_MNT is still mounted — unmount it before re-running"
    log "FAILED (rc=$rc) — $SCRATCH may be partially populated; re-run to retry"
  fi
}
trap cleanup EXIT

# 1. stop whatever is running, and require an empty scratch
#
# This script deletes nothing. The drill plan empties the scratch before the
# restore (Effect::ClearUnder, #1487), so a manual ./drill-run.sh against a
# dirty scratch refuses rather than seeding on top of a previous run.
log "stop previous drill stack"
./drill-smoke.sh stop >/dev/null 2>&1 || true
unmount_nextcloud || true
if mountpoint -q "$NC_MNT"; then
  echo "REFUSING to seed: $NC_MNT is still mounted over $SRC/server-data" >&2
  echo "unmount it by hand, then re-run" >&2
  exit 1
fi
if [ -n "$(find "$SCRATCH" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  echo "REFUSING to seed: $SCRATCH is not empty." >&2
  echo "  Something is left from a previous run. The plan clears it:" >&2
  echo "    plan-run drill --host odin --prod-host isis \\" >&2
  echo "      --settings /etc/plan/settings.json --apply" >&2
  echo "  That runs the whole drill. To clear only, remove it by hand." >&2
  find "$SCRATCH" -mindepth 1 -maxdepth 1 -printf '    %P\n' >&2
  exit 1
fi
mkdir -p "$SCRATCH"/{mysql,redis,nextcloud} "$NC_UPPER" "$NC_WORK"

# 2. nextcloud file tree: overlay, not copy.
# The backup rewrites $SRC, and a lower layer must not change while mounted, so
# refuse to mount while it runs. This covers mount time only; for the rest of a
# run under drill-weekly.service, `Conflicts=` stops the drill when the backup
# starts and ExecStopPost unmounts the overlay (backups.nix).
if systemctl is-active --quiet restic-backups-cluster.service; then
  echo "restic-backups-cluster is running: it rewrites $SRC, which this drill" >&2
  echo "mounts as a read-only overlay lower layer. Wait for it and re-run." >&2
  exit 1
fi
log "overlay $SRC/server-data (ro) + $NC_UPPER (rw) → $NC_MNT"
time mount -t overlay drill-nextcloud \
  -o "lowerdir=$SRC/server-data,upperdir=$NC_UPPER,workdir=$NC_WORK" \
  "$NC_MNT"
mountpoint -q "$NC_MNT" || { echo "BUG: overlay mount reported success but $NC_MNT is not a mountpoint" >&2; exit 99; }

# 3. redis RDB
log "cp redis.rdb → $SCRATCH/redis/dump.rdb"
cp "$SRC/redis.rdb" "$SCRATCH/redis/dump.rdb"
chown 999:999 "$SCRATCH/redis/dump.rdb" 2>/dev/null || true

# 4. mariadb: initialize + load dump
# Root password for the throwaway drill-seed-db, a local container removed by
# the cleanup trap and never exposed off-host: a constant, not a secret.
DRILL_DB_PW=drill-root-pw
# Read the image from docker-compose.yml, which drill-run.sh's preflight compares
# against production; a literal here would escape that check and drift (a
# version mismatch fails the load with `ERROR 1805 ... mysql.proc`).
db_image=$(grep 'image:.*mariadb:' "$DRILL_DIR/docker-compose.yml" | awk '{print $2}')
[ -n "$db_image" ] || { echo "BUG: no mariadb image in docker-compose.yml" >&2; exit 99; }
readonly db_image
log "start temporary drill-seed-db ($db_image)"
docker rm -f drill-seed-db >/dev/null 2>&1 || true
# No `--rm`: the cleanup trap removes it after reading its logs (#1471).
docker run -d \
  --name drill-seed-db \
  -e MYSQL_ROOT_PASSWORD=$DRILL_DB_PW \
  -e MYSQL_DATABASE=nextcloud \
  -v "$SCRATCH/mysql:/var/lib/mysql" \
  "$db_image" \
  >/dev/null

# Four minutes. An idle odin has this container ready in well under one, so a
# timeout means something is wrong, not that it needs longer.
readonly DB_WAIT_ROUNDS=120
readonly DB_WAIT_SLEEP=2
log "waiting for drill-seed-db to accept authenticated connections (up to $((DB_WAIT_ROUNDS * DB_WAIT_SLEEP))s)..."
for i in $(seq 1 "$DB_WAIT_ROUNDS"); do
  if docker exec drill-seed-db mariadb -uroot --password=$DRILL_DB_PW -e "SELECT 1" >/dev/null 2>&1; then
    log "ready after $((i * DB_WAIT_SLEEP))s"
    break
  fi
  # A container that exited is a crash, not a slow start: report it now rather
  # than as a timeout four minutes later.
  if [ "$(docker inspect -f '{{.State.Running}}' drill-seed-db 2>/dev/null)" != "true" ]; then
    echo "drill-seed-db EXITED after $((i * DB_WAIT_SLEEP))s — it crashed, it did not run slow" >&2
    exit 1
  fi
  sleep "$DB_WAIT_SLEEP"
  if [ "$i" -eq "$DB_WAIT_ROUNDS" ]; then
    echo "TIMEOUT: drill-seed-db still running but not accepting connections after $((i * DB_WAIT_SLEEP))s" >&2
    exit 1
  fi
done

# Wait for MariaDB's real server (the init process starts a temp server
# first, shuts it down, then starts the real one — brief socket gap).
sleep 5
log "loading dump via stdin..."
time zstd -dc "$SRC/mysql-all.sql.zst" \
  | docker exec -i drill-seed-db mariadb -uroot --password=$DRILL_DB_PW --binary-mode

log "stopping drill-seed-db"
docker stop drill-seed-db >/dev/null

# 5. drill config override
log "writing $SCRATCH/nextcloud/config/zz-drill.config.php"
cat > "$SCRATCH/nextcloud/config/zz-drill.config.php" <<'EOF'
<?php
// Drill-only overrides. Loaded after config.php in alphabetical
// order so the keys below take precedence. This file overrides both
// the static config.php AND the env-driven redis.config.php /
// reverse-proxy.config.php, since alphabetically 'zz-' loads last.
$CONFIG = array(
  'dbhost' => 'db',
  'trusted_domains' => array('127.0.0.1', 'drill.localhost'),
  'overwritehost' => '127.0.0.1:8443',
  'overwriteprotocol' => 'http',
  'maintenance' => false,
  // Override redis to point at the drill's no-auth redis service.
  // The restored redis.config.php reads REDIS_HOST_PASSWORD from env,
  // which is unset in the drill compose. An empty AUTH to a no-password
  // redis causes "ERR Client sent AUTH, but no password is set".
  // This 'redis' array has no password key and replaces the restored
  // one, so no AUTH is sent.
  'memcache.distributed' => '\OC\Memcache\Redis',
  'memcache.locking' => '\OC\Memcache\Redis',
  'redis' => array(
    'host' => 'redis',
    'port' => 6379,
  ),
);
EOF
chown 33:33 "$SCRATCH/nextcloud/config/zz-drill.config.php"

log "done"
printf '[drill-seed-fast] %s sizes:\n' "$SCRATCH"
# Not "$SCRATCH"/*: the nextcloud entry is an overlay over staging, and du would
# walk all of it. The drill's own disk cost is the upper layer.
du -sh "$SCRATCH/mysql" "$SCRATCH/redis" "$NC_UPPER" | sed 's/^/  /'
printf '  (nextcloud is an overlay over %s/server-data — not counted, not copied)\n' "$SRC"
echo
echo "next: ./drill-smoke.sh up"
echo "=== drill-seed-fast finished $(date -u +%FT%TZ) ==="
