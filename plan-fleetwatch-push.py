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

**It is deliberately plan-agnostic, and it grades nothing.** The two checks
are the runner's own (`plan-run <plan> --simulate --fleetwatch`, graded once in
plan-core's `fleetwatch.rs`), so a verdict cannot depend on which pusher a host
runs; the envelope and the POST are the same for every plan. So `integrity`
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
  ./plan-fleetwatch-push.py --plan firewall --reads       # the hosts its probes name
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
from pathlib import Path

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


def run_plan(
    plan_run: str, plan: str, settings: str, extra: list[str] | None = None
) -> tuple[int, list[dict[str, object]] | None, str]:
    """`plan-run <plan> --settings … --simulate --fleetwatch [extra…]`, as
    (exit, checks, stderr).

    `extra` carries the arguments a plan REQUIRES and this collector cannot
    guess: `drill` needs `--host`/`--prod-host`. Without them those plans exit
    3 — "a defect in the plan" — and this would report a red every hour for
    ever.

    ⚠ `--apply` is not reachable through it. `extra` is appended AFTER
    `--simulate`, and `plan-run` refuses `--apply --simulate` together rather
    than resolving them by precedence, so a settings file that smuggled the flag
    in makes the run fail loudly instead of converging something unattended.
    That refusal is the runner's, not this script's.

    stdout carries exactly one JSON array by construction — the runner sends
    its narration to stderr under `--fleetwatch`. The checks are None when the
    run produced no parseable array, which is a real state (a defect exit,
    code 3) and not the same as a plan that ran and found nothing.
    """
    proc = subprocess.run(
        [plan_run, plan, "--settings", settings, "--simulate", "--fleetwatch", *(extra or [])],
        capture_output=True,
        text=True,
        timeout=600,
        check=False,  # the exit code is part of the report, read below
    )
    try:
        obj = json.loads(proc.stdout.strip() or "null")
    except json.JSONDecodeError:
        obj = None
    checks = (
        [c for c in obj if isinstance(c, dict)]
        if isinstance(obj, list) and all(isinstance(c, dict) for c in obj)
        else None
    )
    return proc.returncode, checks, proc.stderr


def verdict_checks(plan: str, code: int, checks: list[dict[str, object]] | None,
                   stderr: str) -> list[dict[str, object]]:
    """The runner's checks, or one red check when it produced none.

    Tool breakage is reported as a red check, not as silence: a producer that
    dies quietly looks exactly like a fleet with nothing to say. The label is
    the outcome's, so a dead runner and a blocked plan share one line on the
    board rather than two.
    """
    if checks is None:
        return [{
            "section": plan,
            "label": f"{plan}: outcome",
            "verdict": "fail",
            "observed": f"plan-run produced no report (exit {code})",
            "detail": stderr[-2000:] or "no stderr",
        }]
    return checks


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


def write_last_report(path: Path, report: dict[str, object]) -> None:
    """Leave the report beside the unit's state, whole or not at all.

    `plan-run deploy-check` reads it before a switch and again after, to say
    whether the change made a plan's verdict worse. Written before the push,
    because what the judge said is a fact whether or not fleetwatch heard it;
    renamed into place so a reader never sees half of one.
    """
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(report), encoding="utf-8")
    tmp.replace(path)


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


def parser() -> argparse.ArgumentParser:
    """The CLI, separately so a test can reach it.

    ⚠ **`--arg` must be given as `--arg=VALUE`.** Its values ARE flags —
    `--host`, `--prod-host` — and argparse refuses a separate value beginning
    with `-`, on the reasonable assumption that it is the next option. Written
    as `--arg --host` the unit dies with *expected one argument*, which is what
    happened on odin the first time this shipped. The `=` form takes the value
    literally. `plan-fleetwatch.nix` renders it that way; anything else calling
    this must too.
    """
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
    ap.add_argument("--reads", action="store_true",
                    help="print the hosts the plan's probes name (plan-run --reads) "
                         "and exit; deploy-check asks each judge this")
    ap.add_argument("--last-report", type=Path, default=None, metavar="FILE",
                    help="also write the report here, for deploy-check to compare "
                         "a verdict before a switch with the one after")
    # Repeatable rather than one string to split: a value containing a space
    # would be silently torn in two by a split, and this is how a plan is told
    # which host it is about. argparse hands the list to the runner as argv, so
    # there is no shell between them and nothing to quote.
    ap.add_argument("--arg", action="append", default=[], metavar="ARG",
                    help="extra argument for plan-run, as --arg=VALUE; repeat "
                         "for each. `drill` needs --host and --prod-host, which "
                         "this cannot guess")
    return ap


def main() -> int:
    args = parser().parse_args()

    if args.reads:
        # The judge's own command line, so the answer is about the plan this
        # unit judges, with the arguments it judges it with.
        return subprocess.run(
            [args.plan_run, args.plan, "--settings", args.settings, *args.arg, "--reads"],
            check=False,
        ).returncode

    started = time.monotonic()
    collected_at = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
    try:
        code, obj, stderr = run_plan(args.plan_run, args.plan, args.settings, args.arg)
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

    if args.last_report is not None:
        try:
            write_last_report(args.last_report, report)
        except OSError as e:
            print(f"could not keep the report at {args.last_report}: {e}", file=sys.stderr)

    if args.dry_run:
        print(json.dumps(report, indent=2))
        return 0

    try:
        token = Path(args.token_file).read_text(encoding="utf-8").strip()
    except OSError as e:
        print(f"no ingest token ({e}); see plan-fleetwatch.nix", file=sys.stderr)
        return 1
    return post(args.url, token, report)


if __name__ == "__main__":
    sys.exit(main())
