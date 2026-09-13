# plan-run — the reconciler from xinutec-infra/plan, packaged for isis.
#
# Sibling of machines/odin/plan-run.nix; the pinning rationale there applies here.
# To bump: change `rev`, run xinutec-infra's scripts/plan-pin.sh, rebuild.
#
# ⚠ NOT AMUN, where the picade fleet actually lives: the runner needs rustc >= 1.88
# for let-chains and amun is held on 25.05 with 1.86 until its reinstall. The failure
# there is a bare E0658 that names the feature, not the toolchain.

{ pkgs, ... }:

let
  # Private repo; isis's root key is authorised. Fetched at EVAL time, so it must also
  # work wherever the gate evaluates this config (today, the Mac).
  src = builtins.fetchGit {
    url = "git@github.com:xinutec/xinutec-infra.git";
    ref = "main";
    # ⚠ This host's frontdoor.json and the runner are two sides of one comparison and
    # must be bumped together — an older runner ignores new fields via serde and will
    # report healthy on evidence that cannot show it.
    rev = "08e7da0408982974f2f6408732602d2992ede51f";
  };

  plan-run = pkgs.rustPlatform.buildRustPackage {
    pname = "plan-run";
    version = "0.1.0";
    src = src + "/plan";
    cargoLock.lockFile = src + "/plan/Cargo.lock";

    # `cargo_sweep.rs` shells out to `ps`, which the build sandbox lacks; rsync is for
    # the mirror tests. Duplicated from xinutec-infra's flake because this host builds
    # the same source through its own channel nixpkgs.
    nativeCheckInputs = [ pkgs.rsync pkgs.procps ];

    doCheck = true;
  };
in
{
  # Must be in the closure so it has a GC root — see odin's note.
  environment.systemPackages = [ plan-run ];

  # So picade-health.nix names this derivation rather than resolving PATH at run time.
  _module.args.planRun = plan-run;
}
