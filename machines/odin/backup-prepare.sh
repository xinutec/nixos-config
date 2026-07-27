#!/usr/bin/env bash
# Assemble /var/backup-staging with DB-consistent dumps + PVC snapshots
# before restic runs. Invoked as ExecStartPre from
# restic-backups-cluster.service (ROOT). Must be idempotent. The staging
# tree is kept between runs for incremental rsync.
#
# See ~/Code/xinutec-infra/backups.md for the recovery-design rationale and
# ~/.claude/plans/golden-nibbling-island.md for the plan.

set -euo pipefail

STAGE=/var/backup-staging
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

log() { printf '[backup-prepare] %s\n' "$*"; }

# Don't wipe the staging tree between runs — the rsync steps use --delete
# to reconcile it in place, and the other outputs (dumps, YAML) are
# overwritten unconditionally. Keeping the tree makes subsequent runs a
# cheap delta instead of paying the full ~200 GiB cost on each run.
install -d -m 0700 "$STAGE"/{amun,isis}
install -d -m 0700 "$STAGE"/isis/nextcloud
install -d -m 0700 "$STAGE"/amun/mailu
install -d -m 0700 "$STAGE"/amun/k3s "$STAGE"/isis/k3s

# Helpers: ssh to a cluster node and run either a raw command or a
# kubectl-exec-inside-a-pod command.
# shellcheck disable=SC2029  # $2 IS the remote command: expanding it here, so ssh
# receives the finished string, is the whole point of the helper.
remote() { ssh "${SSH_OPTS[@]}" "root@$1" "$2"; }

# Resolve a PVC's k3s local-path directory at RUN TIME.
#
# k3s names it pvc-<uid>_<namespace>_<claim>, and the uid is regenerated whenever
# the claim is recreated — so writing the literal path here is a silent-stale trap:
# once a service moves host or a claim is rebuilt, the path no longer exists, and
# under `set -e` that aborts the ENTIRE backup rather than just its own app. That is
# exactly what vaultwarden's pinned uid did when it moved amun -> isis on 2026-07-26,
# and amun's planned from-scratch reinstall would have tripped every amun-side pin at
# once — precisely when the backups matter most.
#
# ⚠ ALWAYS call this into a VARIABLE, never inline in an rsync argument. The abort
# below exits the command substitution's subshell, not the script; an assignment
# propagates that failure and `set -e` stops the run, but inline it would expand to
# the empty string and leave rsync syncing `host:/` with --delete.
pvc_dir() { # host namespace claim -> absolute path
  local d
  d=$(remote "$1" "ls -d /var/lib/rancher/k3s/storage/*_$2_$3 2>/dev/null" | tr -d '\r') || true
  case $d in
    /var/lib/rancher/k3s/storage/pvc-*_"$2"_"$3") printf '%s\n' "$d" ;;
    *)
      echo "FATAL: PVC $2/$3 not resolvable on $1 (got: '${d:-}')" >&2
      echo "       refusing a silent no-op backup" >&2
      exit 1
      ;;
  esac
}

# A dump-over-exec block writes to "<path>.new"; this promotes it only if it is
# non-empty. `set -e` already aborts the whole run when the exec HARD-fails (a
# retired workload, a dead pod) — this catches the SOFT failure: a source that
# exits 0 with no output (a wedged redis, an empty stream), which would otherwise
# silently overwrite the last good dump held in the persisted staging tree.
keep_if_nonempty() {
  if [ -s "$1.new" ]; then
    mv "$1.new" "$1"
  else
    rm -f "$1.new"
    echo "FATAL: empty dump for $1 (source produced no output)" >&2
    exit 1
  fi
}

# ========================================================================
# ISIS — Nextcloud
# ========================================================================

