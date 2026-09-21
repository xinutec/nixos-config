# plan-run — the reconciler from xinutec-infra/plan, packaged for odin.
#
# Fetched by revision, not vendored and not `ref = "main"`: odin gets rebuilt for
# unrelated reasons, and a floating ref would silently swap the reconciler too.
# To bump: change `rev`, run xinutec-infra's scripts/plan-pin.sh, rebuild.

{ pkgs, ... }:

let
  # Private repo; odin's root key is already authorised. The fetch is at EVAL time,
  # so it must also work wherever the gate evaluates this config (today, the Mac).
  src = builtins.fetchGit {
    url = "git@github.com:xinutec/xinutec-infra.git";
    ref = "main";
    # The pin may LEAD plan-settings.nix but must never LAG it: `deny_unknown_fields`
    # makes a binary older than its settings refuse to start. New capability here first.
    rev = "039484eb45f07d82d72cc736353b3da6fc7680c2";
  };

  # NEEDS rustc >= 1.88 for let-chains. odin's channel has 1.95, so this is slack —
  # written down because the failure is a bare E0658 that does not name the toolchain.
  plan-run = pkgs.rustPlatform.buildRustPackage {
    pname = "plan-run";
    version = "0.1.0";
    src = src + "/plan";
    cargoLock.lockFile = src + "/plan/Cargo.lock";

    # `cargo_sweep.rs` shells out to `ps`, which the build sandbox lacks; rsync is for
    # the mirror tests. Duplicated from xinutec-infra's flake because this host builds
    # the same source through its own channel nixpkgs.
    nativeCheckInputs = [ pkgs.rsync pkgs.procps ];

    # Held true by dev-lint's nix-rust-package-docheck-false.
    doCheck = true;
  };
in
{
  # Must be in the closure, or nix-collect-garbage eats it: a store path with no GC
  # root is not installed, however present it looks.
  environment.systemPackages = [ plan-run ];

  # So backups.nix names this derivation rather than a PATH lookup — the store path
  # pins staging to the generation it was tested with.
  _module.args.planRun = plan-run;
}
