# plan-run — the reconciler from xinutec-infra/plan, packaged for shu.
#
# The pin, and why it is one, are in ../../plan-run-package.nix.
#
# ┌─ WHY A HOME BOX RUNS THE RECONCILER AT ALL ──────────────────────────────────┐
# │ The block that keeps the VPN out of the house lives on the protected host's  │
# │ own INPUT chain (#1403), not on the servers. A one-way host without plan-run │
# │ runs that control with NOTHING checking it, which is the shape               │
# │ project_checks_go_quiet_not_red exists for — so adding a one-way host means  │
# │ adding its judge in the same breath.                                         │
# │                                                                              │
# │ THE POINT IS THE `firewall` PLAN AND NOTHING ELSE. This host is not a        │
# │ Kubernetes node, has no backups of its own to drive and no cabinets to       │
# │ push; adding plans here because they exist would be adding rows that         │
# │ cannot be answered.                                                          │
# └──────────────────────────────────────────────────────────────────────────────┘

{ pkgs, ... }:

let
  # The pin and the build are the fleet's, shared by every host.
  inherit (import ../../plan-run-package.nix { inherit pkgs; }) plan-run;
in
{
  # In systemPackages so the closure holds a GC root — anything scheduled that
  # the system closure does not reference is not really installed.
  environment.systemPackages = [ plan-run ];
  _module.args.planRun = plan-run;
}