# Dump using crictl exec (NOT kubectl exec). kubectl exec pipes through
# the k8s API server websocket which truncates large output (~880k lines).
# crictl talks directly to containerd — no websocket, complete dump every
# time. The file lands on the PVC bind-mount at a known host path.
NEXTCLOUD_PVC=$(pvc_dir isis.vpn nextcloud nextcloud-storage)
DBPATH="$NEXTCLOUD_PVC/mariadb-data"
log "isis: mariadb-dump nextcloud (crictl exec → file → rsync)"
# Filter by namespace+pod name to pick the nextcloud-db mariadb container,
# not the health-db one (both have container name 'mariadb'). Order of
# `crictl ps --name mariadb` is not stable across pod restarts.
remote isis.vpn \
  "POD_ID=\$(k3s crictl pods --namespace nextcloud --name 'nextcloud-db-.*' -q | head -1) \
   && [ -n \"\$POD_ID\" ] || { echo 'no nextcloud-db pod found'; exit 1; } \
   && CONTAINER=\$(k3s crictl ps -p \"\$POD_ID\" --name mariadb -q | head -1) \
   && [ -n \"\$CONTAINER\" ] || { echo 'no mariadb container in nextcloud-db pod'; exit 1; } \
   && k3s crictl exec \"\$CONTAINER\" sh -c \
      'mariadb-dump --single-transaction --quick --routines --triggers \
                    --all-databases > /var/lib/mysql/dump.sql' \
   && tail -c 100 $DBPATH/dump.sql | grep -q 'Dump completed' \
   && echo \"dump ok: \$(wc -c < $DBPATH/dump.sql) bytes\" \
   || { echo 'dump failed or truncated'; exit 1; }"
remote isis.vpn \
  "zstd -3 -f $DBPATH/dump.sql -o /tmp/nextcloud-dump.sql.zst \
   && rm -f $DBPATH/dump.sql"
rsync -a "root@isis.vpn:/tmp/nextcloud-dump.sql.zst" \
  "$STAGE/isis/nextcloud/mysql-all.sql.zst"
remote isis.vpn 'rm -f /tmp/nextcloud-dump.sql.zst'

# Maintenance mode wraps the redis dump only. A trap ensures we always exit
# maintenance mode even if redis-cli fails or the script is interrupted.
_occ() {
  remote isis.vpn "kubectl -n nextcloud exec deploy/nextcloud-server -c nextcloud -- su -s /bin/sh www-data -c \"php /var/www/html/occ $1\""
}

log "isis: nextcloud maintenance:mode --on"
_occ "maintenance:mode --on"
trap '_occ "maintenance:mode --off" || true' EXIT

log "isis: redis RDB dump"
# The RDB stream is the consistent snapshot; the PVC itself is deliberately
# not rsynced (a live RDB file can be torn mid-write).
# covers-pvc: nextcloud/redis-data-redis-master-0
# Redis requires auth. The bitnami chart (v22+) uses REDIS_PASSWORD_FILE
# instead of REDIS_PASSWORD env var. Read the password from the file inside
# the pod. --no-auth-warning silences stderr so the binary RDB stream on
# stdout stays clean.
# shellcheck disable=SC2016  # single-quoted on purpose: these expand inside the pod,
# where the password file lives — expanding them here would send an empty password.
REDIS_INNER='PW=$(cat "$REDIS_PASSWORD_FILE" 2>/dev/null || echo "$REDIS_PASSWORD"); redis-cli --no-auth-warning -a "$PW" --rdb -'
remote isis.vpn \
  "kubectl -n nextcloud exec statefulset/redis-master -- sh -c '$REDIS_INNER'" \
  > "$STAGE/isis/nextcloud/redis.rdb.new"
keep_if_nonempty "$STAGE/isis/nextcloud/redis.rdb"

log "isis: nextcloud maintenance:mode --off"
_occ "maintenance:mode --off"
trap - EXIT

log "isis: rsync nextcloud server-data"
rsync -aH --numeric-ids --delete \
  "root@isis.vpn:$NEXTCLOUD_PVC/server-data/" \
  "$STAGE/isis/nextcloud/server-data/"

# ========================================================================
# ISIS — Health DB (health-sync MariaDB)
# ========================================================================

# Same crictl-exec pattern as Nextcloud above. The health-db container
# requires the root password from its MARIADB_ROOT_PASSWORD env var;
# we set MYSQL_PWD inside the exec so the secret isn't visible in
# the host's process table.
HEALTH_DBPATH="$(pvc_dir isis.vpn health health-db-pvc)/mariadb-data"
log "isis: mariadb-dump health (crictl exec → file → rsync)"
install -d -m 0700 "$STAGE"/isis/health
remote isis.vpn \
  "POD_ID=\$(k3s crictl pods --namespace health --name 'health-db-.*' -q | head -1) \
   && [ -n \"\$POD_ID\" ] || { echo 'no health-db pod found'; exit 1; } \
   && CONTAINER=\$(k3s crictl ps -p \"\$POD_ID\" --name mariadb -q | head -1) \
   && [ -n \"\$CONTAINER\" ] || { echo 'no mariadb container in health-db pod'; exit 1; } \
   && k3s crictl exec \"\$CONTAINER\" sh -c \
      'MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb-dump -u root --single-transaction --quick --routines --triggers \
                    --all-databases > /var/lib/mysql/dump.sql' \
   && tail -c 100 $HEALTH_DBPATH/dump.sql | grep -q 'Dump completed' \
   && echo \"dump ok: \$(wc -c < $HEALTH_DBPATH/dump.sql) bytes\" \
   || { echo 'dump failed or truncated'; exit 1; }"
