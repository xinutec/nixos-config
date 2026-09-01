{-
nixos-config/gate.dhall — this repository's commit gate.

Was `scripts/verify.sh`, an aggregating gate written by hand: it deliberately
omitted `set -e` so one failing step could not hide the four after it, piped every
step's output through `sed` for indentation, and therefore had to end each one
`[ "${PIPESTATUS[0]}" -eq 0 ] || fail=1`. PIPESTATUS is a bashism that has already
broken once under zsh, and a bare `$?` there would have reported sed's success
rather than the check's. None of that is expressible wrongly in a table: the
runner sees the real exit code, there is no pipe, and "run everything, fail at the
end" is what the runner does rather than something the absence of a flag implies.
The strict-mode waiver the script carried goes with it — there is no `set -e` here
to opt out of.

**The machine eval is Python now**, at `scripts/eval_machines.py`. It was a shell
loop doing real work — a temp tree, a `sed` substitution into
`configuration.nix.dist`, the machine's own `hardware-configuration.nix` dropped
at the root — and that is a program, not a command line. Same evaluation, same
per-machine reporting, and it is now readable by the ruff and mypy rows below it.

**The cross-check against xinutec-infra is GONE, with its subject.**
`backup-prepare.sh` used to be the one file in this PUBLIC repo that another
repo compiled against: xinutec-infra's `plan/core/tests/backup.rs` `include_str!`d
it at five sites and checked the reconciler's table against it. The coupling ran
one way and the gates ran the other, so an edit HERE could only be discovered by
running the gate THERE — which is why a row here reached into that repo.

The script was deleted on 2026-08-05, three days after the reconciler took over
the nightly staging, and those five tests went with it. The row that ran them
went too: it would still have passed, because the file it names holds nine other
tests, but it would have been a row in THIS repo running THAT repo's suite for a
reason that no longer existed — and `plan: cargo test` in xinutec-infra's own
gate already covers them. A green row whose justification has evaporated is the
shape this whole gate exists to catch.

The script's answer was to print `– skipped: no ~/Code/xinutec-infra` and carry
on green, on the grounds that this repo is public and that one is not. That is
still a hole: the machine that commits here is the machine that has both, so the
skip only ever fired when something was wrong. As a row it is a `cwd` that does
not exist, which the runner reports as a failed check rather than a pass — a
public clone cannot run this row, and it should say so rather than pass.

The generated `gate.json` is committed; `the table matches its Dhall` re-renders
and diffs it, so running the gate needs no `dhall`.

The pinned toolchain lives in `nix/`, NOT at the repository root: the root is
`/etc/nixos` on each host, and `nixos-rebuild` would take a root `flake.nix` as
the system to build. So the rows that need it name `path:./nix`, rather than
`G.inDevShell`, which assumes a flake at the root.
-}

let G = ../dev-lint/gate/schema.dhall

let inNixShell = G.inShell "path:./nix"

in  { name = "nixos-config"
    , checks =
      [ {-  The real check: every machine's complete NixOS configuration is
            evaluated — module system, agenix, home-manager, every option
            definition. Evaluation only; nothing is built, so it runs on the Mac.
            See the script for what it reconstructs and why.
        -}
        G.Check::{
        , name = "nix eval — every machine's full NixOS config"
        , argv = inNixShell [ "python3", "scripts/eval_machines.py" ]
        , timeout_s = 1800
        }
      , {-  isis's front door is rendered from the fleet model and is NOT in any
            machine's `imports` yet — adding it IS the cutover (#1294). So the
            row above, which evaluates each machine's complete configuration,
            does not reach this file and it would rot unnoticed until the day it
            matters most.

            Evaluating it also runs its own assertion, which is the point: a
            VpnOnly host that also listens on a public address serves perfectly
            and is simply reachable by anyone who knows the name. That is the
            one mistake in the file that announces itself in no other way.
        -}
        G.Check::{
        , name = "isis front door evaluates, and no VpnOnly name listens publicly"
        , argv =
            inNixShell
              [ "nix-instantiate"
              , "--eval"
              , "--strict"
              , "-E"
              , "let p = import <nixpkgs> {}; m = import ./machines/isis/frontdoor.nix { config = {}; lib = p.lib; pkgs = p; }; in builtins.length (builtins.attrNames m.services.nginx.virtualHosts)"
              ]
        , timeout_s = 600
        }
      , G.Check::{
        , name = "ruff (operational Python)"
        , argv = inNixShell [ "ruff", "check", "." ]
        , timeout_s = 300
        }
      , {-  Named files rather than the tree: these two are the ones that run on
            a host unattended, and `--strict` on the rest would be a promise this
            repository has not made yet.
        -}
        G.Check::{
        , name = "mypy --strict (operational Python)"
        , argv =
            inNixShell
              [ "mypy"
              , "--strict"
              , "machines/amun/vpn-nodes-push.py"
              , "machines/odin/backup_preview.py"
              , "plan-fleetwatch-push.py"
              ]
        , timeout_s = 600
        }
      , G.Check::{
        , name = "pytest (operational Python)"
        , argv =
            inNixShell
              [ "python"
              , "-m"
              , "pytest"
              , "-q"
              , "machines"
              , "test_plan_fleetwatch_push.py"
              ]
        , timeout_s = 600
        }
      , {-  `find` rather than `git ls-files '*.sh'`: the file list was
            word-split out of a command substitution, which needed a shellcheck
            disable of its own, and an untracked script is exactly the one nobody
            has read yet.
        -}
        G.Check::{
        , name = "shellcheck (host-side shell scripts)"
        , argv =
            inNixShell
              [ "find"
              , "machines"
              , "scripts"
              , "setup.sh"
              , "-name"
              , "*.sh"
              , "-exec"
              , "shellcheck"
              , "{}"
              , "+"
              ]
        , timeout_s = 300
        }
      , G.devLint "../"
      , G.checkTable "../dev-lint"
      ]
    }
