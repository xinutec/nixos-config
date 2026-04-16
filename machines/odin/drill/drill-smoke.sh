#!/usr/bin/env bash
# Nextcloud drill: compose wrapper (up / status / teardown).
#
# Stage 1: run `./drill-smoke.sh up` with EMPTY ./volumes/ to let
# Nextcloud auto-install against the drill DB+Redis. Verifies the
# composition itself.
#
# Stage 2: run `./drill-seed.sh <snapshot>` first to populate
# ./volumes/, then `./drill-smoke.sh up` on the seeded volumes.
#
# See README.md for design.

set -euo pipefail

cd "$(dirname "$0")"

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
      if [ $i -eq 60 ]; then
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
    du -sh ./volumes/* 2>/dev/null || echo "(no volumes yet)"
    ;;

  logs)
    shift
    docker compose logs "$@"
    ;;

  teardown)
    echo "[drill] docker compose down -v --remove-orphans"
    docker compose down -v --remove-orphans
    echo "[drill] rm -rf ./volumes"
    rm -rf ./volumes
    echo "[drill] done"
    ;;

  "")
    echo "usage: $0 {up|status|logs [service...]|teardown}" >&2
    exit 1
    ;;

  *)
    echo "unknown command: $cmd" >&2
    echo "usage: $0 {up|status|logs [service...]|teardown}" >&2
    exit 1
    ;;
esac