remote isis.vpn \
  "zstd -3 -f $HEALTH_DBPATH/dump.sql -o /tmp/health-dump.sql.zst \
   && rm -f $HEALTH_DBPATH/dump.sql"
rsync -a "root@isis.vpn:/tmp/health-dump.sql.zst" \
  "$STAGE/isis/health/health.sql.zst"
remote isis.vpn 'rm -f /tmp/health-dump.sql.zst'

# ========================================================================
# ISIS — Life DB (life app MariaDB: inventory / recipes / shopping / todo)
# ========================================================================

# Same crictl-exec pattern as health above. life-db is the stateless life
# app's only persistent state; the app container never writes to disk.
LIFE_DBPATH="$(pvc_dir isis.vpn life life-db-pvc)/mariadb-data"
log "isis: mariadb-dump life (crictl exec → file → rsync)"
install -d -m 0700 "$STAGE"/isis/life
remote isis.vpn \
  "POD_ID=\$(k3s crictl pods --namespace life --name 'life-db-.*' -q | head -1) \
   && [ -n \"\$POD_ID\" ] || { echo 'no life-db pod found'; exit 1; } \
   && CONTAINER=\$(k3s crictl ps -p \"\$POD_ID\" --name mariadb -q | head -1) \
   && [ -n \"\$CONTAINER\" ] || { echo 'no mariadb container in life-db pod'; exit 1; } \
   && k3s crictl exec \"\$CONTAINER\" sh -c \
      'MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb-dump -u root --single-transaction --quick --routines --triggers \
                    --all-databases > /var/lib/mysql/dump.sql' \
   && tail -c 100 $LIFE_DBPATH/dump.sql | grep -q 'Dump completed' \
   && echo \"dump ok: \$(wc -c < $LIFE_DBPATH/dump.sql) bytes\" \
   || { echo 'dump failed or truncated'; exit 1; }"
remote isis.vpn \
  "zstd -3 -f $LIFE_DBPATH/dump.sql -o /tmp/life-dump.sql.zst \
   && rm -f $LIFE_DBPATH/dump.sql"
rsync -a "root@isis.vpn:/tmp/life-dump.sql.zst" \
  "$STAGE/isis/life/life.sql.zst"
remote isis.vpn 'rm -f /tmp/life-dump.sql.zst'

# ========================================================================
# ISIS — Home DB (home dashboard MariaDB: Govee sensor time-series)
# ========================================================================

# Same crictl-exec pattern as health above. home-db holds the temp/RH/RSSI
# readings the bes/Mac/pixel5 BLE receivers feed in — the app is stateless.
HOME_DBPATH="$(pvc_dir isis.vpn home home-db-pvc)/mariadb-data"
log "isis: mariadb-dump home (crictl exec → file → rsync)"
install -d -m 0700 "$STAGE"/isis/home
remote isis.vpn \
  "POD_ID=\$(k3s crictl pods --namespace home --name 'home-db-.*' -q | head -1) \
   && [ -n \"\$POD_ID\" ] || { echo 'no home-db pod found'; exit 1; } \
   && CONTAINER=\$(k3s crictl ps -p \"\$POD_ID\" --name mariadb -q | head -1) \
   && [ -n \"\$CONTAINER\" ] || { echo 'no mariadb container in home-db pod'; exit 1; } \
   && k3s crictl exec \"\$CONTAINER\" sh -c \
      'MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb-dump -u root --single-transaction --quick --routines --triggers \
                    --all-databases > /var/lib/mysql/dump.sql' \
   && tail -c 100 $HOME_DBPATH/dump.sql | grep -q 'Dump completed' \
   && echo \"dump ok: \$(wc -c < $HOME_DBPATH/dump.sql) bytes\" \
   || { echo 'dump failed or truncated'; exit 1; }"
remote isis.vpn \
  "zstd -3 -f $HOME_DBPATH/dump.sql -o /tmp/home-dump.sql.zst \
   && rm -f $HOME_DBPATH/dump.sql"
rsync -a "root@isis.vpn:/tmp/home-dump.sql.zst" \
  "$STAGE/isis/home/home.sql.zst"
remote isis.vpn 'rm -f /tmp/home-dump.sql.zst'

# ========================================================================
# ISIS — Coach DB (coach app MariaDB)
# ========================================================================

