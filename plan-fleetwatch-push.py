#!/usr/bin/env python3
"""Run a `plan-run` plan read-only and report its verdict to fleetwatch.

**Why this exists.** A plan that converges on two machines and tells nobody is
a check that only works while somebody is watching a terminal. #728's firewall
plan is the case that forced it: it can find a rule nobody declared — the thing
that sat in amun's FORWARD chain for 88 days — and until this, finding it and
saying it were different problems.

**Why not a systemd unit going red.** That IS the tempting answer, and it is
the anti-pattern this fleet keeps designing out: fleetwatch does not collect
systemd unit state, so a unit that fails is a red nobody sees. A push puts the
verdict where the other producers already put theirs.

**It is deliberately plan-agnostic.** The envelope, the check shape and the
POST are the same for every plan; what differs is the plan name. So `integrity`
(#52), `backup`, `offsite` and `drill` can each get a timer without a second
copy of this file. The wire format mirrors `machines/amun/vpn-nodes-push.py`,
`picade_fleet.fleetwatch` and `mac-mini/fleetwatch_push.py` so all four
producers speak one dialect.

**`source` is never sent.** fleetwatch derives it from the bearer token, so a
producer can only ever write as its own mapped source — odin's token makes odin,
isis's makes isis. That is the whole guarantee the token design has, and it is
why each machine needs its OWN token rather than a shared one.

**Read-only, always.** `--simulate`, never `--apply`, and not configurable:
this is a reporting job. Simulate rather than the default observe because
observe stops at the first pending step and leaves every later goal unread,
which would report a partially-read plan as if it were the whole one — the same
distinction `picade_fleet.health` reads this object for.

  ./plan-fleetwatch-push.py --plan firewall --dry-run     # print, do not POST
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
from datetime import datetime, timezone

SCHEMA = 1
DEFAULT_URL = "https://fleetwatch.xinutec.org/api/reports"
DEFAULT_TOKEN_FILE = "/var/lib/fleetwatch/token"
DEFAULT_SETTINGS = "/etc/plan/settings.json"

_CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def ulid() -> str:
    """A ULID (48-bit ms timestamp + 80-bit randomness, Crockford base32),
    fleetwatch's idempotency key. Same construction as the other producers, so
    at-least-once delivery here plus fleetwatch's dedupe on the id is
    effectively exactly-once."""
    n = (int(time.time() * 1000) << 80) | int.from_bytes(os.urandom(10), "big")
    out = []
    for _ in range(26):
        out.append(_CROCKFORD[n & 0x1F])
        n >>= 5
    return "".join(reversed(out))


def run_plan(plan_run: str, plan: str, settings: str) -> tuple[int, dict[str, object] | None, str]:
    """`plan-run <plan> --settings … --simulate --json`, as (exit, object, stderr).

    stdout carries exactly one object by construction — the runner sends its
    progress narration to stderr under `--json` precisely so a collector need
    not strip anything. The object is None when the run produced no parseable
    stdout, which is a real state (a defect exit, code 3) and not the same as a
    plan that ran and found nothing.
    """
    proc = subprocess.run(
        [plan_run, plan, "--settings", settings, "--simulate", "--json"],
        capture_output=True,
        text=True,
        timeout=600,
    )
    try:
        obj = json.loads(proc.stdout.strip() or "null")
    except json.JSONDecodeError:
        obj = None
    return proc.returncode, obj if isinstance(obj, dict) else None, proc.stderr


def verdict_checks(plan: str, code: int, obj: dict[str, object] | None,
                   stderr: str) -> list[dict[str, object]]:
    """The plan's report → fleetwatch checks.

    TWO checks, and the second is not decoration. `outcome` says whether the
    plan is satisfied; `verified` says how much of it was actually READ. A run
    that converged because every probe was unreadable is not a run that found
    the world in order, and reporting only the first would restate #734 one
    layer up — this time with nobody at a terminal to notice.

    Labels are qualified by plan (`firewall: outcome`), because fleetwatch
    matches mutes on (source, collector, label) and ignores section: a bare
    `outcome` would be shared by every plan on the host, so muting one would
    silence them all.
    """
    if obj is None:
        return [{
            "section": plan,
            "label": f"{plan}: outcome",
            "verdict": "fail",
            "observed": f"plan-run produced no report (exit {code})",
            "detail": stderr[-2000:] or "no stderr",
        }]

    outcome = str(obj.get("outcome", "?"))
    detail = str(obj.get("detail", ""))
    # 0 converged or stood down; 1 blocked; 2 work pending; 3 a defect. Pending
    # is a warn rather than a fail: on a read-only plan it means the world has
    # drifted and the run correctly declined to change it.
    status = {0: "pass", 1: "fail", 2: "warn", 3: "fail"}.get(code, "fail")
    fact = str(obj.get("fact", ""))
    checks: list[dict[str, object]] = [{
        "section": plan,
        "label": f"{plan}: outcome",
        "verdict": status,
        "observed": f"{outcome}: {detail}" if detail else outcome,
    }]
    if fact:
        # WHICH goal, not just that one failed. The firewall plan's two rows are
        # different alarms — a declared rule missing is usually a deploy, a rule
        # nobody declared is the #727 shape — and a verdict that named neither
        # would send someone to read both.
        checks[0]["detail"] = f"fact: {fact}"

    held, unread, adrift = (_count(obj, k) for k in ("held", "unread", "adrift"))
    if held is None or unread is None or adrift is None:
        # NOT a default of zero. "0 could not be read" is the strongest claim
        # this producer makes, and a runner whose report changed shape must not
        # be able to make it by omission — that is #734 with the evidence
        # removed rather than merely unstated.
        checks.append({
            "section": plan,
            "label": f"{plan}: verified",
            "verdict": "fail",
            "observed": "the report carried no goal counts",
            "detail": f"held={obj.get('held')!r} unread={obj.get('unread')!r} "
                      f"adrift={obj.get('adrift')!r}",
        })
        return checks

    if held + unread + adrift == 0:
        # A run that BLOCKED short-circuits before it counts anything, so all
        # three are zero — and "0 could not be read" then reads as a clean bill
        # of health for a run that established nothing at all. Found by
        # ablation on isis 2026-08-12: with iptables off the unit's PATH the
        # outcome check failed correctly and this one still said `pass`.
        checks.append({
            "section": plan,
            "label": f"{plan}: verified",
            "verdict": "warn",
            "observed": "the run established nothing about this plan",
            "detail": "no goal was resolved either way; see the outcome check",
        })
        return checks

    checks.append({
        "section": plan,
        "label": f"{plan}: verified",
        "verdict": "pass" if unread == 0 and adrift == 0 else "warn",
        "observed": f"{held} held, {unread} could not be read, {adrift} did not hold",
        "value": float(unread + adrift),
        "unit": "goals",
    })
    return checks


def _count(obj: dict[str, object], key: str) -> int | None:
    """One of the runner's three goal counts, or None if it is not there.

    The object came off a JSON boundary, so `object` is the truth about the
    field's type and narrowing it IS the check. `bool` is excluded explicitly
    because it is a subclass of `int` in Python, and `True` reported as a count
    of 1 would be a number nobody wrote.
    """
    value = obj.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def build_report(plan: str, checks: list[dict[str, object]], *, interval_s: int,
                 duration_ms: int, collected_at: str, report_id: str) -> dict[str, object]:
    """Assemble the envelope. Pure — the timestamp, id and duration are passed
    in so a test can pin them."""
    return {
        "schema": SCHEMA,
        "id": report_id,
        "collector": f"plan-{plan}",
        "collected_at": collected_at,
        "duration_ms": duration_ms,
        "interval_s": interval_s,
        "checks": checks,
    }


def post(url: str, token: str, report: dict[str, object]) -> int:
    req = urllib.request.Request(
        url,
        data=json.dumps(report).encode(),
        method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            checks = report["checks"]
            n = len(checks) if isinstance(checks, list) else 0
            print(f"pushed {n} check(s): HTTP {resp.status}")
            return 0
    except urllib.error.HTTPError as e:
        print(f"fleetwatch refused the report: HTTP {e.code} {e.read()[:300]!r}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"could not reach fleetwatch: {e}", file=sys.stderr)
        return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--plan", required=True, help="plan name, e.g. firewall")
    ap.add_argument("--plan-run", default="plan-run", help="path to the plan-run binary")
    ap.add_argument("--settings", default=DEFAULT_SETTINGS)
    ap.add_argument("--token-file", default=DEFAULT_TOKEN_FILE)
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--interval", type=int, default=3600,
                    help="seconds between scheduled runs; fleetwatch uses it to "
                         "decide when this producer has gone silent")
    ap.add_argument("--dry-run", action="store_true", help="print the report instead of POSTing")
    args = ap.parse_args()

    started = time.monotonic()
    collected_at = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
    try:
        code, obj, stderr = run_plan(args.plan_run, args.plan, args.settings)
    except (OSError, subprocess.SubprocessError) as e:
        # Tool breakage is reported as a red check, not as silence. A producer
        # that dies quietly looks exactly like a fleet with nothing to say.
        code, obj, stderr = 3, None, str(e)

    report = build_report(
        args.plan,
        verdict_checks(args.plan, code, obj, stderr),
        interval_s=args.interval,
        duration_ms=int((time.monotonic() - started) * 1000),
        collected_at=collected_at,
        report_id=ulid(),
    )

    if args.dry_run:
        print(json.dumps(report, indent=2))
        return 0

    try:
        token = open(args.token_file, encoding="utf-8").read().strip()
    except OSError as e:
        print(f"no ingest token ({e}); see plan-fleetwatch.nix", file=sys.stderr)
        return 1
    return post(args.url, token, report)


if __name__ == "__main__":
    sys.exit(main())
