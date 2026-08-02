# plan-run — the reconciler from xinutec-infra/plan, packaged for odin.
#
# It is here rather than vendored because a copy would be a second source of
# truth for the table that decides what gets backed up, and a table that drifts
# produces a backup with a hole in it that reports success. One source, fetched
# by revision.
#
# ┌─ WHY A REVISION AND NOT `ref = "main"` ────────────────────────────────────┐
# │ Both work — these machines are channel-based, so evaluation is impure and  │
# │ an unlocked fetch is permitted (a flake would refuse it outright). The     │
# │ reason not to is that odin gets rebuilt for unrelated things — a kernel    │
# │ bump, a firewall edit — and with a floating ref every one of those would   │
# │ ALSO swap in whatever had landed on xinutec-infra since, with nothing in   │
# │ this repo's history saying so.                                             │
# │                                                                            │
# │ That is the bar the reconciler itself refuses to cross: its                │
# │ `LocalMatchesOrigin` fact has no remedy on purpose, because the push is    │
# │ the line between testing and production. Bumping the rev below is the      │
# │ deliberate act on this side of that line — pull is not apply.              │
# │                                                                            │
# │ Being behind is a state you may have chosen, so it is reported rather than │
# │ enforced: xinutec-infra's gate runs `scripts/plan-pin.sh`, which fails only │
# │ when this rev is not an ancestor of that repo's main (a dangling or        │
# │ force-pushed pin) and otherwise just says how far back it is.              │
# └────────────────────────────────────────────────────────────────────────────┘
#
# To bump: change `rev`, run xinutec-infra's `scripts/plan-pin.sh`, rebuild.
# No hash to refresh — fetchGit verifies the commit itself.

{ pkgs, ... }:

let
  # Private repo. odin's root key is already authorised on it (it is the same
  # key that pulls this repo), so no deploy key or netrc had to be added; and
  # the fetch happens at EVAL time, which means it must also work wherever the
  # verify gate evaluates odin's config — currently the Mac, which has access.
  #
  # `ref` is given alongside `rev` only to tell git where to look; the rev is
  # what is used.
  src = builtins.fetchGit {
    url = "git@github.com:xinutec/xinutec-infra.git";
    ref = "main";
    rev = "fa5b3a2fa7b23def6f54a952277cc5f3fde9dfac";
  };

  # Built with odin's channel nixpkgs, while the Mac builds the same source
  # through xinutec-infra's own flake. Two toolchains for one program, which is
  # worth knowing about but not worth fixing: nothing here depends on the two
  # binaries being bit-identical, and pinning them together would mean either a
  # root flake in this repo (which breaks `nixos-rebuild` on every host) or a
  # second nixpkgs for odin to build against.
  # NEEDS rustc >= 1.88. The crates are edition 2024 (1.85+), but the runner
  # uses let-chains — `if ok && let Some(key) = ...` — which only left nightly
  # in 1.88. odin's channel is nixos-26.05 with rustc 1.95, so this is slack
  # rather than a constraint; it is written down because the failure is a bare
  # `error[E0658]: 'let' expressions in this position are unstable` with nothing
  # in it to suggest the toolchain is the problem. Measured on amun's older
  # 25.05 channel (rustc 1.86), where it fails exactly that way.
  plan-run = pkgs.rustPlatform.buildRustPackage {
    pname = "plan-run";
    version = "0.1.0";
    src = src + "/plan";
    cargoLock.lockFile = src + "/plan/Cargo.lock";

    # The test suite cannot build from a store path, and that is a property of
    # one test rather than an accident: `the_plan_covers_every_claim_the_script_stages`
    # include_str!s this very repo's machines/odin/backup-prepare.sh, to prove
    # the plan and the shell it replaces name the same PVCs. Two repositories
    # cannot both be inside one src.
    #
    # So the tests run where both trees exist — `cargo test` from a checkout,
    # which is where the gate runs them. That test is scheduled to die with the
    # shell it cross-checks; when it does, this line can go and doCheck can be
    # true.
    doCheck = false;
  };
in
{
  # In systemPackages, which is what actually fixes the bug this packaging is
  # for. Before this, plan-run existed on odin only as hand-copied store paths
  # with no GC root — three of them, and `nix-collect-garbage` had already eaten
  # one. Anything scheduled must be referenced by the system closure or it is
  # not really installed.
  environment.systemPackages = [ plan-run ];
}
