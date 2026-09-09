#!/usr/bin/env bash
# Nextcloud drill: compose wrapper (up / status / teardown).
#
# Stage 1: run `./drill-smoke.sh up` with an EMPTY scratch to let
# Nextcloud auto-install against the drill DB+Redis. Verifies the
# composition itself.
#
# Stage 2: run `./drill-seed.sh <snapshot>` first to populate
# the scratch, then `./drill-smoke.sh up` on the seeded volumes.
#
# See README.md for design.

set -euo pipefail

cd "$(dirname "$0")"

# The drill's scratch, deliberately NOT under this directory — see the note in
# drill-seed-fast.sh and #1487. `docker compose` still runs here, because the
# compose file lives here; only the data moved.
readonly SCRATCH=/var/lib/drill/volumes

cmd=${1:-}

case "$cmd" in
  up)
    echo "[drill] docker compose up -d"
    docker compose up -d
    echo
    echo "[drill] waiting for services to become healthy..."
    for i in $(seq 1 60); do
      db_state=$(docker inspect -f '{{.State.Health.Status}}' drill-db 2>/dev/null || echo missing)
      redis_state=$(docker inspect -f '{{.State.Health.Status}}' drill-redis 2>/dev/null || echo missing)
      nc_running=$(docker inspect -f '{{.State.Running}}' drill-nextcloud 2>/dev/null || echo false)
      web_running=$(docker inspect -f '{{.State.Running}}' drill-web 2>/dev/null || echo false)

      if [ "$db_state" = healthy ] && [ "$redis_state" = healthy ] \
         && [ "$nc_running" = true ] && [ "$web_running" = true ]; then
        echo "[drill] all services up (db=$db_state redis=$redis_state nc=running web=running)"
        break
      fi
      printf '[drill] %2ds: db=%s redis=%s nc=%s web=%s\n' \
        "$((i*5))" "$db_state" "$redis_state" "$nc_running" "$web_running"
      sleep 5
      if [ "$i" -eq 60 ]; then
        echo "[drill] TIMEOUT after 5 minutes" >&2
        exit 1
      fi
    done
    echo
    echo "[drill] HTTP probe: curl http://127.0.0.1:8443/status.php"
    # Nextcloud exposes /status.php as a simple health endpoint that returns
    # JSON once the install is complete. During first-install it may return
    # an HTML maintenance page — that's a valid "stack is up, install is
    # in progress" state.
    curl -sS -o /tmp/drill-status.$$ -w "HTTP %{http_code}\n" \
      http://127.0.0.1:8443/status.php || true
    head -c 400 /tmp/drill-status.$$ || true
    echo
    rm -f /tmp/drill-status.$$
    echo
    echo "[drill] open an SSH tunnel from your workstation to reach the UI:"
    echo "  ssh -L 8443:127.0.0.1:8443 odin.xinutec.org"
    echo "  then browse http://127.0.0.1:8443/"
    ;;

  status)
    docker compose ps
    echo
    echo "--- volumes ---"
    du -sh "$SCRATCH"/* 2>/dev/null || echo "(no volumes yet)"
    ;;

  logs)
    shift
    docker compose logs "$@"
    ;;

  # Stop the stack and release the scratch, WITHOUT deleting anything.
  #
  # Split out of `teardown` so the seed has something to call. The seed used to
  # call `teardown`, which meant a script starting a drill also held the fleet's
  # sharpest `rm` — and there is nothing about "get ready to seed" that needs to
  # be able to delete. Emptying the scratch is the PLAN's job now
  # (`Effect::ClearUnder`, ordered before the restore).
  stop)
    echo "[drill] docker compose down -v --remove-orphans"
    docker compose down -v --remove-orphans
    if mountpoint -q "$SCRATCH/nextcloud"; then
      echo "[drill] unmounting overlay $SCRATCH/nextcloud"
      umount "$SCRATCH/nextcloud" || {
        echo "[drill] $SCRATCH/nextcloud is still mounted; something holds it" >&2
        exit 1
      }
    fi
    echo "[drill] stopped"
    ;;

  teardown)
    "$0" stop
    # ⚠ $SCRATCH/nextcloud MAY BE AN OVERLAY whose lower layer is
    # /var/backup-staging/isis/nextcloud — the live mirror of production, and
    # the source restic backs up. A bare `rm -rf` recurses THROUGH a
    # mountpoint, so it would delete the mirror, not the drill's copy of it.
    # `stop` above unmounts and FAILS if it cannot, so reaching this line means
    # the overlay is gone; the check is repeated anyway because the cost of
    # being wrong here is the mirror.
    if mountpoint -q "$SCRATCH/nextcloud"; then
      echo "[drill] REFUSING to rm $SCRATCH: the overlay over staging is still mounted" >&2
      exit 1
    fi
    echo "[drill] rm -rf $SCRATCH"
    # ⚠ THE LAST `rm` IN THE DRILL, and it runs ONCE, at the END of a run.
    # The seed's copy of this is gone — the plan clears before a restore. This
    # one stays because the alternative is leaving 560G resident between weekly
    # drills, and the plan cannot own it: its goal is satisfied before the
    # restore and is not re-observed after, since the runner forgets only
    # `invalidated_by(&goal.fact)`. See #1487.
    #
    # --one-file-system as a second line of defence: if a mount survives the
    # check above, this refuses to cross it instead of deleting through it.
    rm -rf --one-file-system "$SCRATCH"
    echo "[drill] done"
    ;;

  "")
    echo "usage: $0 {up|status|logs [service...]|stop|teardown}" >&2
    exit 1
    ;;

  *)
    echo "unknown command: $cmd" >&2
    echo "usage: $0 {up|status|logs [service...]|stop|teardown}" >&2
    exit 1
    ;;
esac
