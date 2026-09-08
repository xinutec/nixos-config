#!/usr/bin/env bash
# FAST drill seed: populate /var/lib/drill/volumes/ directly from
# /var/backup-staging/isis/nextcloud/ without going through
# `restic restore`, at the cost of NOT exercising the restic pipeline
# itself.
#
# The nextcloud tree is not COPIED, it is OVERLAID: staging is the
# read-only lower layer and the scratch's .nc-upper takes every write. The
# copy it replaces was `rsync -aH` over 560G, and it was the whole cost
# of this drill — 4h28m of a 5h15m run on 2026-09-07, which is what put
# the run into `RunDrill`'s ceiling and killed it a minute short of a
# restore that was otherwise sound. It was also pure waste: the fast
# drill BOOTS the staging mirror, so copying it proved only that 560G
# can be duplicated, which nothing needs to know. The full drill
# (drill-seed.sh) still restores from restic, and that is the run that
# proves the backup.
#
# ⚠ The lower layer is the LIVE isis mirror — the tree restic backs up.
# Three things protect it, and all three were probed on odin before this
# landed. Do not remove any of them:
#   1. overlayfs never writes to a lower layer, so the drill's own writes
#      (including modifying a file that exists in staging) cannot reach it;
#   2. `drill-smoke.sh teardown` unmounts before deleting, and REFUSES to
#      delete at all if the unmount fails — every drill script reaches its
#      wipe through it;
#   3. both wipes pass `--one-file-system`, so a mount that survives (2)
#      is skipped rather than deleted through.
#
# Use this for weekly-cadence drills and for iteration. Run the full
# drill (drill-seed.sh) monthly to exercise the restic restore path.
#
# See README.md § "Drill cadence and tiering" for rationale.

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

# ⚠ NOT under $DRILL_DIR. The scratch used to live beside these scripts, inside
# the /etc/nixos checkout — which put a 560G tree in a git working copy and made
# a DELETABLE root contain the scripts doing the deleting. dev-lint refused a
# `DrillScratch` root pointing there (nix-root-exec-mutable-etc) and was right:
# the waiver `drill.dir` carries exists because a drill must exercise the CURRENT
# scripts, and data has no such claim. See #1487.
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
  # A container still holding the tree is the ordinary reason. Stop the stack
  # and try once more.
  #
  # ⚠ NOT `drill-smoke.sh teardown`: that wipes the scratch, and calling it from
  # here would run a deletion over a tree we have just established is STILL
  # MOUNTED over the isis mirror. Stop the containers, nothing else.
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  umount "$NC_MNT" 2>/dev/null || return 1
}

# --- safe deletion ---
safe_rm() {
  local target="$1"
  if [[ -z "$target" ]]; then
    echo "BUG: safe_rm called with empty path" >&2; exit 99
  fi
  case "$target" in
    "$SCRATCH") ;;
    *) echo "BUG: safe_rm refusing unexpected path: $target" >&2; exit 99 ;;
  esac
  rm -rf --one-file-system "$target"
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
  # ⚠ READ THE LOGS BEFORE REMOVING IT. This container used to run with `--rm`,
  # which meant a container that failed to start deleted itself — and took with
  # it the only record of why. The `docker logs` in the readiness timeout below
  # then printed `No such container`, which reads as a missing container rather
  # than as the diagnostic being destroyed. Cost a whole weekly drill on
  # 2026-09-06 with nothing to show for it (#1471).
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

# 1. teardown previous state
log "teardown previous drill stack and wipe $SCRATCH"
./drill-smoke.sh teardown >/dev/null 2>&1 || true
# BEFORE the wipe, always. safe_rm would refuse to cross the mount and fail
# the run, which is the safe outcome but not a useful one.
unmount_nextcloud || true
if mountpoint -q "$NC_MNT"; then
  echo "REFUSING to wipe $SCRATCH: $NC_MNT is still mounted over $SRC/server-data" >&2
  echo "unmount it by hand, then re-run" >&2
  exit 1
