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
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

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

log "isis: mysqldump nextcloud"
remote isis.vpn \
  'kubectl -n nextcloud exec deploy/nextcloud-db -- \
     mysqldump --single-transaction --quick --routines --triggers \
               --all-databases' \
  | zstd -T0 -3 > "$STAGE/isis/nextcloud/mysql-all.sql.zst"

# Maintenance mode wraps the redis dump only. A trap ensures we always exit
# maintenance mode even if redis-cli fails or the script is interrupted.
_occ() {
  remote isis.vpn "kubectl -n nextcloud exec deploy/nextcloud-server -c nextcloud -- su -s /bin/sh www-data -c \"php /var/www/html/occ $1\""
}

log "isis: nextcloud maintenance:mode --on"
_occ "maintenance:mode --on"
trap '_occ "maintenance:mode --off" || true' EXIT

log "isis: redis RDB dump"
# Redis requires auth; password is already in the pod's REDIS_PASSWORD env
# var via the k8s secret. Use sh -c so the env var is expanded inside the
# pod, not on odin or isis. --no-auth-warning silences stderr so the binary
# RDB stream on stdout stays clean.
REDIS_INNER='redis-cli --no-auth-warning -a "$REDIS_PASSWORD" --rdb -'
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
