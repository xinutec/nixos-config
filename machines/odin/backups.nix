# Restic backup for the fleet. Runs on odin, stages Nextcloud and Mailu state, and
# takes one snapshot per run. See ~/Code/xinutec-infra/backups.md.

{ config, pkgs, planRun, planSchedule, ... }:

{
  # restic for ad-hoc inspection; sqlite for drill-nocodb.sh, which reads the
  # RESTORED database to prove it carried data rather than initialising empty.
  environment.systemPackages = [ pkgs.restic pkgs.sqlite ];

  # Shipped to amun over SSH stdin, so nothing need be installed there.
  environment.etc."backup-preview.py".source = ./backup_preview.py;

  # The Mac's off-site pull. Read-only, pinned by the ForceCommand below.
  users.users.restic-offsite = {
    isSystemUser = true;
    group = "restic-offsite";
    home = "/backup/restic";
    shell = "${pkgs.shadow}/bin/nologin";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK1jlqT4cX8mkprp9VQ+KBkdRD1Bv68tE0BrCoyBC9ii mac-mini-restic"
    ];
  };
  users.groups.restic-offsite = {};

  # `-R` is what makes it read-only; ChrootDirectory confines it to /backup.
  services.openssh.extraConfig = ''
    Match User restic-offsite
      ForceCommand internal-sftp -R
      ChrootDirectory /backup
      AllowTcpForwarding no
      X11Forwarding no
  '';

  # The Mac's push of ~/.claude — the only mac -> server job, because the Mac is a
  # one-way peer and odin cannot pull. Lands under /var/backup-staging, which the
  # nightly snapshot covers.
  users.users.mac-archive = {
    isSystemUser = true;
    group = "mac-archive";
    home = "/var/backup-staging/mac";
    # ⚠ A real shell, NOT nologin: sshd runs an authorized_keys `command=` through
    # the login shell. The key is confined by `command=`, not by the shell.
    shell = "${pkgs.bash}/bin/bash";
    openssh.authorizedKeys.keys = [
      # `-wo`: write-only, so a compromised Mac can add but not read. Deletions
      # PROPAGATE, so restic is the only history. rsync not SFTP because projects/
      # is append-mostly JSONL.
      ''command="${pkgs.rrsync}/bin/rrsync -wo /var/backup-staging/mac",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFZb+BRn1YUxmseeNCEU+cD9CzvOGdgcZmk4zqYwTb7i mac-mini-claude-archive''
    ];
  };
  users.groups.mac-archive = {};

  # The repo dir must be readable by the offsite user for SFTP.
  systemd.tmpfiles.rules = [
    "d /backup/restic 2750 root restic-offsite -"
    # NOT under amun/ or isis/ — those are rsync --delete targets in the staging
    # step, so anything parked inside one would be erased on the next run.
    "d /var/backup-staging/mac 0750 mac-archive mac-archive -"
    # The drill's scratch: an unencrypted copy of production Nextcloud data, so
    # 0700. Outside /etc/nixos because the runner DELETES under this root, which
    # must not hold the scripts doing the deleting (#1487).
    "d /var/lib/drill 0700 root root -"
    "d /var/lib/drill/volumes 0700 root root -"
  ];

  # Consumed by the backup, the weekly integrity check and the restore drill.
  age.secrets."restic-password".file = ../../agenix/restic-password.age;

  # Dead-man's-switch ids, each a bearer capability. ⚠ Read at RUN time from
  # /run/agenix — agenix decrypts after evaluation, so `builtins.readFile` here
  # would read a path that does not exist yet on a fresh boot.
  age.secrets."hc-ping-backup".file = ../../agenix/hc-ping-backup.age;
  age.secrets."hc-ping-drill".file = ../../agenix/hc-ping-drill.age;
  age.secrets."hc-ping-integrity".file = ../../agenix/hc-ping-integrity.age;

  services.restic.backups.cluster = {
    repository   = "/backup/restic";
    initialize   = true;
    passwordFile = config.age.secrets."restic-password".path;

    # odin's own state not in git. Docker, the Alloy WAL, /etc and the store are
    # excluded deliberately.
    #
    # ⚠ /backup is on the SAME filesystem as /, so `--one-file-system` does not
    # fence the repo out. Never add a path containing /backup/restic.
    paths = [
      "/var/backup-staging"
      "/root"
      "/home"
      "/var/lib/private"
    ];

    timerConfig = planSchedule.timerFor "restic-backups-cluster" // {
      Persistent = true;
    };

    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
      "--keep-yearly 1"
    ];

    extraBackupArgs = [
      "--one-file-system"
      "--exclude-caches"
      # `--exclude-caches` only skips dirs with a CACHEDIR.TAG, which ~/.cache lacks.
      "--exclude" "/root/.cache"
      "--exclude" "/home/*/.cache"
      "--tag" "cluster"
    ];

    # Staging is a declared table in xinutec-infra's `plans::backup`. By store path,
    # pinned to the binary this generation was tested with. ⚠ `--apply` because
    # observe is the default, and without it this stages nothing and reports success.
    #
    # ⚠ A failed stage must not cost the whole fleet its backup, so the failure is
    # recorded, the run continues, and ExecStartPost fails the unit. The artifact is
    # then STALE, not absent — check the journal for `[plan] blocked:` before
    # trusting a snapshot from a failed run.
    #
    # `if !` rather than `|| true`: the pre-start script runs under `set -e`.
    backupPrepareCommand = ''
      if ! ${planRun}/bin/plan-run backup --settings /etc/plan/settings.json --apply; then
        echo "staging failed — backing up what IS staged, and failing this unit afterwards"
        touch /run/restic-backups-cluster/staging-failed
      fi
    '';
    # No backupCleanupCommand: keeping the staging tree makes the next rsync
    # incremental, and restic deduplicates.
  };

  # The staging step shells out locally; kubectl is NOT needed, it runs over SSH.
  systemd.services.restic-backups-cluster = {
    path = with pkgs; [ bash rsync openssh zstd curl ];
    serviceConfig = {
      # Hours on a first run — the Nextcloud PVC is ~200 GiB.
      TimeoutStartSec = "6h";
      # So the restic-offsite group can read the repo for SFTP pulls.
      UMask = "0027";
      # ⚠ `id=$(...)` on its own line: inline in curl's arguments, `set -e` cannot
      # see an unreadable secret and it would ping a URL with no id. No `|| true`.
      # It does NOT check in when staging failed — absence is what alerts.
      ExecStartPost = pkgs.writeShellScript "restic-backup-ping" ''
        set -euo pipefail
        if [ -e /run/restic-backups-cluster/staging-failed ]; then
          echo "a stage did not run, so an artifact in this snapshot is stale;" >&2
          echo "not checking in, and failing the unit — see the [plan] lines above" >&2
          exit 1
        fi
        id="$(cat ${config.age.secrets."hc-ping-backup".path})"
        exec ${pkgs.curl}/bin/curl -fsS "https://hc-ping.com/$id"
      '';
    };
  };

  # Integrity check, reading 5% of the repo; `retry_lock_s` in plan-settings.nix
  # waits on restic's lock. Daily sampling of a weekly check lets the run-day
  # drift, so its healthchecks check is a period, not a weekday.
  systemd.timers.restic-check-cluster = {
    wantedBy = [ "timers.target" ];
    timerConfig = planSchedule.timerFor "restic-check-cluster" // {
      Persistent = true;
    };
  };
  systemd.services.restic-check-cluster = {
    # `restic` by NAME: plan-run builds an argv list and does not know where nix put it.
    path = with pkgs; [ restic curl ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    # The check-in is a goal, so a run that stops happening stops pinging.
    script = ''
      ${planRun}/bin/plan-run integrity \
        --settings /etc/plan/settings.json --apply
    '';
  };

  # odin must trust odin: every drill effect goes over ssh, so the plan loops back
  # to localhost. Declared so it survives a reinstall. Only odin's own key — the
  # rest of the fleet's known_hosts is hand-built.
  programs.ssh.knownHosts.odin = {
    hostNames = [ "odin" "odin.xinutec.org" "10.100.0.3" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBGB7SpLmQnKQZIiYgigWvyk3Gr5kRJ6LXlVASgnunC/";
  };

  # Restore drill: seed from staging → compose up → occ integrity checks →
  # teardown (machines/odin/drill/). Daily, though a restore is wanted weekly:
  # most days converge in minutes, and the 20-hour goals get a daily chance.
  systemd.timers.drill-weekly = {
    wantedBy = [ "timers.target" ];
    timerConfig = planSchedule.timerFor "drill-weekly" // {
      Persistent = true;
    };
  };
  systemd.services.drill-weekly = {
    # ⚠ The plan's scripts run over ssh and see root's login environment, but
    # `ExecStopPost` runs LOCALLY — so docker and util-linux must be here. Getting
    # it wrong fails only in the cleanup path, where nobody is watching.
    path = with pkgs; [ openssh curl docker util-linux ];

    # The backup wins: the drill overlays a staging tree that `plan-run backup`
    # rewrites, so what is at risk is the drill's verdict, not the data (#1486).
    conflicts = [ "restic-backups-cluster.service" ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";

      # ⚠ However this unit dies, the overlay must come off, or `Conflicts=` makes
      # it worse: systemd kills the drill and the mirror rewrites a tree still
      # mounted as its lower layer. `stop`, not `teardown` — a dying unit is no
      # reason to delete the scratch. `-` so it cannot mask the original failure.
      ExecStopPost = "-${pkgs.bash}/bin/bash /etc/nixos/machines/odin/drill/drill-smoke.sh stop";
      # The drill's directory is in plan-settings.nix — the live /etc/nixos
      # checkout, so a drill exercises the CURRENT scripts.
      #
      # ⚠ Must stay ABOVE `RunDrill`'s own ceiling in plan/runner/src/act.rs: the
      # lower of two ceilings wins, and this one killing first turns a named plan
      # timeout into an unexplained systemd kill.
      TimeoutStartSec = "8h";
    };
    # By store path, pinned to the binary this generation was tested with.
    # ⚠ Ordering gates: a failed Nextcloud restore blocks before nocodb is reached,
    # so that week's nocodb drill does not happen. Accepted deliberately.
    script = ''
      ${planRun}/bin/plan-run drill \
        --host odin --prod-host isis \
        --settings /etc/plan/settings.json --apply
    '';
  };
}
