#!/usr/bin/env bash
# Load the staged Nextcloud dump into a throwaway DB container and assert it
# lands. ~5 minutes; no rsync, no restic, no compose stack.
#
# Why this exists, given drill-run.sh already compares image tags: the tag
# comparison proves the drill's mariadb MATCHES production, which is not the
# same as proving the dump LOADS. A matching version still fails on a truncated
# or half-written dump, on a mysqldump written with flags the server rejects,
# and on a prod-side schema feature the image does not implement. Those all
# surface at exactly the same place — the import — and the import is the last
# thing the drill reaches, after ~2.5h of rsync (fast) or ~4h of restic
# restore (full).
#
# That is what made 2026-07-26 expensive: 249 minutes of restore, then a
# 10-second import died on `ERROR 1805 ... mysql.proc ... Expected 21, found 22`.
# Running the import FIRST turns that class of failure from a wasted afternoon
# into a five-minute answer.
#
# Reads:  the staged dump (read-only) and docker-compose.yml.
# Writes: a scratch datadir under /var/tmp, removed on success and deliberately
#         KEPT on failure so the container can be inspected.
#
# Standalone:  ./drill-dbload-check.sh
# In the drill: drill-run.sh calls it as stage 0b, before seeding.

set -euo pipefail

DRILL_DIR="$(cd "$(dirname "$0")" && pwd)" || {
  echo "BUG: could not cd to script directory" >&2; exit 99
}
readonly DRILL_DIR
cd "$DRILL_DIR"

readonly SRC=/var/backup-staging/isis/nextcloud
readonly DATADIR=/var/tmp/drill-dbload-check
readonly NAME=drill-dbload-check
# Throwaway container, torn down at the end and never exposed off-host: this is
# a constant, not a secret. Same reasoning as drill-seed-fast.sh.
readonly PW=drill-root-pw

log() { printf '[dbload-check] %s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

for cmd in docker zstd; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd" >&2; exit 1; }
done

teardown() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  case "$DATADIR" in
    /var/tmp/drill-dbload-check) rm -rf --one-file-system "$DATADIR" ;;
    *) echo "BUG: refusing to remove unexpected path: $DATADIR" >&2; exit 99 ;;
  esac
}

# Clean up ONLY on success. A failed run must leave the container behind or the
# `docker logs` that explains the failure is gone before anyone can read it.
on_exit() {
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    teardown
  else
    echo "[dbload-check] FAILED — left '$NAME' and $DATADIR for inspection:" >&2
    echo "[dbload-check]   docker logs $NAME | tail -50" >&2
    echo "[dbload-check] clean up with: docker rm -f $NAME; rm -rf $DATADIR" >&2
  fi
  exit "$rc"
}
trap on_exit EXIT

# Same provenance as drill-seed-fast.sh: read the tag, never repeat it here. A
# literal would be invisible to drill-run.sh's version-sync preflight.
# `|| true` so the explicit check below reports the missing tag, rather than
# `set -e` aborting the assignment with no explanation.
db_image=$(grep 'image:.*mariadb:' "$DRILL_DIR/docker-compose.yml" | awk '{print $2}') || true
[ -n "$db_image" ] || { echo "BUG: no mariadb image in docker-compose.yml" >&2; exit 99; }
readonly db_image

[ -f "$SRC/mysql-all.sql.zst" ] || {
  echo "MISSING: $SRC/mysql-all.sql.zst — has backup-prepare run?" >&2; exit 1
}

log "image:  $db_image"
log "dump:   $(du -h "$SRC/mysql-all.sql.zst" | cut -f1)  ($(date -u -r "$SRC/mysql-all.sql.zst" +%FT%TZ))"

# --- start the server ---------------------------------------------------------
# odin's Atom is slow enough that the image's OWN entrypoint sometimes gives up
# waiting for the temporary server it starts during datadir init ("Unable to
# start server", container exits 1). Measured 2026-07-29 over four cold starts,
# same image and a fresh datadir every time: two aborted at 44s, two reached an
# authenticated connection at 50s and 54s. So it is intermittent, not a
# reproducible cold-start failure — near enough the entrypoint's own timeout
# that it lands on either side of it. That timeout is inside the image and is
# not ours to raise, so allow ONE retry and say so loudly. A second failure is a
# real failure and fails the drill: this retry exists for a known-marginal
# startup, not to paper over a broken image.
start_db() {
  teardown
  mkdir -p "$DATADIR"
  docker run -d --name "$NAME" \
    -e MYSQL_ROOT_PASSWORD="$PW" \
    -e MYSQL_DATABASE=nextcloud \
    -v "$DATADIR:/var/lib/mysql" \
    "$db_image" >/dev/null || return 1

  local i status
  for i in $(seq 1 150); do
    if docker exec "$NAME" mariadb -uroot --password="$PW" -e "SELECT 1" >/dev/null 2>&1; then
      log "server ready after $((i * 2))s"
      return 0
    fi
    status=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo gone)
    if [ "$status" != "running" ]; then
      log "container is '$status' after $((i * 2))s (entrypoint gave up during init)"
      return 1
    fi
    sleep 2
  done
  log "server never accepted connections within 300s"
  return 1
}

if ! start_db; then
  log "RETRYING ONCE — odin's startup is marginal for this image; a second failure is real"
  docker logs --tail 20 "$NAME" 2>&1 | sed 's/^/[dbload-check]   /' || true
  if ! start_db; then
    echo "[dbload-check] RESULT: FAILED — $db_image cannot start on this host" >&2
    exit 1
  fi
fi

# The entrypoint shuts its temporary server down and starts the real one; there
# is a brief socket gap between the two.
sleep 5

# --- load ---------------------------------------------------------------------
log "loading dump (the step that fails when prod and drill have diverged)..."
# `|| load_rc=$?` keeps `set -e` from killing the script before the codes can be
# read and reported. This is not a masked failure: PIPESTATUS is captured on the
# next line and checked immediately below.
load_rc=0
zstd -dc "$SRC/mysql-all.sql.zst" \
  | docker exec -i "$NAME" mariadb -uroot --password="$PW" --binary-mode || load_rc=$?
rc=("${PIPESTATUS[@]}")
log "exit codes: zstd=${rc[0]} mariadb=${rc[1]} (pipeline=$load_rc)"
if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -ne 0 ]; then
  echo "[dbload-check] RESULT: FAILED — the dump does not load into $db_image" >&2
  exit 1
fi

# --- assert it actually landed ------------------------------------------------
# A zero exit from the pipe is not proof: assert on content, or this check
# passes on an empty dump.
# `|| true` so a query that errors falls through to the assertion below and is
# reported as "not a Nextcloud DB", instead of aborting with a bare exit code.
tables=$(docker exec "$NAME" mariadb -uroot --password="$PW" --skip-column-names -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='nextcloud';" 2>/dev/null | tr -d '[:space:]') || true
users=$(docker exec "$NAME" mariadb -uroot --password="$PW" --skip-column-names -e \
  "SELECT COUNT(*) FROM nextcloud.oc_users;" 2>/dev/null | tr -d '[:space:]') || true

log "restored: nextcloud=${tables:-0} tables, oc_users=${users:-0} rows"
if [ "${tables:-0}" -lt 100 ] || [ "${users:-0}" -lt 1 ]; then
  echo "[dbload-check] RESULT: FAILED — dump loaded but the result is not a Nextcloud DB" >&2
  echo "[dbload-check]   expected >=100 tables and >=1 user; got ${tables:-0} / ${users:-0}" >&2
  exit 1
fi

log "RESULT: PASSED — $db_image loads the staged dump cleanly"
