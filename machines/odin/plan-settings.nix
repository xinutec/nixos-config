# odin's settings for `plan-run` — what the names in a plan mean HERE. A plan says
# `From::Isis` and `Root::BackupStaging`; this says where those are, so the plan stays
# pure. See xinutec-infra/plan/runner/src/settings.rs.
#
# NO CHECK IDS HERE, ONLY PATHS TO THEM: a healthchecks id is a bearer capability
# and THIS REPO IS PUBLIC. `monitor.check_files` names them by path, decrypted by
# agenix and read at ping time. An empty `checks` is not a permissive default —
# `Monitor::url_for` refuses a name it holds neither way, and one held both ways.

{ pkgs, ... }:

let
  settings = {
    roots = {
      # The tree restic reads. A root rather than a free path: the runner refuses
      # any root it was not started with, so a staging run cannot create this
      # directory under a mountpoint that failed to mount and quietly fill /.
      BackupStaging = "/var/backup-staging";

      # What the drill may EMPTY — the root `Effect::ClearUnder` resolves against
      # (#1487). A root the runner DELETES under answers "what is reachable if a
      # plan names the wrong `rel`", so it is a dedicated scratch directory.
      #
      # ⚠ NOT the drill directory: that would put the scripts performing the
      # deletion inside the blast radius of the root authorising it.
      #
      # Pairs with `rel = "volumes"` — ClearUnder refuses a `rel` naming the root.
      DrillScratch = "/var/lib/drill";
    };

    # `backup` names no repository — the NixOS module runs restic; the reconciler
    # only assembles what it reads. `integrity` does, because it runs restic itself.
    #
    # The password is named by FILE and never read into the runner, so it cannot
    # reach a log, an argument list or a core dump.
    repos = {
      cluster = {
        path = "/backup/restic";
        password_file = "/run/agenix/restic-password";
        # Wait for the lock rather than dying on it. restic's lock is EXCLUSIVE
        # and this repository has a second writer, the nightly backup; a check
        # that starts while it runs would simply not verify that week. A stagger
        # only moves the collision, where this removes it — whenever the backup
        # finishes, the check proceeds.
        #
        # A ceiling on WAITING, added to the effect's own timeout rather than
        # spent out of it — otherwise a long wait plus a real check is killed
        # part-way, and a timeout does not name its cause.
        retry_lock_s = 7200;
      };
    };

    # ⚠ `.vpn`, not the bare name: on odin `isis` resolves to the PUBLIC address.
    # Both answer, so the wrong one does not fail — it moves the whole staging pull
    # off the tunnel and reports success. `.vpn` is not a DNS zone; it is rendered
    # into /etc/hosts from network.nix.
    #
    # `odin` is here for the drill, talking to ITSELF: every drill effect runs over
    # ssh, so odin must trust odin's host key (declared in backups.nix).
    hosts = {
      isis = {
        user = "root";
        address = "isis.vpn";
      };
      amun = {
        user = "root";
        address = "amun.vpn";
      };
      odin = { user = "root"; };
    };

    # Where the drill lives, and which production namespace it mirrors.
    #
    # The live /etc/nixos checkout and NOT a store path: the drill has to exercise
    # the CURRENT scripts and compose file. Hence the waiver below, which
    # nix-root-exec-mutable-etc is right to demand of root units in general.
    drill = {
      # ast-grep-ignore: nix-root-exec-mutable-etc
      dir = "/etc/nixos/machines/odin/drill";
      namespace = "nextcloud";
    };

    monitor = {
      base_url = "https://hc-ping.com";
      checks = { };
      # Read when the ping is sent, not at load: agenix decrypts during activation,
      # so resolving at load fails on a fresh boot.
      check_files = {
        drill = "/run/agenix/hc-ping-drill";
        # The name the PLAN uses, so `cluster-integrity` and not `integrity`.
        # `url_for` refuses a name it does not hold rather than guessing.
        cluster-integrity = "/run/agenix/hc-ping-integrity";
      };
    };

    # The runner's only state between runs: when each activity last succeeded.
    # ⚠ Under /var/lib so it survives a reboot — on tmpfs, every boot looks like a
    # machine that has never staged anything.
    stamps = "/var/lib/plan-run/stamps.json";

    # By store path, which cannot be edited in place: this program decides what a
    # copy CONTAINS, and a wrong answer is not an error but a shorter list —
    # a backup that restores cleanly with files missing from it.
    preview_script = ./backup_preview.py;
  };
in {
  environment.etc."plan/settings.json".source =
    pkgs.writeText "plan-settings.json" (builtins.toJSON settings);

  # Created here rather than by the unit, because `plan-run` is also run by hand.
  systemd.tmpfiles.rules = [ "d /var/lib/plan-run 0700 root root -" ];
}
