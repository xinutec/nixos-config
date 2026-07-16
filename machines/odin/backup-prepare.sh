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

# ========================================================================
# ISIS — Nextcloud
# ========================================================================

# Dump using crictl exec (NOT kubectl exec). kubectl exec pipes through
# the k8s API server websocket which truncates large output (~880k lines).
# crictl talks directly to containerd — no websocket, complete dump every
# time. The file lands on the PVC bind-mount at a known host path.
DBPVC="pvc-47f55441-335c-4533-a5d5-e270c4a5b59e_nextcloud_nextcloud-storage"
DBPATH="/var/lib/rancher/k3s/storage/$DBPVC/mariadb-data"
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
  > "$STAGE/isis/nextcloud/redis.rdb"

log "isis: nextcloud maintenance:mode --off"
_occ "maintenance:mode --off"
trap - EXIT

log "isis: rsync nextcloud server-data"
rsync -aH --numeric-ids --delete \
  "root@isis.vpn:/var/lib/rancher/k3s/storage/pvc-47f55441-335c-4533-a5d5-e270c4a5b59e_nextcloud_nextcloud-storage/server-data/" \
  "$STAGE/isis/nextcloud/server-data/"

# ========================================================================
# ISIS — Health DB (health-sync MariaDB)
# ========================================================================

# Same crictl-exec pattern as Nextcloud above. The health-db container
# requires the root password from its MARIADB_ROOT_PASSWORD env var;
# we set MYSQL_PWD inside the exec so the secret isn't visible in
# the host's process table.
HEALTH_DBPVC="pvc-5d1e1a9e-3e3f-4451-aba8-c6d70e10a444_health_health-db-pvc"
HEALTH_DBPATH="/var/lib/rancher/k3s/storage/$HEALTH_DBPVC/mariadb-data"
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
LIFE_DBPVC="pvc-8b4f9606-f8c4-4e02-8b5a-97ecac489cf4_life_life-db-pvc"
LIFE_DBPATH="/var/lib/rancher/k3s/storage/$LIFE_DBPVC/mariadb-data"
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
HOME_DBPVC="pvc-e4221e0c-7331-49e4-9b2c-417020cd0b1c_home_home-db-pvc"
HOME_DBPATH="/var/lib/rancher/k3s/storage/$HOME_DBPVC/mariadb-data"
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
COACH_DBPVC="pvc-201cd057-a8ab-4ff1-abbd-c5e7e4cf9566_coach_coach-db-pvc"
COACH_DBPATH="/var/lib/rancher/k3s/storage/$COACH_DBPVC/mariadb-data"
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
FLEETWATCH_DBPVC="pvc-e4bdd500-3464-478f-b481-08ca58b83437_fleetwatch_fleetwatch-db-pvc"
FLEETWATCH_DBPATH="/var/lib/rancher/k3s/storage/$FLEETWATCH_DBPVC/mariadb-data"
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
SIGNAL_DBPVC="pvc-61696d6d-735d-4f8f-8eef-d2d0a5b6d004_signal_signal-db-pvc"
SIGNAL_DBPATH="/var/lib/rancher/k3s/storage/$SIGNAL_DBPVC/mariadb-data"
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
rsync -aH --numeric-ids --delete \
  "root@isis.vpn:/var/lib/rancher/k3s/storage/pvc-9425bead-7280-4c1b-8708-94f38a795b11_signal_signal-cli-pvc/" \
  "$STAGE/isis/signal/signal-cli/"

# Downloaded attachment blobs (media that flowed in via the live feed).
log "isis: rsync signal-attachments PVC (media)"
rsync -aH --numeric-ids --delete \
  "root@isis.vpn:/var/lib/rancher/k3s/storage/pvc-692ab1c6-6e12-43bb-8bf8-51573a5ceddf_signal_signal-attachments-pvc/" \
  "$STAGE/isis/signal/attachments/"

