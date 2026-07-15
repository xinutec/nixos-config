#!/usr/bin/env python3
"""Push WireGuard peer liveness to fleetwatch, from the VPN hub (amun).

amun is the WireGuard hub (star topology — every peer connects to it), so the
authoritative "which node is up" signal lives right here in `wg show wg0
latest-handshakes`: each peer's last-handshake time. This is strictly better than
probing from the Mac (which sleeps, and only sees its own reachability) — the hub
has the real peer table locally and is always on. If amun itself is down there is
no report at all, and fleetwatch's staleness turns the whole producer red — so
"hub silent" and "VPN down" collapse into the same honest signal.

A peer is UP if it handshaked within --fresh-secs (default 180s, the window `wg`
itself treats as an active handshake). WireGuard only re-handshakes when there is
traffic, so an idle-but-connected mobile peer reads as down — and that is exactly
why each peer carries a LIVENESS CLASS:

  - always-on (servers, the receiver Pi): down is a real fault -> FAIL, which
    reaches the notification channel.
  - intermittent (phones, laptops, picades): down is expected -- they come and go
    -- so it is informational, never an alert -> SKIP; up is still PASS.

The class is `intermittent` in network.nix; a peer without it defaults to always-on,
so a node someone forgot to classify fails loud rather than being silently skipped.

Peer pubkey -> {name, intermittent} comes from network.nix (rendered to JSON by the
NixOS module), so adding a peer there is the only edit ever needed; nothing hardcoded.
The report envelope mirrors mac-mini/fleetwatch_push.py so both producers speak the
same wire format. `source` is NOT sent — fleetwatch derives it from the bearer token.

Run by systemd (fleetwatch-vpn-nodes.service/.timer) every 10 min; --dry-run prints
the report instead of POSTing.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone

SCHEMA = 1
COLLECTOR = "vpn-nodes"
SECTION = "wireguard"
_CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def ulid() -> str:
    """A ULID (48-bit ms timestamp + 80-bit randomness, Crockford base32). fleetwatch
    uses it as the idempotency key. Same construction as the Mac producer."""
    n = (int(time.time() * 1000) << 80) | int.from_bytes(os.urandom(10), "big")
    out = []
    for _ in range(26):
        out.append(_CROCKFORD[n & 0x1F])
        n >>= 5
    return "".join(reversed(out))


def human(secs: int) -> str:
    """A compact age like '45s', '3m', '2h5m', '4d'."""
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h{(secs % 3600) // 60}m"
    return f"{secs // 86400}d{(secs % 86400) // 3600}h"


def latest_handshakes(interface: str) -> list[tuple[str, int]]:
    """`wg show <iface> latest-handshakes` -> [(pubkey, unix_ts)]; ts 0 = never.
    Needs CAP_NET_ADMIN (the service runs as root). Raises on failure so the caller
    can turn tool breakage into a visible FAIL rather than silence."""
    proc = subprocess.run(
        ["wg", "show", interface, "latest-handshakes"],
        capture_output=True, text=True, check=True,
    )
    rows: list[tuple[str, int]] = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            rows.append((parts[0], int(parts[1])))
    return rows


@dataclass(frozen=True)
class Peer:
    """A named WireGuard peer and its liveness class (see module docstring)."""

    name: str
    intermittent: bool


def classify(name: str, intermittent: bool, ts: int, now: int,
             fresh_secs: int) -> dict[str, object]:
    """One peer's last-handshake timestamp -> a verdict check.

    The liveness class decides what DOWN means: an always-on peer that is down is a
    FAIL (a real fault, reaches the alert channel); an intermittent peer that is down
    is expected and stays a SKIP. UP is PASS for both. ts == 0 means the peer has not
    handshaked since wg0 came up. The numeric `value` (handshake age, seconds) drives
    the trend chart and only exists once there has been a handshake to measure."""
    check: dict[str, object] = {"section": SECTION, "label": name}
    if ts == 0:
        check["verdict"] = "skip" if intermittent else "fail"
        check["observed"] = "not connected" if intermittent else "no handshake yet"
        return check
    age = max(0, now - ts)
    check["value"] = float(age)
    check["unit"] = "s"
    if age <= fresh_secs:
        check["verdict"] = "pass"
        check["observed"] = f"handshake {human(age)} ago"
    elif intermittent:
        check["verdict"] = "skip"
        check["observed"] = f"offline: last handshake {human(age)} ago"
    else:
        check["verdict"] = "fail"
        check["observed"] = f"stale: last handshake {human(age)} ago"
    return check


def build_checks(interface: str, peers: dict[str, Peer], fresh_secs: int) -> list[dict[str, object]]:
    """One check per peer, its verdict decided by liveness class (see `classify`). A
    pubkey absent from the map is treated as always-on: an unknown key is far more
    likely a real node nobody named than a device we meant to silence."""
    try:
        rows = latest_handshakes(interface)
    except (subprocess.CalledProcessError, OSError, ValueError) as e:
        detail = getattr(e, "stderr", "") or str(e)
        return [{
            "section": SECTION, "label": "wg show", "verdict": "fail",
            "observed": "wg show failed", "detail": str(detail)[:2000],
        }]

    now = int(time.time())
    checks: list[dict[str, object]] = []
    for pubkey, ts in rows:
        peer = peers.get(pubkey)
        name = peer.name if peer else pubkey[:12]
        intermittent = peer.intermittent if peer else False
        checks.append(classify(name, intermittent, ts, now, fresh_secs))
    checks.sort(key=lambda c: str(c["label"]))
    return checks


def post(url: str, token: str, report: dict[str, object]) -> int:
    req = urllib.request.Request(
        url, data=json.dumps(report).encode(), method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            print(f"pushed {len(report['checks'])} check(s): HTTP {resp.status}")  # type: ignore[arg-type]
            return 0
    except urllib.error.HTTPError as e:
        print(f"push failed: HTTP {e.code} {e.read()[:200]!r}", file=sys.stderr)
        return 1
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        print(f"push failed: {e}", file=sys.stderr)
        return 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--interface", default="wg0")
    p.add_argument("--peers", required=True, help="JSON file mapping wg pubkey -> node name")
    p.add_argument("--token-file", required=True, help="file holding the fleetwatch ingest token")
    p.add_argument("--url", default="https://fleetwatch.xinutec.org/api/reports")
    p.add_argument("--interval", type=int, default=600, help="report interval_s (drives staleness)")
    p.add_argument("--fresh-secs", type=int, default=180, help="max handshake age counted as up")
    p.add_argument("--dry-run", action="store_true", help="print the report, do not POST")
    args = p.parse_args()

    with open(args.peers) as f:
        raw: dict[str, dict[str, object]] = json.load(f)
    peers = {
        pubkey: Peer(
            name=str(entry["name"]),
            intermittent=bool(entry.get("intermittent", False)),
        )
        for pubkey, entry in raw.items()
    }

    t0 = time.monotonic()
    start = datetime.now(timezone.utc)
    checks = build_checks(args.interface, peers, args.fresh_secs)
    report: dict[str, object] = {
        "schema": SCHEMA,
        "id": ulid(),
        "collector": COLLECTOR,
        "collected_at": start.isoformat(),
        "duration_ms": int((time.monotonic() - t0) * 1000),
        "interval_s": args.interval,
        "checks": checks,
    }

    if args.dry_run:
        print(json.dumps(report, indent=2))
        return 0

    try:
        token = open(args.token_file).read().strip()
    except OSError as e:
        print(f"no ingest token ({e}); place it at {args.token_file} (0600). "
              "See machines/amun/vpn-nodes.nix.", file=sys.stderr)
        return 1
    if not token:
        print(f"ingest token file {args.token_file} is empty", file=sys.stderr)
        return 1

    return post(args.url, token, report)


if __name__ == "__main__":
    raise SystemExit(main())
