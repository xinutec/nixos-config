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
time rsync -aH --numeric-ids "$SRC/server-data/" ./volumes/nextcloud/

# 3. redis RDB
log "cp redis.rdb → ./volumes/redis/dump.rdb"
cp "$SRC/redis.rdb" ./volumes/redis/dump.rdb
chown 999:999 ./volumes/redis/dump.rdb 2>/dev/null || true

# 4. mysql: initialize + load dump
log "start temporary drill-seed-db (mysql:8.0.28)"
docker run -d --rm \
  --name drill-seed-db \
  -e MYSQL_ROOT_PASSWORD=drill-root-pw \
  -e MYSQL_DATABASE=nextcloud \
  -v "$PWD/volumes/mysql:/var/lib/mysql" \
  mysql:8.0.28 \
  >/dev/null

log "waiting for drill-seed-db to finish init..."
for i in $(seq 1 120); do
  if docker exec drill-seed-db mysqladmin ping -h localhost -uroot --password=drill-root-pw --silent 2>/dev/null; then
    log "ready after ${i}s"
    break
  fi
  sleep 1
  if [ "$i" -eq 120 ]; then
    echo "TIMEOUT: drill-seed-db did not become ready in 2 minutes" >&2
    docker logs --tail 40 drill-seed-db >&2
    exit 1
  fi
done

log "verifying mysql auth before loading dump..."
docker exec drill-seed-db mysql -uroot --password=drill-root-pw -e "SELECT 'auth-ok'" 2>&1
log "loading mysql dump via stdin..."
time zstd -dc "$SRC/mysql-all.sql.zst" \
  | docker exec -i drill-seed-db mysql -uroot --password=drill-root-pw --binary-mode

log "stopping drill-seed-db"
docker stop drill-seed-db >/dev/null

# 5. drill config override
log "writing ./volumes/nextcloud/config/zz-drill.config.php"
cat > ./volumes/nextcloud/config/zz-drill.config.php <<'EOF'
<?php
// Drill-only overrides. Loaded after config.php in alphabetical
// order so the keys below take precedence.
$CONFIG = array(
  'dbhost' => 'db',
  'trusted_domains' => array('127.0.0.1', 'drill.localhost'),
  'maintenance' => false,
);
EOF
chown 33:33 ./volumes/nextcloud/config/zz-drill.config.php

log "done"
printf '[drill-seed-fast] ./volumes/ sizes:\n'
du -sh ./volumes/* | sed 's/^/  /'
echo
echo "next: ./drill-smoke.sh up"
echo "=== drill-seed-fast finished $(date -u +%FT%TZ) ==="
