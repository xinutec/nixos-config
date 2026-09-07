# plan-run — the reconciler from xinutec-infra/plan, packaged for tefnut.
#
# Sibling of machines/{odin,isis,geb,shu}/plan-run.nix, and everything odin's file says
# about WHY the source is pinned by revision rather than following a ref applies
# unchanged. To bump: change `rev`, run xinutec-infra's `scripts/plan-pin.sh`,
# rebuild.
#
# ┌─ WHY A HOME BOX RUNS THE RECONCILER AT ALL ────────────────────────────────┐
# │ Added 2026-09-07 with tefnut itself (#1469), and for the reason #1403      │
# │ established: the block that keeps the VPN out of the house lives on the    │
# │ protected host's own INPUT chain. A one-way host without this runs that    │
# │ control with NOTHING checking it — which is what tefnut did from its       │
# │ install until now, and is the shape project_checks_go_quiet_not_red        │
# │ exists for. Adding a one-way host means adding its judge in the same       │
# │ breath, or the security model is asserted rather than verified.            │
# │                                                                            │
# │ ⚠ THE POINT IS THE `firewall` PLAN AND NOTHING ELSE. This host is not a    │
# │ Kubernetes node, has no backups of its own to drive and no cabinets to     │
# │ push; adding plans here because they exist would be adding rows that       │
# │ cannot be answered.                                                        │
# └────────────────────────────────────────────────────────────────────────────┘

{ pkgs, ... }:

let
  # Private repo, fetched at EVAL time, so this needs a credential wherever the
  # config is evaluated — on the host itself and on the Mac, which runs the
  # verify gate. tefnut's own read-only deploy key is /root/.ssh/id_github_infra,
  # generated on the host and never copied; `Host github.com` in
  # base-configuration.nix names it.
  #
  # ⚠ A MISSING KEY FAILS LATE, NOT NOW. fetchGit only reaches the network for a
  # rev the store does not already hold, so every rebuild that KEEPS the pin
  # succeeds and the first BUMP is what fails. Found on odin 2026-08-24.
  src = builtins.fetchGit {
    url = "git@github.com:xinutec/xinutec-infra.git";
    ref = "main";
    # fbc135a — the judge gains ADDRESS FAMILIES. A runner older than this reads
    # `ip6tables` never, and reads the v6 rules in declared-firewall.json as
    # though they were IPv4 — measured on geb and shu 2026-09-05: nine declared
    # against four owned, and the plan blocked. The declaration and the runner
    # that understands it have to move together.
    rev = "fbc135a3e887fe544ca593b445871386c686c53d";
  };

  plan-run = pkgs.rustPlatform.buildRustPackage {
    pname = "plan-run";
    version = "0.1.0";
    src = src + "/plan";
    cargoLock.lockFile = src + "/plan/Cargo.lock";

    # ⚠ SECOND COPY OF xinutec-infra's flake.nix line, and it has to be: this
    # host builds the same source through its own channel nixpkgs, so the test
    # closure is assembled again here. `ps` for cargo_sweep's build probe,
    # rsync for the mirror tests; the sandbox has neither on PATH.
    nativeCheckInputs = [ pkgs.rsync pkgs.procps ];

    doCheck = true;
  };
in
{
  # In systemPackages so the closure holds a GC root — anything scheduled that
  # the system closure does not reference is not really installed.
  environment.systemPackages = [ plan-run ];
  _module.args.planRun = plan-run;
}
