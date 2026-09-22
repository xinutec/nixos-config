#!/usr/bin/env python3
"""The order of root's ssh_config, asserted instead of described.

ssh_config takes the FIRST value it obtains for a keyword, so a block's position
decides which key a host is offered. Two orderings in base-configuration.nix matter
and neither is visible to any other check:

  * `Host github.com` must precede `Match localuser root`. Otherwise the root match
    pins id_fleet for GitHub as well, and id_fleet is authorised on the fleet, not on
    GitHub.
  * the github block must name a key that is not the fleet key, for the same reason.

The failure is latent, which is why a comment was not enough: `builtins.fetchGit`
only reaches the network for a revision the store lacks, so every rebuild succeeds
and the first pin bump fails.

    ./ssh_config_order.py           check every machine
    ./ssh_config_order.py amun      check one
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FLEET_KEY = "id_fleet"
DUMMY_PASSWD = "$6$dummy$" + "x" * 43


def directives(config: str) -> list[tuple[str, str]]:
    """(keyword, argument) per non-empty line, keywords lowercased.

    ssh_config is case-insensitive in keywords, so a check that matched `Host`
    exactly would pass a config spelled `host` while ssh read it the same.
    """
    out: list[tuple[str, str]] = []
    for line in config.split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        out.append((parts[0].lower(), parts[1].strip() if len(parts) > 1 else ""))
    return out


def _first(items: list[tuple[str, str]], keyword: str, arg: str | None = None) -> int | None:
    for i, (k, a) in enumerate(items):
        if k == keyword and (arg is None or a == arg):
            return i
    return None


def violations(items: list[tuple[str, str]]) -> list[str]:
    """Order faults in one host's ssh_config. Empty means it holds."""
    out: list[str] = []
    gh = _first(items, "host", "github.com")
    root_match = _first(items, "match", "localuser root")
    if root_match is not None and gh is None:
        out.append(
            f"`Match localuser root` pins {FLEET_KEY} and there is no `Host github.com` "
            f"block before it, so root offers the fleet key to GitHub."
        )
        return out
    if gh is None or root_match is None:
        return out  # a host declaring neither has no ordering to get wrong

    if gh > root_match:
        out.append(
            f"`Host github.com` (line {gh}) comes AFTER `Match localuser root` "
            f"(line {root_match}). ssh_config takes the FIRST value for a keyword, so "
            f"root would offer {FLEET_KEY} to GitHub — a key authorised on the fleet "
            f"and not on GitHub."
        )

    # The identity the github block names, i.e. the first IdentityFile after it.
    gh_identity = None
    for k, a in items[gh + 1 :]:
        if k in ("host", "match"):
            break
        if k == "identityfile":
            gh_identity = a
            break
    if gh_identity is None:
        out.append("`Host github.com` names no IdentityFile, so root falls back to "
                   "whatever the later match pins.")
    elif FLEET_KEY in gh_identity:
        out.append(f"`Host github.com` names {gh_identity}, the FLEET key. That key is "
                   f"authorised on the fleet, not on GitHub.")
    return out


def _render(machine: str) -> str:
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / "tree"
        shutil.copytree(ROOT, work, ignore=shutil.ignore_patterns(".git"))
        dist = (ROOT / "configuration.nix.dist").read_text()
        (work / "configuration.nix").write_text(
            dist.replace("@HOST@", machine).replace("@PASSWD@", DUMMY_PASSWD))
        shutil.copyfile(ROOT / "machines" / machine / "hardware-configuration.nix",
                        work / "hardware-configuration.nix")
        r = subprocess.run(
            ["nix-instantiate", "--eval", "--strict", "--json", "<nixpkgs/nixos>",
             "-A", "config.programs.ssh.extraConfig",
             "-I", f"nixos-config={work / 'configuration.nix'}",
             "--argstr", "system", "x86_64-linux"],
            capture_output=True, text=True, check=False)
        if r.returncode != 0:
            raise RuntimeError(f"{machine}: evaluating ssh config failed:\n{r.stderr[-400:]}")
        # --json, then json.loads: the plain --eval form returns a QUOTED Nix
        # string, whose leading `"` became part of the first keyword and made this
        # find no directives at all. It then reported "nothing to order" for every
        # host — a pass that meant the check had not looked. Caught by ablation.
        rendered = json.loads(r.stdout)
        if not isinstance(rendered, str):
            raise TypeError(f"{machine}: ssh config evaluated to {type(rendered).__name__}, "
                            f"not a string")
        return rendered


def main() -> int:
    wanted = sys.argv[1:]
    machines = sorted(p.name for p in (ROOT / "machines").iterdir() if p.is_dir())
    if wanted:
        machines = [m for m in machines if m in wanted]
    bad = 0
    for m in machines:
        faults = violations(directives(_render(m)))
        if faults:
            bad += 1
            print(f"x {m}")
            for f in faults:
                print(f"    {f}")
        else:
            print(f"ok {m}")
    if bad:
        print(f"\n{bad} host(s) whose ssh_config order does not hold.", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