# Same crictl-exec pattern as health above.
COACH_DBPATH="$(pvc_dir isis.vpn coach coach-db-pvc)/mariadb-data"
log "isis: mariadb-dump coach (crictl exec → file → rsync)"
install -d -m 0700 "$STAGE"/isis/coach
remote isis.vpn \
  "POD_ID=\$(k3s crictl pods --namespace coach --name 'coach-db-.*' -q | head -1) \
   && [ -n \"\$POD_ID\" ] || { echo 'no coach-db pod found'; exit 1; } \
   && CONTAINER=\$(k3s crictl ps -p \"\$POD_ID\" --name mariadb -q | head -1) \
   && [ -n \"\$CONTAINER\" ] || { echo 'no mariadb container in coach-db pod'; exit 1; } \
   && k3s crictl exec \"\$CONTAINER\" sh -c \
      'MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb-dump -u root --single-transaction --quick --routines --triggers \
                    --all-databases > /var/lib/mysql/dump.sql' \
   && tail -c 100 $COACH_DBPATH/dump.sql | grep -q 'Dump completed' \
   && echo \"dump ok: \$(wc -c < $COACH_DBPATH/dump.sql) bytes\" \
   || { echo 'dump failed or truncated'; exit 1; }"
remote isis.vpn \
  "zstd -3 -f $COACH_DBPATH/dump.sql -o /tmp/coach-dump.sql.zst \
   && rm -f $COACH_DBPATH/dump.sql"
rsync -a "root@isis.vpn:/tmp/coach-dump.sql.zst" \
  "$STAGE/isis/coach/coach.sql.zst"
remote isis.vpn 'rm -f /tmp/coach-dump.sql.zst'

# ========================================================================
# ISIS — Fleetwatch DB (fleetwatch MariaDB: fleet health history)
# ========================================================================

# Same crictl-exec pattern as health above.
FLEETWATCH_DBPATH="$(pvc_dir isis.vpn fleetwatch fleetwatch-db-pvc)/mariadb-data"
log "isis: mariadb-dump fleetwatch (crictl exec → file → rsync)"
install -d -m 0700 "$STAGE"/isis/fleetwatch
remote isis.vpn \
  "POD_ID=\$(k3s crictl pods --namespace fleetwatch --name 'fleetwatch-db-.*' -q | head -1) \
   && [ -n \"\$POD_ID\" ] || { echo 'no fleetwatch-db pod found'; exit 1; } \
   && CONTAINER=\$(k3s crictl ps -p \"\$POD_ID\" --name mariadb -q | head -1) \
   && [ -n \"\$CONTAINER\" ] || { echo 'no mariadb container in fleetwatch-db pod'; exit 1; } \
   && k3s crictl exec \"\$CONTAINER\" sh -c \
      'MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb-dump -u root --single-transaction --quick --routines --triggers \
                    --all-databases > /var/lib/mysql/dump.sql' \
   && tail -c 100 $FLEETWATCH_DBPATH/dump.sql | grep -q 'Dump completed' \
   && echo \"dump ok: \$(wc -c < $FLEETWATCH_DBPATH/dump.sql) bytes\" \
   || { echo 'dump failed or truncated'; exit 1; }"
remote isis.vpn \
  "zstd -3 -f $FLEETWATCH_DBPATH/dump.sql -o /tmp/fleetwatch-dump.sql.zst \
   && rm -f $FLEETWATCH_DBPATH/dump.sql"
rsync -a "root@isis.vpn:/tmp/fleetwatch-dump.sql.zst" \
  "$STAGE/isis/fleetwatch/fleetwatch.sql.zst"
remote isis.vpn 'rm -f /tmp/fleetwatch-dump.sql.zst'

# ========================================================================
# ISIS — Signal archive (signal-cli message DB + linked-device keys + media)
# ========================================================================

# DB-consistent dump (same crictl-exec pattern as Nextcloud/health above).
SIGNAL_DBPATH="$(pvc_dir isis.vpn signal signal-db-pvc)/mariadb-data"
log "isis: mariadb-dump signal (crictl exec → file → rsync)"
install -d -m 0700 "$STAGE"/isis/signal
remote isis.vpn \
  "POD_ID=\$(k3s crictl pods --namespace signal --name 'signal-db-.*' -q | head -1) \
   && [ -n \"\$POD_ID\" ] || { echo 'no signal-db pod found'; exit 1; } \
   && CONTAINER=\$(k3s crictl ps -p \"\$POD_ID\" --name mariadb -q | head -1) \
   && [ -n \"\$CONTAINER\" ] || { echo 'no mariadb container in signal-db pod'; exit 1; } \
   && k3s crictl exec \"\$CONTAINER\" sh -c \
      'MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\" mariadb-dump -u root --single-transaction --quick --routines --triggers \
                    --all-databases > /var/lib/mysql/dump.sql' \
   && tail -c 100 $SIGNAL_DBPATH/dump.sql | grep -q 'Dump completed' \
   && echo \"dump ok: \$(wc -c < $SIGNAL_DBPATH/dump.sql) bytes\" \
   || { echo 'dump failed or truncated'; exit 1; }"
