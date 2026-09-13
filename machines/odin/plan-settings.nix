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
      # A root rather than a free path: the runner refuses any root it was not started
      # with, so staging cannot land elsewhere — in particular not under a mountpoint
      # that failed to mount, quietly filling /.
      # The tree restic actually reads. A root rather than a free path: the
      # runner refuses any root it was not started with, so a staging run
      # cannot land anywhere else — and in particular cannot create this
      # directory under a mountpoint that failed to mount and quietly fill /.
      BackupStaging = "/var/backup-staging";

      # What the drill may EMPTY — the root `Effect::ClearUnder` resolves against
      # so the drill's wipe can stop being a shell `rm -rf` (#1487).
      #
      # A root the runner DELETES under has a different question to answer than
      # one it only reads: not "where does this live" but "what is reachable if a
      # plan names the wrong `rel`". Here that is a dedicated scratch directory
      # and nothing else.
      #
      # It is NOT the drill directory. That version was written and dev-lint
      # refused it (`nix-root-exec-mutable-etc`), correctly: it would have put the
      # scripts that perform the deletion inside the blast radius of the root
      # authorising it, and the waiver `drill.dir` carries is for exercising the
      # CURRENT scripts — a claim data does not have. The scratch moved to
      # /var/lib/drill instead (2aa6ebc), verified by a full drill run.
      #
      # Pairs with `rel = "volumes"`: ClearUnder refuses a `rel` naming the root,
      # since emptying the root is the one deletion a declared root would
      # otherwise authorise.
      DrillScratch = "/var/lib/drill";
    };

    # `backup` still names no repository — restic is run by the NixOS module
    # there, and the reconciler only assembles what restic then reads.
    #
    # `integrity` does, because it runs restic itself: one `check
    # --read-data-subset` against odin's own repository. The password is named
    # by FILE and never read into the runner, so it cannot reach a log, an
    # argument list or a core dump. Same path the restic module already uses.
    repos = {
      cluster = {
        path = "/backup/restic";
        password_file = "/run/agenix/restic-password";
        # Wait for the lock rather than dying on it. restic's lock is EXCLUSIVE
        # and this repository has a second writer — the nightly backup — which
        # on 2026-08-16 was still holding it when the check started, so that
        # week's verification never ran. A stagger only moves the collision;
        # this removes it, because whenever the backup finishes, the check
        # proceeds.
        #
        # Two hours is a CEILING ON WAITING, not a target, and the runner adds
        # it to the effect's own timeout rather than spending it out of it. Were
        # it spent, a long wait plus a half-hour check would be killed at two
        # hours — and a timeout does not name its cause, where `repository is
        # already locked` does.
        retry_lock_s = 7200;
      };
    };

    # `address` is why this file exists at all today. The plan names `isis`,
    # and on odin that name resolves to the PUBLIC address while `isis.vpn`
    # is the WireGuard one — and `.vpn` is not a DNS zone, it is rendered into
    # /etc/hosts from network.nix. The shell this replaced always used .vpn.
    # Both answer, so naming the wrong one does not fail: it moves the whole
    # ~573 GB staging pull off the tunnel and reports success.
    # `odin` is here for the drill, and it is odin talking to ITSELF. Every
    # drill effect runs its script through `exec::over_ssh`, because the plan
    # was written to be driven from the Mac; running it here does not make the
    # ssh go away, it makes it a loop back to this machine. The cost is one
    # connection per step against a four-hour restore, which is nothing — but
    # it does mean odin has to trust odin's host key, declared in backups.nix
    # beside the unit that needs it.
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

    # Where the drill lives, and which production namespace it claims to
    # mirror. Facts about the machines rather than about the plan: `plans::drill`
    # names two hosts and nothing else.
    #
    # The directory is the live /etc/nixos checkout, deliberately, and NOT a
    # store path — the drill has to exercise the CURRENT scripts and compose
    # file, which is the whole point of a restore drill. The same reasoning the
    # unit's WorkingDirectory carried before the cutover, and the same waiver:
    # DL's nix-root-exec-mutable-etc is right about root units in general and
    # deliberately wrong about this one. The waiver MOVED with the fact rather
    # than being invented here — it sat on the WorkingDirectory line this
    # replaces, and dev-lint caught the move, which is the rule working.
    drill = {
      # ast-grep-ignore: nix-root-exec-mutable-etc
      dir = "/etc/nixos/machines/odin/drill";
      namespace = "nextcloud";
    };

    monitor = {
      base_url = "https://hc-ping.com";
      checks = { };
      # Read when the ping is sent, not when the settings load: agenix decrypts
      # during activation, so resolving this at load would fail on a fresh boot
      # for every plan that never checks in.
      check_files = {
        drill = "/run/agenix/hc-ping-drill";
        # The name the PLAN uses, so it is `cluster-integrity` and not
        # `integrity` — `plans::integrity` says
        # `NotifyMonitor { check = "cluster-integrity" }`, and `url_for` refuses
        # a name it does not hold rather than guessing at a near miss.
        cluster-integrity = "/run/agenix/hc-ping-integrity";
      };
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
