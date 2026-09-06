#!/usr/bin/env bash
# FAST drill seed: populate ./volumes/ directly from
# /var/backup-staging/isis/nextcloud/ without going through
# `restic restore`. ~10× cheaper than drill-seed.sh — finishes in
# minutes instead of hours — at the cost of NOT exercising the
# restic pipeline itself.
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

log() { printf '[drill-seed-fast] %s\n' "$*"; }

# --- safe deletion ---
safe_rm() {
  local target="$1"
  if [[ -z "$target" ]]; then
    echo "BUG: safe_rm called with empty path" >&2; exit 99
  fi
  case "$target" in
    "$DRILL_DIR"/volumes) ;;
    *) echo "BUG: safe_rm refusing unexpected path: $target" >&2; exit 99 ;;
  esac
  rm -rf --one-file-system "$target"
}

# --- sanity checks ---
for cmd in docker rsync zstd; do
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
    log "FAILED (rc=$rc) — ./volumes/ may be partially populated; re-run to retry"
  fi
}
trap cleanup EXIT

# 1. teardown previous state
log "teardown previous drill stack and wipe ./volumes/"
./drill-smoke.sh teardown >/dev/null 2>&1 || true
safe_rm "$DRILL_DIR/volumes"
mkdir -p ./volumes/{mysql,redis,nextcloud}

# 2. nextcloud file tree (local rsync, no SSH, same filesystem)
log "rsync server-data/ → ./volumes/nextcloud/"
# Exit 23 = partial transfer (e.g. symlinks with names exceeding fs limits).
# Acceptable for the drill — a few broken .license symlinks don't affect
# Nextcloud boot or integrity checks.
time rsync -aH --numeric-ids "$SRC/server-data/" ./volumes/nextcloud/ || {
  rc=$?; [ $rc -eq 23 ] && log "rsync partial transfer (exit 23), continuing" || exit $rc
}

# 3. redis RDB
log "cp redis.rdb → ./volumes/redis/dump.rdb"
cp "$SRC/redis.rdb" ./volumes/redis/dump.rdb
chown 999:999 ./volumes/redis/dump.rdb 2>/dev/null || true

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
  -v "$PWD/volumes/mysql:/var/lib/mysql" \
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
log "writing ./volumes/nextcloud/config/zz-drill.config.php"
cat > ./volumes/nextcloud/config/zz-drill.config.php <<'EOF'
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
chown 33:33 ./volumes/nextcloud/config/zz-drill.config.php

log "done"
printf '[drill-seed-fast] ./volumes/ sizes:\n'
du -sh ./volumes/* | sed 's/^/  /'
echo
echo "next: ./drill-smoke.sh up"
echo "=== drill-seed-fast finished $(date -u +%FT%TZ) ==="
