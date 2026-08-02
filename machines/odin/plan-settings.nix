# odin's settings for `plan-run` — what the names in a plan mean HERE.
#
# A plan says `From::Isis` and `Root::BackupStaging`; this says where those are.
# The split is the reconciler's central one: the plan is pure and carries no
# path, no login and no address, so the same plan is correct on a machine that
# resolves them differently. See xinutec-infra/plan/runner/src/settings.rs.
#
# ┌─ WHY THIS FILE HOLDS NO CHECK ID ──────────────────────────────────────────┐
# │ `monitor.checks` is empty, and that is the point rather than an omission.  │
# │ A healthchecks id is a bearer capability — whoever holds one can mark the  │
# │ check up and silence the dead-man's switch it feeds — and THIS REPO IS     │
# │ PUBLIC. The Mac's settings.json may hold ids because that repo is private; │
# │ this one may not.                                                          │
# │                                                                            │
# │ Nothing is lost, because `plans::backup` never checks in. Staging is not   │
# │ the thing being monitored: the backup's check-in belongs after RESTIC      │
# │ succeeds, which is where it already is — restic-backups-cluster's          │
# │ ExecStartPost, reading the id from /run/agenix/hc-ping-backup.             │
# │                                                                            │
# │ An empty map is not a permissive default. `Monitor::url_for` refuses a     │
# │ name it does not hold, so a plan that tried to check in from here would    │
# │ stop rather than post to a guessed URL. A runner with no business pinging  │
# │ anything says so.                                                          │
# │                                                                            │
# │ NOTE for whoever wires `plan-run drill` on odin: that plan DOES check in,  │
# │ and its id cannot come from here. It has to be read at run time from       │
# │ /run/agenix/hc-ping-drill, which means the runner needs to accept a check  │
# │ id by FILE the way it already accepts repository passwords by file.        │
# └────────────────────────────────────────────────────────────────────────────┘

{ pkgs, ... }:

let
  settings = {
    roots = {
      # The tree restic actually reads. A root rather than a free path: the
      # runner refuses any root it was not started with, so a staging run
      # cannot land anywhere else — and in particular cannot create this
      # directory under a mountpoint that failed to mount and quietly fill /.
      BackupStaging = "/var/backup-staging";
    };

    # The backup plan names no repository. restic itself is run by the NixOS
    # module, not by the reconciler; the reconciler only assembles what restic
    # then reads.
    repos = { };

    # `address` is why this file exists at all today. The plan names `isis`,
    # and on odin that name resolves to the PUBLIC address while `isis.vpn`
    # is the WireGuard one — and `.vpn` is not a DNS zone, it is rendered into
    # /etc/hosts from network.nix. backup-prepare.sh has always used .vpn.
    # Both answer, so naming the wrong one does not fail: it moves the whole
    # ~573 GB staging pull off the tunnel and reports success.
    hosts = {
      isis = {
        user = "root";
        address = "isis.vpn";
      };
      amun = {
        user = "root";
        address = "amun.vpn";
      };
    };

    monitor = {
      base_url = "https://hc-ping.com";
      checks = { };
    };

    # The runner's only state between runs: when each activity last succeeded.
    # Under /var/lib so it survives a reboot — a stamps file on tmpfs would
    # make every boot look like a machine that had never staged anything, and
    # the freshness window is the whole basis on which work is skipped.
    stamps = "/var/lib/plan-run/stamps.json";

    # By store path, not /etc/backup-preview.py. Both come from the same source
    # file so the content is identical, but a store path cannot be edited in
    # place — and this program decides what a working-tree copy CONTAINS, where
    # a wrong answer is not an error but a shorter list, and a shorter list is a
    # backup that restores cleanly with files missing from it.
    preview_script = ./backup_preview.py;
  };
in {
  environment.etc."plan/settings.json".source =
    pkgs.writeText "plan-settings.json" (builtins.toJSON settings);

  # The stamps file's directory. Created here rather than by the unit that
  # writes it, because `plan-run` is also run by hand and would otherwise fail
  # differently depending on whether the timer had run since boot.
  systemd.tmpfiles.rules = [ "d /var/lib/plan-run 0700 root root -" ];
}