# ========================================================================
# ISIS — httpd-isis-storage (public share host: dicom-scan + mri-scan.zip)
# ========================================================================

log "isis: rsync httpd-isis-storage PVC (web share host)"
install -d -m 0700 "$STAGE"/isis/httpd-isis
rsync -aH --numeric-ids --delete \
  "root@isis.vpn:/var/lib/rancher/k3s/storage/pvc-21b9cb56-a868-469b-95a4-c5b919829c86_web_httpd-isis-storage/" \
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
RECALL_PVC="pvc-0d2b964f-9ebf-4720-8e9f-b543ca3a0dbb_recall_recall-data-pvc"
RECALL_DATA="/var/lib/rancher/k3s/storage/$RECALL_PVC"
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
rsync -aH --numeric-ids --delete \
  "root@amun.vpn:/var/lib/rancher/k3s/storage/pvc-d50344a0-6803-47e9-9da3-12e3c64f5285_mailu-mailserver_mailu-storage/" \
  "$STAGE/amun/mailu/mailu-storage/"

log "amun: mailu redis RDB dump"
# rspamd learned state, the greylist DB, and the in-flight mail queue — the
# gap backups.md used to list as "Real gap". Same dump-over-exec shape as the
# Nextcloud redis above (the RDB stream is the consistent snapshot, the PVC
# itself is never rsynced), minus the password dance: the mailu chart runs
# its redis with ALLOW_EMPTY_PASSWORD=yes.
# covers-pvc: mailu-mailserver/redis-data-mailu-redis-master-0
remote amun.vpn \
  'kubectl -n mailu-mailserver exec statefulset/mailu-redis-master -- redis-cli --rdb -' \
  > "$STAGE/amun/mailu/redis.rdb"

log "amun: rsync nocodb-storage PVC"
install -d -m 0700 "$STAGE/amun/nocodb"
rsync -aH --numeric-ids --delete \
  "root@amun.vpn:/var/lib/rancher/k3s/storage/pvc-d8296eee-c45f-4f7b-abce-45636659afc1_nocodb_nocodb-storage/" \
  "$STAGE/amun/nocodb/"

log "amun: vaultwarden (consistent sqlite snapshot + data dir)"
# The vault DB is hot SQLite in WAL mode — a plain rsync of db.sqlite3
# can yield a torn copy. Take a consistent online .backup on amun first,
# then rsync everything else (attachments, rsa keys, icon cache).
VW_PVC=/var/lib/rancher/k3s/storage/pvc-98a35778-d544-4fce-87b3-ba7f34dae537_vaultwarden_vaultwarden-data
install -d -m 0700 "$STAGE/amun/vaultwarden"
remote amun.vpn \
  "nix-shell -p sqlite --run 'sqlite3 $VW_PVC/db.sqlite3 \".backup /tmp/vw-db-snapshot.sqlite3\"' && chmod 600 /tmp/vw-db-snapshot.sqlite3"
rsync -a "root@amun.vpn:/tmp/vw-db-snapshot.sqlite3" "$STAGE/amun/vaultwarden/db.sqlite3"
remote amun.vpn "rm -f /tmp/vw-db-snapshot.sqlite3"
rsync -aH --numeric-ids --delete \
  --exclude 'db.sqlite3' --exclude 'db.sqlite3-wal' --exclude 'db.sqlite3-shm' \
  "root@amun.vpn:$VW_PVC/" \
  "$STAGE/amun/vaultwarden/data/"

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
rsync -aH --numeric-ids --delete \
  "root@amun.vpn:/var/lib/rancher/k3s/storage/pvc-1bf60831-9e69-425b-8aff-61eb8a4999a2_vps-pippijn_irssi-storage/" \
  "$STAGE/amun/irssi-pippijn/"
rsync -aH --numeric-ids --delete \
  "root@amun.vpn:/var/lib/rancher/k3s/storage/pvc-b7c7a0df-167d-4fd2-b689-ddd5f861bb28_vps-simon_irssi-storage/" \
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