remote isis.vpn \
  "zstd -3 -f $SIGNAL_DBPATH/dump.sql -o /tmp/signal-dump.sql.zst \
   && rm -f $SIGNAL_DBPATH/dump.sql"
rsync -a "root@isis.vpn:/tmp/signal-dump.sql.zst" \
  "$STAGE/isis/signal/signal.sql.zst"
remote isis.vpn 'rm -f /tmp/signal-dump.sql.zst'

# Linked-device keys/state (signal-cli) — restoring these reconnects the
# archiver without re-linking. Secret-class, but the restic repo is encrypted.
log "isis: rsync signal-cli data PVC (linked-device keys)"
SIGNAL_CLI_PVC=$(pvc_dir isis.vpn signal signal-cli-pvc)
rsync -aH --numeric-ids --delete \
  "root@isis.vpn:$SIGNAL_CLI_PVC/" \
  "$STAGE/isis/signal/signal-cli/"

# Downloaded attachment blobs (media that flowed in via the live feed).
log "isis: rsync signal-attachments PVC (media)"
SIGNAL_ATT_PVC=$(pvc_dir isis.vpn signal signal-attachments-pvc)
rsync -aH --numeric-ids --delete \
  "root@isis.vpn:$SIGNAL_ATT_PVC/" \
  "$STAGE/isis/signal/attachments/"

# ========================================================================
# ISIS — httpd-isis-storage (public share host: dicom-scan + mri-scan.zip)
# ========================================================================

log "isis: rsync httpd-isis-storage PVC (web share host)"
install -d -m 0700 "$STAGE"/isis/httpd-isis
HTTPD_ISIS_PVC=$(pvc_dir isis.vpn web httpd-isis-storage)
rsync -aH --numeric-ids --delete \
  "root@isis.vpn:$HTTPD_ISIS_PVC/" \
  "$STAGE/isis/httpd-isis/"

# ========================================================================
# ISIS — recall (household speech archive: SQLite + the audio itself)
# ========================================================================

# recall is the memory aid. Its audio and the human corrections made against it
# exist nowhere else once the Mac stops holding them, and a correction cannot be
# re-made — so this is the one app here whose loss is not recoverable by re-running
# anything.
#
# SQLite, not MariaDB, so this does NOT take the mariadb-dump shape the blocks above
# share. A live SQLite file must never be copied byte-for-byte: it is in WAL mode and
# written continuously by the worker, so a plain copy ships a torn page that restores
# to a corrupt database. `Connection.backup()` is SQLite's online-backup API — a
# consistent point-in-time image of a database in use — and it runs INSIDE the pod
# because the isis host has no sqlite3 binary.
#
# The snapshot is verified where it is made: PRAGMA integrity_check plus a row count.
# A backup that silently stages a corrupt file is worse than no backup, because it
# looks like one.
RECALL_DATA=$(pvc_dir isis.vpn recall recall-data-pvc)
log "isis: sqlite online-backup recall (crictl exec → snapshot → rsync)"
install -d -m 0700 "$STAGE"/isis/recall
remote isis.vpn \
  "POD_ID=\$(k3s crictl pods --namespace recall --name 'recall-.*' -q | head -1) \
   && [ -n \"\$POD_ID\" ] || { echo 'no recall pod found'; exit 1; } \
   && CONTAINER=\$(k3s crictl ps -p \"\$POD_ID\" --name recall -q | head -1) \
   && [ -n \"\$CONTAINER\" ] || { echo 'no recall container in recall pod'; exit 1; } \
   && k3s crictl exec \"\$CONTAINER\" python -c \"
import sqlite3, sys
src = sqlite3.connect('file:/data/recall.sqlite?mode=ro', uri=True)
dst = sqlite3.connect('/data/.snapshot.sqlite')
src.backup(dst)
if dst.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
    sys.exit('recall snapshot failed integrity_check')
