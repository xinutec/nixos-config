#!/usr/bin/env bash
# Stage-2 FULL drill seed: populate ./volumes/ from a restic snapshot
# so that `./drill-smoke.sh up` starts Nextcloud against real data.
#
# This is the SLOW variant (~4 hours on odin) that exercises the full
# restic restore path. For weekly-cadence drills use drill-seed-fast.sh
# which copies from /var/backup-staging/ directly (~15 min).
#
# See README.md for context. Run on odin.
#
#   ./drill-seed.sh                 # use 'latest' snapshot
#   ./drill-seed.sh <snapshot-id>   # use a specific snapshot

set -euo pipefail

# Anchor to the script's directory. If cd fails, abort immediately.
DRILL_DIR="$(cd "$(dirname "$0")" && pwd)" || {
  echo "BUG: could not cd to script directory" >&2; exit 99
}
readonly DRILL_DIR
cd "$DRILL_DIR"

# Always log to a file so a broken ssh stream doesn't hide failures.
readonly LOG="$DRILL_DIR/drill-seed.log"
exec > >(tee "$LOG") 2>&1

echo "=== drill-seed starting $(date -u +%FT%TZ) ==="

readonly SNAPSHOT=${1:-latest}
readonly RESTIC_REPO=/backup/restic
readonly RESTIC_PW_FILE=/etc/nixos/secrets/restic-password
readonly STAGING_PATH=/var/backup-staging/isis/nextcloud
readonly RESTORE_TMP=$(mktemp -d /tmp/drill-restore-XXXXXX)

log() { printf '[drill-seed] %s\n' "$*"; }

# --- safe deletion ---
# Only deletes paths matching an explicit allowlist. Uses
# --one-file-system so a stray bind mount can't cause cross-filesystem
# damage.
safe_rm() {
  local target="$1"
  if [[ -z "$target" ]]; then
    echo "BUG: safe_rm called with empty path" >&2; exit 99
  fi
  case "$target" in
    /tmp/drill-restore-*) ;;
    "$DRILL_DIR"/volumes)  ;;
    *) echo "BUG: safe_rm refusing unexpected path: $target" >&2; exit 99 ;;
  esac
  rm -rf --one-file-system "$target"
}

# --- sanity checks ---
for cmd in restic docker rsync zstd mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd" >&2; exit 1; }
done
[ -r "$RESTIC_PW_FILE" ] || { echo "$RESTIC_PW_FILE not readable" >&2; exit 1; }

# --- cleanup trap ---
# On SUCCESS: remove the restore tmp dir (it's large).
# On FAILURE: rename it to .failed so it can be inspected, and log the
#             failure. We never silently delete evidence of a crash.
cleanup() {
  local rc=$?
  docker inspect drill-seed-db >/dev/null 2>&1 && \
    docker stop drill-seed-db >/dev/null 2>&1 || true
  if [ $rc -eq 0 ]; then
    log "cleaning up $RESTORE_TMP (success)"
    safe_rm "$RESTORE_TMP"
  else
    local failed_dir="${RESTORE_TMP}.failed"
    if [ -d "$RESTORE_TMP" ] && [ "$(ls -A "$RESTORE_TMP" 2>/dev/null)" ]; then
      mv "$RESTORE_TMP" "$failed_dir"
      log "FAILED (rc=$rc) — restore tree preserved at $failed_dir for inspection"
    else
      log "FAILED (rc=$rc) — restore tree was empty or missing"
      safe_rm "$RESTORE_TMP"
    fi
    log "./volumes/ may be partially populated; re-run drill-seed.sh to retry"
  fi
}
trap cleanup EXIT

# 1. teardown any previous state
log "teardown previous drill stack and wipe ./volumes/"
./drill-smoke.sh teardown >/dev/null 2>&1 || true
safe_rm "$DRILL_DIR/volumes"
mkdir -p ./volumes/{mysql,redis,nextcloud}

# 2. restore from restic
log "restic restore '$SNAPSHOT' (path=$STAGING_PATH) → $RESTORE_TMP"
restic -r "$RESTIC_REPO" --password-file "$RESTIC_PW_FILE" \
  restore "$SNAPSHOT" \
  --target "$RESTORE_TMP" \
  --include "$STAGING_PATH"

readonly SRC="$RESTORE_TMP$STAGING_PATH"
if [ ! -d "$SRC/server-data" ] || [ ! -f "$SRC/mysql-all.sql.zst" ] || [ ! -f "$SRC/redis.rdb" ]; then
  echo "restored tree missing expected files under $SRC" >&2
  echo "contents of $SRC:" >&2
  ls -la "$SRC" >&2 || echo "(directory does not exist)" >&2
  echo "contents of $RESTORE_TMP:" >&2
  find "$RESTORE_TMP" -maxdepth 5 -type d >&2 || true
  exit 1
fi

# 3. nextcloud file tree
log "rsync server-data/ → ./volumes/nextcloud/"
rsync -aH --numeric-ids "$SRC/server-data/" ./volumes/nextcloud/

# 4. redis RDB
log "cp redis.rdb → ./volumes/redis/dump.rdb"
cp "$SRC/redis.rdb" ./volumes/redis/dump.rdb
chown 999:999 ./volumes/redis/dump.rdb 2>/dev/null || true

# 5. mysql: initialize + load dump
log "start temporary drill-seed-db (mysql:8.0.28)"
docker run -d --rm \
  --name drill-seed-db \
  -e MYSQL_ROOT_PASSWORD=drill-root-pw \
  -e MYSQL_DATABASE=nextcloud \
  -v "$PWD/volumes/mysql:/var/lib/mysql" \
  mysql:8.0.28 \
  >/dev/null

log "waiting for drill-seed-db to accept authenticated connections..."
for i in $(seq 1 120); do
  if docker exec drill-seed-db mysql -uroot --password=drill-root-pw -e "SELECT 1" >/dev/null 2>&1; then
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

log "loading mysql dump via stdin (this may take a few minutes)..."
time zstd -dc "$SRC/mysql-all.sql.zst" \
  | docker exec -i drill-seed-db mysql -uroot --password=drill-root-pw

log "stopping drill-seed-db"
docker stop drill-seed-db >/dev/null

# 6. drill config override
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

# 7. cleanup handled by trap (removes $RESTORE_TMP on success,
#    preserves it as .failed on failure)
log "done"
printf '[drill-seed] ./volumes/ sizes:\n'
du -sh ./volumes/* | sed 's/^/  /'
echo
echo "next: ./drill-smoke.sh up"
echo "=== drill-seed finished $(date -u +%FT%TZ) ==="
