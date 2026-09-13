#!/usr/bin/env python3
"""The one-way firewall's ORDER, asserted instead of described.

`base-configuration.nix` renders each host's chain as shell. Two orderings in it are
load-bearing and neither is visible to any other check:

  * the ESTABLISHED accept must precede the DROP, or the chain drops the replies to
    traffic this host itself sent and kills the VPN in the legitimate direction. The
    Mac shipped exactly that on 2026-06-10.
  * ICMPv6 must precede the v6 DROP. A neighbour advertisement carries the sender's
    GLOBAL address, so the fe80::/10 rule does not cover it, and losing Packet Too Big
    makes large transfers HANG rather than fail.

And the chain must be CREATED on every host, one-way or not: `iptables -S` on a chain
that does not exist is an error, which the firewall plan reads as Unreadable rather
than as "declares nothing".

Until this existed all three were comments. A comment only works if whoever edits the
file happens to read the right paragraph first.

    ./firewall_order.py           check every machine
    ./firewall_order.py amun      check one
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHAIN = "xinutec-oneway"
DUMMY_PASSWD = "$6$dummy$" + "x" * 43


def commands(script: str) -> list[str]:
    """The script's COMMANDS: comments and blank lines are not ordering."""
    return [ln.strip() for ln in script.replace("\\n", "\n").split("\n")
            if ln.strip() and not ln.strip().startswith("#")]


def _index(cmds: list[str], *needles: str) -> int | None:
    """First line containing every needle, or None."""
    for i, ln in enumerate(cmds):
        if all(n in ln for n in needles):
            return i
    return None


def violations(cmds: list[str], binary: str) -> list[str]:
    """Order faults for one address family. Empty means the chain is sound."""
    out: list[str] = []
    created = _index(cmds, binary, "-N", CHAIN)
    if created is None:
        out.append(f"{binary}: the {CHAIN} chain is never created — "
                   f"`{binary} -S {CHAIN}` then errors and reads as Unreadable")
        return out

    drop = _index(cmds, binary, f"-A {CHAIN}", "-j DROP")
    if drop is None:
        return out  # not a one-way host: the chain is created and left empty

    est = _index(cmds, binary, f"-A {CHAIN}", "ESTABLISHED")
    if est is None:
        out.append(f"{binary}: no ESTABLISHED accept before the DROP — this chain "
                   f"drops the replies to traffic this host itself sent")
    elif est > drop:
        out.append(f"{binary}: ESTABLISHED accept is AFTER the DROP (line {est} vs "
                   f"{drop}) — kills the tunnel in the legitimate direction")

    if binary == "ip6tables":
        icmp = _index(cmds, binary, f"-A {CHAIN}", "ipv6-icmp")
        if icmp is None:
            out.append("ip6tables: no ICMPv6 accept — neighbour discovery and Packet "
                       "Too Big are dropped, so IPv6 stops working and PMTU HANGS")
        elif icmp > drop:
            out.append(f"ip6tables: ICMPv6 accept is AFTER the DROP (line {icmp} vs "
                       f"{drop}) — same failure as omitting it")

    # ⚠ `binary in ln` is load-bearing: both families render into ONE script, and the
    # v6 chain's accepts sit after the v4 chain's DROP by construction. Without it this
    # reported every one-way host, which looks exactly like a real finding.
    for i, ln in enumerate(cmds):
        if binary in ln and f"-A {CHAIN}" in ln and "-j ACCEPT" in ln and i > drop:
            out.append(f"{binary}: an ACCEPT at line {i} sits AFTER the DROP at "
                       f"{drop}, so it can never match")
    return out


def _render(machine: str, attr: str) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / "tree"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git"))
        dist = (ROOT / "configuration.nix.dist").read_text()
        (work / "configuration.nix").write_text(
            dist.replace("@HOST@", machine).replace("@PASSWD@", DUMMY_PASSWD))
        shutil.copyfile(ROOT / "machines" / machine / "hardware-configuration.nix",
                        work / "hardware-configuration.nix")
        r = subprocess.run(
            ["nix-instantiate", "--eval", "--strict", "<nixpkgs/nixos>", "-A", attr,
             "-I", f"nixos-config={work / 'configuration.nix'}",
             "--argstr", "system", "x86_64-linux"],
            capture_output=True, text=True, check=False)
        if r.returncode != 0:
            raise RuntimeError(f"{machine}: evaluating {attr} failed:\n{r.stderr[-400:]}")
        return r.stdout


def main() -> int:
    wanted = sys.argv[1:]
    machines = sorted(p.name for p in (ROOT / "machines").iterdir() if p.is_dir())
    if wanted:
        machines = [m for m in machines if m in wanted]
    bad = 0
    for m in machines:
        cmds = commands(_render(m, "config.networking.firewall.extraCommands"))
        faults = violations(cmds, "iptables") + violations(cmds, "ip6tables")
        if faults:
            bad += 1
            print(f"✗ {m}")
            for f in faults:
                print(f"    {f}")
        else:
            print(f"✓ {m}")
    if bad:
        print(f"\n{bad} host(s) with a one-way chain that does not hold.", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
