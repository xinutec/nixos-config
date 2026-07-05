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
  docker inspect drill-seed-db >/dev/null 2>&1 && \
    docker stop drill-seed-db >/dev/null 2>&1 || true
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
DRILL_DB_PW=drill-root-pw  # dev-lint: allow-secret throwaway local drill-seed-db
log "start temporary drill-seed-db (mariadb:11.8)"
docker rm -f drill-seed-db >/dev/null 2>&1 || true
docker run -d --rm \
  --name drill-seed-db \
  -e MYSQL_ROOT_PASSWORD=$DRILL_DB_PW \
  -e MYSQL_DATABASE=nextcloud \
  -v "$PWD/volumes/mysql:/var/lib/mysql" \
  mariadb:11.8 \
  >/dev/null

log "waiting for drill-seed-db to accept authenticated connections..."
for i in $(seq 1 120); do
  if docker exec drill-seed-db mariadb -uroot --password=$DRILL_DB_PW -e "SELECT 1" >/dev/null 2>&1; then
    log "ready after ${i}s"
    break
  fi
  sleep 2
  if [ "$i" -eq 120 ]; then
    echo "TIMEOUT: drill-seed-db did not become ready" >&2
    docker logs --tail 40 drill-seed-db >&2
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