n = dst.execute('SELECT COUNT(*) FROM audio_segments').fetchone()[0]
t = dst.execute('SELECT COUNT(*) FROM transcript_segments').fetchone()[0]
if n == 0 or t == 0:
    sys.exit(f'recall snapshot is empty: {n} segments, {t} turns')
print(f'snapshot ok: {n} segments, {t} turns')
\" \
   || { echo 'recall snapshot failed'; exit 1; }"
rsync -a "root@isis.vpn:$RECALL_DATA/.snapshot.sqlite" \
  "$STAGE/isis/recall/recall.sqlite"
remote isis.vpn "rm -f $RECALL_DATA/.snapshot.sqlite"

# The audio. Excluding the live DB (the snapshot above is the consistent copy of it)
# and the WAL/SHM sidecars, which are meaningless without the file they belong to.
log "isis: rsync recall audio PVC"
rsync -aH --numeric-ids --delete \
  --exclude 'recall.sqlite' --exclude 'recall.sqlite-wal' --exclude 'recall.sqlite-shm' \
  --exclude '.snapshot.sqlite' \
  "root@isis.vpn:$RECALL_DATA/" \
  "$STAGE/isis/recall/audio/"

# ========================================================================
# AMUN — Mailu
# ========================================================================

log "amun: mailu-admin sqlite (cat; sqlite3 not in image)"
remote amun.vpn \
  'kubectl -n mailu-mailserver exec deploy/mailu-admin -- cat /data/main.db' \
  > "$STAGE/amun/mailu/admin.sqlite"

log "amun: rsync mailu-storage PVC (dovecot + rspamd + friends)"
MAILU_PVC=$(pvc_dir amun.vpn mailu-mailserver mailu-storage)
rsync -aH --numeric-ids --delete \
  "root@amun.vpn:$MAILU_PVC/" \
  "$STAGE/amun/mailu/mailu-storage/"

log "amun: mailu redis RDB dump"
# rspamd learned state, the greylist DB, and the in-flight mail queue — the
# gap backups.md used to list as "Real gap". Same dump-over-exec shape as the
# Nextcloud redis above (the RDB stream is the consistent snapshot, the PVC
# itself is never rsynced), minus the auth dance: no redis auth (mailu can't
# authenticate to redis, so it runs unauthenticated). As of 2026-07-24 mailu's
# bundled Bitnami redis subchart was replaced by our own mailu-redis-ext
# (redis:8-alpine, protected-mode off) — dump from that Deployment now.
# covers-pvc: mailu-mailserver/mailu-redis-ext-data
remote amun.vpn \
  'kubectl -n mailu-mailserver exec deploy/mailu-redis-ext -- redis-cli --rdb -' \
  > "$STAGE/amun/mailu/redis.rdb.new"
keep_if_nonempty "$STAGE/amun/mailu/redis.rdb"

