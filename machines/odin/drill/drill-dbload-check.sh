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
# Standalone:  ./drill-dbload-check.sh [ARTIFACT]     (default: nextcloud)
# In the drill: drill-run.sh calls it as stage 0b, before seeding.
#
# ⚠ WHAT AN ARTIFACT ARGUMENT BUYS, and what it does not. 37 artifacts are staged
# and five have ever had a restore performed; this proves the WEAKER claim
# `Loadable` — the dump imports into a matching server — for any of them in about
# five minutes, where drilling one is hours (#1162). It does NOT prove the app
# comes up against the result; that is `Drilled`, and only Nextcloud and nocodb
# have it.
#
# Every one of these dumps is `--all-databases` from ONE code path
# (`plan/runner/src/script.rs::sql`), so they all load identically and the dump
# creates its own schemas. That is why this generalises at all.

set -euo pipefail

DRILL_DIR="$(cd "$(dirname "$0")" && pwd)" || {
  echo "BUG: could not cd to script directory" >&2; exit 99
}
readonly DRILL_DIR
cd "$DRILL_DIR"

# The artifact to check, and where its dump lands. ⚠ The paths are the model's
# (`backup.dhall`'s `into`), and are repeated here rather than asked for because
# `plan-run backup-report` blocks unless `BackupStaging` is declared to the
# runner — true on odin, false on the Mac, so a script that asked would work here
# and fail wherever anyone tested it. Keep this list in step with `backup.dhall`;
# the mismatch is caught by the missing-file check below, loudly and immediately.
ARTIFACT="${1:-nextcloud}"
case "$ARTIFACT" in
  nextcloud)  readonly DUMP=/var/backup-staging/isis/nextcloud/mysql-all.sql.zst ;;
  health)     readonly DUMP=/var/backup-staging/isis/health/health.sql.zst ;;
  life)       readonly DUMP=/var/backup-staging/isis/life/life.sql.zst ;;
  home)       readonly DUMP=/var/backup-staging/isis/home/home.sql.zst ;;
  coach)      readonly DUMP=/var/backup-staging/isis/coach/coach.sql.zst ;;
  fleetwatch) readonly DUMP=/var/backup-staging/isis/fleetwatch/fleetwatch.sql.zst ;;
  tasks)      readonly DUMP=/var/backup-staging/isis/tasks/tasks.sql.zst ;;
  signal)     readonly DUMP=/var/backup-staging/isis/signal/signal.sql.zst ;;
  *) echo "unknown artifact: $ARTIFACT" >&2
     echo "known: nextcloud health life home coach fleetwatch tasks signal" >&2
     echo "(these are every artifact in backup.dhall whose 'into' ends .sql.zst)" >&2
     exit 2 ;;
esac
readonly ARTIFACT
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

[ -f "$DUMP" ] || {
  echo "MISSING: $DUMP — has the backup staged $ARTIFACT?" >&2; exit 1
}

log "image:  $db_image"
log "artifact: $ARTIFACT"
log "dump:   $(du -h "$DUMP" | cut -f1)  ($(date -u -r "$DUMP" +%FT%TZ))"

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
zstd -dc "$DUMP" \
  | docker exec -i "$NAME" mariadb -uroot --password="$PW" --binary-mode || load_rc=$?
rc=("${PIPESTATUS[@]}")
log "exit codes: zstd=${rc[0]} mariadb=${rc[1]} (pipeline=$load_rc)"
if [ "${rc[0]}" -ne 0 ] || [ "${rc[1]}" -ne 0 ]; then
  echo "[dbload-check] RESULT: FAILED — the dump does not load into $db_image" >&2
  exit 1
fi

# --- assert it actually landed ------------------------------------------------
# A zero exit from the pipe is not proof: assert on content, or this check passes
# on an empty dump.
#
# ⚠ THE GENERIC ASSERTION IS THE POINT, not a weakening. `Loadable` claims the
# dump imports into a matching server and produces real schemas — no more. An
# assertion naming one app's tables could only ever cover that app, and a
# per-artifact table of sentinel tables would be judgement retyped into bash,
# which is what this programme exists to remove. So: at least one NON-SYSTEM
# schema, carrying tables, carrying rows. That is exactly the claim being made.
q() { docker exec "$NAME" mariadb -uroot --password="$PW" --skip-column-names \
        -e "$1" 2>/dev/null | tr -d "[:space:]"; }

# ⚠ The exclusion list is ONE variable, and the SQL below contains no nested
# quotes at all. An earlier version inlined `'"'"'mysql'"'"',…` in each query;
# it worked when pasted into a shell and did NOT work from the script file — the
# filter silently stopped applying, so the check counted the four system schemas
# as data and then found no rows in them. It reported 5 schemas / 482 tables for
# a dump that has 1 / 181, and FAILED a perfectly good Nextcloud dump. A form
# that behaves differently depending on how it is invoked is not worth debugging.
SYS="'mysql','information_schema','performance_schema','sys'"

schemas=$(q "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ($SYS);") || true
tables=$(q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ($SYS);") || true
# information_schema.tables.table_rows is an ESTIMATE on InnoDB and reads 0 for
# populated tables, so it cannot carry an assertion. Ask the largest table for a
# real count. Schema and name come back as two fields and are joined in shell,
# so no SQL string here needs a quote of its own.
biggest=$(docker exec "$NAME" mariadb -uroot --password="$PW" --skip-column-names \
  -e "SELECT table_schema, table_name FROM information_schema.tables \
      WHERE table_schema NOT IN ($SYS) AND table_type = 'BASE TABLE' \
      ORDER BY data_length DESC LIMIT 1;" 2>/dev/null | awk '{print $1 "." $2}') || true
rows=0
if [ -n "${biggest:-}" ]; then rows=$(q "SELECT COUNT(*) FROM $biggest;") || true; fi

log "restored: ${schemas:-0} schema(s), ${tables:-0} table(s); ${biggest:-none} has ${rows:-0} row(s)"
if [ "${schemas:-0}" -lt 1 ] || [ "${tables:-0}" -lt 1 ] || [ "${rows:-0}" -lt 1 ]; then
  echo "[dbload-check] RESULT: FAILED — the dump loaded but produced no data" >&2
  echo "[dbload-check]   expected >=1 schema, >=1 table and a non-empty largest table;" >&2
  echo "[dbload-check]   got ${schemas:-0} / ${tables:-0} / ${rows:-0}" >&2
  exit 1
fi

# Nextcloud keeps its ORIGINAL, stronger assertion on top of the generic one.
# `drill-run.sh` calls this as stage 0b and has relied on it since 2026-07-26;
# generalising a check is no reason to weaken the one case already covered.
if [ "$ARTIFACT" = nextcloud ]; then
  nc_tables=$(q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = \"nextcloud\";") || true
  nc_users=$(q "SELECT COUNT(*) FROM nextcloud.oc_users;") || true
  log "nextcloud: ${nc_tables:-0} tables, oc_users=${nc_users:-0} rows"
  if [ "${nc_tables:-0}" -lt 100 ] || [ "${nc_users:-0}" -lt 1 ]; then
    echo "[dbload-check] RESULT: FAILED — loaded, but the result is not a Nextcloud DB" >&2
    echo "[dbload-check]   expected >=100 tables and >=1 user; got ${nc_tables:-0} / ${nc_users:-0}" >&2
    exit 1
  fi
fi

log "RESULT: PASSED — $db_image loads the staged $ARTIFACT dump cleanly"
