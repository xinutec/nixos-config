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
# Redis requires auth. The bitnami chart (v22+) uses REDIS_PASSWORD_FILE
# instead of REDIS_PASSWORD env var. Read the password from the file inside
# the pod. --no-auth-warning silences stderr so the binary RDB stream on
# stdout stays clean.
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
# ISIS — httpd-isis-storage (public share host: dicom-scan + mri-scan.zip)
# ========================================================================

log "isis: rsync httpd-isis-storage PVC (web share host)"
install -d -m 0700 "$STAGE"/isis/httpd-isis
rsync -aH --numeric-ids --delete \
  "root@isis.vpn:/var/lib/rancher/k3s/storage/pvc-21b9cb56-a868-469b-95a4-c5b919829c86_web_httpd-isis-storage/" \
  "$STAGE/isis/httpd-isis/"

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

log "amun: rsync nocodb-storage PVC"
install -d -m 0700 "$STAGE/amun/nocodb"
rsync -aH --numeric-ids --delete \
  "root@amun.vpn:/var/lib/rancher/k3s/storage/pvc-d8296eee-c45f-4f7b-abce-45636659afc1_nocodb_nocodb-storage/" \
  "$STAGE/amun/nocodb/"

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