fi
safe_rm "$SCRATCH"
mkdir -p "$SCRATCH"/{mysql,redis,nextcloud} "$NC_UPPER" "$NC_WORK"

# 2. nextcloud file tree — overlay, not copy. Seconds, not hours.
# The mirror job REWRITES $SRC, and a lower layer must not change while it is
# mounted. Refuse rather than mount over a tree being rewritten underneath us.
#
# This closes the window at mount time, not for the whole run: the mirror could
# still start while the overlay is up. Two things make that acceptable rather
# than fixed — the schedules do not meet (mirror daily ~02:38, drill Sundays
# 12:00), and dropping the copy takes the drill's hold on staging from over
# five hours to well under one. Closing it properly means teaching the backup
# plan to refuse while a drill overlay is mounted, which is a plan change.
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
# Root password for the throwaway drill-seed-db — a local container torn down
# (--rm) at the end and never exposed off-host, so this is a constant, not a secret.
DRILL_DB_PW=drill-root-pw
# Read the image from docker-compose.yml rather than repeating it here. That file
# is what drill-run.sh's preflight compares against production, so a literal in
# this script is invisible to the guard: production went to mariadb:12.3 and this
# stayed on 11.8, and every load then died with `ERROR 1805 ... mysql.proc ...
# Expected 21, found 22` after a 4-hour restore.
db_image=$(grep 'image:.*mariadb:' "$DRILL_DIR/docker-compose.yml" | awk '{print $2}')
[ -n "$db_image" ] || { echo "BUG: no mariadb image in docker-compose.yml" >&2; exit 99; }
readonly db_image
log "start temporary drill-seed-db ($db_image)"
docker rm -f drill-seed-db >/dev/null 2>&1 || true
# NO `--rm`: the cleanup trap removes it, AFTER reading its logs. See #1471.
docker run -d \
  --name drill-seed-db \
  -e MYSQL_ROOT_PASSWORD=$DRILL_DB_PW \
  -e MYSQL_DATABASE=nextcloud \
  -v "$SCRATCH/mysql:/var/lib/mysql" \
  "$db_image" \
  >/dev/null

# 120 iterations x 2s = FOUR MINUTES, not two. Measured on odin 2026-09-06 with
# the box idle, this container is ready in ~38s, so the budget is generous —
# which is why a timeout here should be read as "something is wrong", not as
# "needs longer".
readonly DB_WAIT_ROUNDS=120
readonly DB_WAIT_SLEEP=2
log "waiting for drill-seed-db to accept authenticated connections (up to $((DB_WAIT_ROUNDS * DB_WAIT_SLEEP))s)..."
for i in $(seq 1 "$DB_WAIT_ROUNDS"); do
  if docker exec drill-seed-db mariadb -uroot --password=$DRILL_DB_PW -e "SELECT 1" >/dev/null 2>&1; then
    log "ready after $((i * DB_WAIT_SLEEP))s"
    break
  fi
  # ⚠ A CONTAINER THAT EXITED IS NOT A SLOW ONE. Without this the loop waits out
  # the full four minutes on a container that died in the first ten seconds, and
  # then reports "did not become ready" — which sends the reader looking for a
  # timeout when what happened was a crash.
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
  // Explicitly setting password to '' here with memcache config
  // prevents redis.config.php from being consulted.
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
# ⚠ NOT "$SCRATCH"/* — the nextcloud entry is an overlay over 560G of
# staging, and du would walk all of it to report a number that is not this
# drill's disk cost. What this drill actually occupies is the upper layer.
du -sh "$SCRATCH/mysql" "$SCRATCH/redis" "$NC_UPPER" | sed 's/^/  /'
printf '  (nextcloud is an overlay over %s/server-data — not counted, not copied)\n' "$SRC"
echo
echo "next: ./drill-smoke.sh up"
echo "=== drill-seed-fast finished $(date -u +%FT%TZ) ==="