log "amun: nocodb (consistent sqlite snapshot + data dir)"
# nocodb keeps its metadata in SQLite at server-data/noco.db, and that database is
# in journal_mode=delete: SQLite mutates the MAIN FILE IN PLACE during a write and
# holds the undo data in a transient noco.db-journal sidecar. A plain rsync taken
# mid-transaction therefore copies a torn page AND misses the journal needed to
# repair it — an unrecoverable copy that reports success every night. This block
# used to be exactly that rsync. Same hazard the vaultwarden block below documents;
# the fix is the same, an online .backup which takes SQLite's own locks.
#
# nocodb is slated for retirement once its data has been migrated out. Until that
# happens it is a live system holding real data, so it gets backed up properly
# rather than approximately.
#
# sqlite3 comes from amun's system closure (machines/amun/configuration.nix), not
# from a `nix-shell -p sqlite` here. Fetching the tool at backup time would make
# this step depend on working internet and an up binary cache, and nix GC evicts it
# again, so it never settles into a cost you have already paid.
NOCODB_PVC=$(pvc_dir amun.vpn nocodb nocodb-storage)
install -d -m 0700 "$STAGE/amun/nocodb"
remote amun.vpn "
  set -eu
  sqlite3 '$NOCODB_PVC/server-data/noco.db' '.backup /tmp/noco-snapshot.db'
  chmod 600 /tmp/noco-snapshot.db
  IC=\$(sqlite3 /tmp/noco-snapshot.db 'PRAGMA integrity_check')
  [ \"\$IC\" = ok ] || { echo \"nocodb snapshot failed integrity_check: \$IC\" >&2; exit 1; }
  N=\$(sqlite3 /tmp/noco-snapshot.db 'SELECT count(*) FROM sqlite_master')
  [ \"\$N\" -gt 0 ] || { echo 'nocodb snapshot is empty' >&2; exit 1; }
  echo \"snapshot ok: \$N schema objects\"
"
rsync -a "root@amun.vpn:/tmp/noco-snapshot.db" "$STAGE/amun/nocodb/noco.db"
remote amun.vpn "rm -f /tmp/noco-snapshot.db"

# Everything else (uploads, thumbnails). The live DB and its sidecars are excluded —
# the snapshot above is the consistent copy of it, and a half-written journal is
# worse than useless next to a good snapshot.
rsync -aH --numeric-ids --delete \
  --exclude 'noco.db' --exclude 'noco.db-journal' \
  --exclude 'noco.db-wal' --exclude 'noco.db-shm' \
  "root@amun.vpn:$NOCODB_PVC/" \
  "$STAGE/amun/nocodb/data/"

log "isis: vaultwarden (consistent sqlite snapshot + data dir)"
# The vault DB is hot SQLite in WAL mode — a plain rsync of db.sqlite3
# can yield a torn copy. Take a consistent online .backup on isis first,
# then rsync everything else (attachments, rsa keys, icon cache).
#
# Moved amun -> isis 2026-07-26. The PVC dir is RESOLVED AT RUN TIME by pvc_dir,
# not pinned: it used to be a hardcoded pvc-98a35778-… UUID, so the move would
# have left this snapshotting amun's frozen copy and still reporting success — a
# silent stale backup of the password manager. pvc_dir fails loudly instead.
#
# sqlite3 comes from isis's system closure (machines/isis/configuration.nix), not
# from a `nix-shell -p sqlite` here — that fetch was 101.6 MiB of stdenv pulled
# from cache.nixos.org in the middle of the backup, i.e. the vault snapshot only
# worked while the network and the binary cache were both up.
VW_PVC=$(pvc_dir isis.vpn vaultwarden vaultwarden-data)
install -d -m 0700 "$STAGE/isis/vaultwarden"
remote isis.vpn \
  "sqlite3 '$VW_PVC/db.sqlite3' '.backup /tmp/vw-db-snapshot.sqlite3' && chmod 600 /tmp/vw-db-snapshot.sqlite3"
rsync -a "root@isis.vpn:/tmp/vw-db-snapshot.sqlite3" "$STAGE/isis/vaultwarden/db.sqlite3"
remote isis.vpn "rm -f /tmp/vw-db-snapshot.sqlite3"
rsync -aH --numeric-ids --delete \
  --exclude 'db.sqlite3' --exclude 'db.sqlite3-wal' --exclude 'db.sqlite3-shm' \
  "root@isis.vpn:$VW_PVC/" \
  "$STAGE/isis/vaultwarden/data/"

log "amun: toktok workspace (preview script → file list → rsync)"
install -d -m 0700 "$STAGE/amun/toktok-workspace"
# Generate the file list on amun. Run the preview script as `pippijn`
# so git doesn't complain about safe.directory (the repos are owned
# by pippijn). The script is piped via SSH stdin so we don't have to
# install it on amun — backup_preview.py lives next to this script
# in nixos-config and is deployed to /etc/backup-preview.py.
# --exclude tools/toktok-fuzzer because its 100+ MB of random binary
# fuzz data is regenerable, not in-flight code (see todo.md).
TOKTOK_FILES=/tmp/toktok-workspace-files.list
# `bash -lc` is needed because python3 only exists in pippijn's
# home-manager nix-profile (~/.nix-profile/bin/python3); plain
# `sudo -u pippijn` runs with root's PATH and can't find it.
ssh "${SSH_OPTS[@]}" root@amun.vpn \
  "sudo -u pippijn bash -lc 'python3 - --print0 --exclude tools/toktok-fuzzer \
     /home/pippijn/code/kubes/vps/toktok/workspace'" \
  < /etc/backup-preview.py \
  > "$TOKTOK_FILES"
# The toktok workspace is a live dev environment — files can vanish in
# the window between the preview-list snapshot above and this rsync.
# --ignore-missing-args skips list entries already gone (without it,
# rsync exits 23 and the whole cluster backup aborts — see 2026-05-18).
# Exit 24 (a file vanishing mid-transfer) is tolerated too; any other
# exit code stays fatal.
rsync -aH --numeric-ids --ignore-missing-args \
  --files-from="$TOKTOK_FILES" --from0 \
  "root@amun.vpn:/home/pippijn/code/kubes/vps/toktok/workspace/" \
  "$STAGE/amun/toktok-workspace/" \
  || { rc=$?; [ "$rc" -eq 24 ] || exit "$rc"; }
rm -f "$TOKTOK_FILES"

log "amun: rsync irssi-storage PVCs (pippijn + simon)"
install -d -m 0700 "$STAGE/amun/irssi-pippijn" "$STAGE/amun/irssi-simon"
IRSSI_PIPPIJN_PVC=$(pvc_dir amun.vpn vps-pippijn irssi-storage)
rsync -aH --numeric-ids --delete \
  "root@amun.vpn:$IRSSI_PIPPIJN_PVC/" \
  "$STAGE/amun/irssi-pippijn/"
IRSSI_SIMON_PVC=$(pvc_dir amun.vpn vps-simon irssi-storage)
rsync -aH --numeric-ids --delete \
  "root@amun.vpn:$IRSSI_SIMON_PVC/" \
  "$STAGE/amun/irssi-simon/"

# ========================================================================
# AMUN — picade fleet (/home/pi)
# ========================================================================
#
# /home/pi holds the picade fleet's canonical state: picade/ (a ~3.5 GB
# full RetroPie rootfs mirror of picade1, the restore source for any
# cabinet), overlay/ (per-host config), and the picade_fleet/ tooling.
# Losing it means losing the fleet's canonical, so it gets the same
# daily snapshot + off-site + integrity coverage as everything else.

log "amun: rsync /home/pi (picade fleet canonical + tooling)"
install -d -m 0700 "$STAGE/amun/picade-home"
# -A -X here (the PVC sources above use plain -aH): picade/ is a full
# rootfs mirror, so ACLs and xattrs — notably file capabilities on
# binaries — must survive a restore. Skip the regenerable python caches
# left behind by running ./check on amun.
rsync -aHAX --numeric-ids --delete \
  --exclude='__pycache__' --exclude='.mypy_cache' --exclude='.pytest_cache' \
  "root@amun.vpn:/home/pi/" \
  "$STAGE/amun/picade-home/"

# ========================================================================
# k3s control-plane: tokens, TLS, snapshot dir (if any), manifest dumps
# ========================================================================
#
# NOTE: `k3s etcd-snapshot save` returns "Unauthorized" on both amun and
# isis (never investigated root cause; the snapshots/ directory is empty
# because the built-in scheduler also appears broken). Documented as an
# open follow-up in upgrade-notes.md. The real recovery path in this
# environment is "rebuild from nixos-config + ~/code/kubes/ manifests +
# PVC restore from restic", so etcd snapshots are a bonus, not a
# requirement. Until the snapshot API is working we skip it entirely
# and rely on the live manifest dump below as the cluster-state capture.

log "amun: k3s token + TLS + any existing snapshots"
rsync -a "root@amun.vpn:/var/lib/rancher/k3s/server/token" \
  "$STAGE/amun/k3s/token"
rsync -aH --numeric-ids --delete \
  "root@amun.vpn:/var/lib/rancher/k3s/server/tls/" \
  "$STAGE/amun/k3s/tls/"
rsync -aH --numeric-ids --delete \
  "root@amun.vpn:/var/lib/rancher/k3s/server/db/snapshots/" \
  "$STAGE/amun/k3s/etcd-snapshots/" 2>/dev/null || true

log "isis: k3s token + TLS + any existing snapshots"
rsync -a "root@isis.vpn:/var/lib/rancher/k3s/server/token" \
  "$STAGE/isis/k3s/token"
rsync -aH --numeric-ids --delete \
  "root@isis.vpn:/var/lib/rancher/k3s/server/tls/" \
  "$STAGE/isis/k3s/tls/"
rsync -aH --numeric-ids --delete \
  "root@isis.vpn:/var/lib/rancher/k3s/server/db/snapshots/" \
  "$STAGE/isis/k3s/etcd-snapshots/" 2>/dev/null || true

log "amun + isis: kubectl manifest dumps"
for host in amun isis; do
  remote "$host.vpn" \
    'kubectl get -A -o yaml \
       deploy,sts,ds,job,cronjob,svc,ing,cm,secret,pvc,pv,sa,role,rolebinding' \
    > "$STAGE/$host/k3s/namespaced.yaml"
  remote "$host.vpn" \
    'kubectl get -o yaml \
       ns,clusterrole,clusterrolebinding,storageclass,ingressclass' \
    > "$STAGE/$host/k3s/cluster.yaml"
  remote "$host.vpn" 'helm list -A -o yaml' \
    > "$STAGE/$host/k3s/helm-releases.yaml" || true
done

log "done — $(du -sh "$STAGE" | cut -f1) staged"
