# Restic backup for the fleet. Runs on odin, stages Nextcloud and Mailu state, and
# takes one snapshot per run. See ~/Code/xinutec-infra/backups.md.

{ config, pkgs, planRun, ... }:

{
  # restic for ad-hoc inspection; sqlite for drill-nocodb.sh, which inspects the
  # RESTORED database to prove the restore carried data rather than initialising empty.
  environment.systemPackages = [ pkgs.restic pkgs.sqlite ];

  # Shipped to amun over SSH stdin, so nothing need be installed there.
  environment.etc."backup-preview.py".source = ./backup_preview.py;

  # The Mac's off-site pull. READ-only, pinned by the ForceCommand below, so a
  # compromised Mac cannot modify odin's repo.
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

  # The Mac's push of ~/.claude. The ONLY fleet job travelling mac -> server, and it
  # has to be: the Mac is a one-way peer, so odin cannot pull. Lands in
  # /var/backup-staging, which the nightly snapshot already covers.
  users.users.mac-archive = {
    isSystemUser = true;
    group = "mac-archive";
    home = "/var/backup-staging/mac";
    # A real shell, NOT nologin: sshd runs an authorized_keys `command=` through the
    # LOGIN SHELL, so nologin breaks rsync. The key is confined by `command=`, not the
    # shell. restic-offsite gets away with nologin only because internal-sftp execs none.
    shell = "${pkgs.bash}/bin/bash";
    openssh.authorizedKeys.keys = [
      # `-wo`: write-only, so a compromised Mac can add to the archive but not read it.
      # Deletions PROPAGATE (append-only was dropped 2026-08-14), so restic is the
      # only history. Retention is FOUR lines — the keep-yearly below outlives the
      # monthly ladder — and bounds how long a snapshot lives, not how far back one
      # exists: the oldest holding transcripts is 2026-07-31, when this job began.
      # rsync not SFTP because projects/ is append-mostly JSONL, the largest ~480 MB.
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
    # The drill's scratch: a full unencrypted copy of production Nextcloud data, so
    # 0700. Deliberately outside /etc/nixos — the runner may DELETE under this root,
    # which must not contain the scripts doing the deleting (#1487).
    "d /var/lib/drill 0700 root root -"
    "d /var/lib/drill/volumes 0700 root root -"
  ];

  # Consumed by the backup, the weekly integrity check and the restore drill.
  age.secrets."restic-password".file = ../../agenix/restic-password.age;

  # Dead-man's-switch ids. A check id is a bearer capability, read at RUN time from
  # /run/agenix: agenix decrypts AFTER evaluation, so `builtins.readFile` here would
  # read a path that does not yet exist on a fresh boot.
  age.secrets."hc-ping-backup".file = ../../agenix/hc-ping-backup.age;
  age.secrets."hc-ping-drill".file = ../../agenix/hc-ping-drill.age;
  age.secrets."hc-ping-integrity".file = ../../agenix/hc-ping-integrity.age;

  services.restic.backups.cluster = {
    repository   = "/backup/restic";
    initialize   = true;
    passwordFile = config.age.secrets."restic-password".path;

    # Until 2026-08-12 this was `/var/backup-staging` alone, so the one host with no
    # copy anywhere was the one holding everyone else's. /root, /home and
    # /var/lib/private are odin's only state not in git. Docker, the Alloy WAL, /etc
    # and the store are excluded deliberately.
    # /backup is on the SAME filesystem as /, so `--one-file-system` does not fence
    # the repo out. NEVER add a path containing /backup/restic.
    paths = [
      "/var/backup-staging"
      "/root"
      "/home"
      "/var/lib/private"
    ];

    timerConfig = {
      OnCalendar         = "02:30";
      RandomizedDelaySec = "15m";
      Persistent         = true;
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

    # Staging is a declared table in xinutec-infra's `plans::backup`. By store path so
    # it is pinned to the binary this generation was tested with; `--apply` because
    # observe is the default and a missing flag would stage nothing and report success.
    #
    # A FAILED STAGE MUST NOT COST THE WHOLE FLEET ITS BACKUP. As a bare command it
    # exited ExecStartPre and restic never ran, producing no snapshot of anything
    # (2026-08-12). So the failure is recorded, the run continues, and ExecStartPost
    # fails the unit instead.
    # The missing artifact is then STALE, not absent — the staging tree is kept, so
    # restic backs up the previous copy. Read the journal for `[plan] blocked:` before
    # trusting a snapshot from a failed run.
    # `if !` rather than `|| true`: the pre-start script runs under `set -e`.
    backupPrepareCommand = ''
      if ! ${planRun}/bin/plan-run backup --settings /etc/plan/settings.json --apply; then
        echo "staging failed — backing up what IS staged, and failing this unit afterwards"
        touch /run/restic-backups-cluster/staging-failed
      fi
    '';
    # Intentionally NO backupCleanupCommand: keeping the staging tree makes the next
    # rsync incremental, and restic deduplicates.
  };

  # The staging step shells out locally; kubectl is NOT needed, it runs over SSH.
  systemd.services.restic-backups-cluster = {
    path = with pkgs; [ bash rsync openssh zstd curl ];
    serviceConfig = {
      # Hours on a first run — the Nextcloud PVC is ~200 GiB.
      TimeoutStartSec = "6h";
      # So the restic-offsite group can read the repo for SFTP pulls.
      UMask = "0027";
      # The dead-man's switch. `id=$(...)` on its own line deliberately: inline in
      # curl's arguments, `set -e` would not catch an unreadable secret and it would
      # ping a URL with no id. No `|| true` — a backup nobody can confirm is not one.
      # It does NOT check in when staging failed: absence is what alerts, and that
      # does not depend on a failing unit remembering to report itself.
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

  # Weekly integrity check, reading 5% of the repo. 06:00 is SLACK, not the
  # mechanism — restic's lock is exclusive and `retry_lock_s` in plan-settings.nix is
  # what makes this WAIT. The healthchecks schedule must match, or it alarms early.
  systemd.timers.restic-check-cluster = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 06:00";
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
    # What the plan adds is that SILENCE BECOMES VISIBLE: the check-in is a goal, so a
    # run that stops happening stops pinging. Its freshness window is 6 days against
    # a 7-day timer, deliberately — at exactly 7 a Sunday run would judge itself
    # satisfied and skip, silently, for ever.
    script = ''
      ${planRun}/bin/plan-run integrity \
        --settings /etc/plan/settings.json --apply
    '';
  };

  # odin must trust odin: every drill effect goes through ssh, so running the plan on
  # the host it names is a loop back to localhost. Declared so it survives a reinstall.
  # Only odin's own key — the rest of the fleet's known_hosts is still hand-built.
  programs.ssh.knownHosts.odin = {
    hostNames = [ "odin" "odin.xinutec.org" "10.100.0.3" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBGB7SpLmQnKQZIiYgigWvyk3Gr5kRJ6LXlVASgnunC/";
  };

  # Weekly fast restore drill, Sunday 12:00 UTC: seed from staging → compose up → occ
  # integrity checks → teardown (scripts in machines/odin/drill/). Staggered after the
  # 02:30 backup and 06:00 check so the three never overlap on odin's single HDD.
  systemd.timers.drill-weekly = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 12:00";
      Persistent = true;
    };
  };
  systemd.services.drill-weekly = {
    # The PLAN's scripts run over ssh and see root's login environment, not this
    # path — but `ExecStopPost` runs LOCALLY, so docker and util-linux must be here.
    # Getting this wrong fails only in the cleanup path, where nobody is watching.
    path = with pkgs; [ openssh curl docker util-linux ];

    # THE BACKUP WINS. The drill overlays a staging tree that `plan-run backup`
    # rewrites, so what is at risk is the DRILL'S VERDICT, not the data — and a drill
    # is a check while staging is the backup itself (#1486).
    conflicts = [ "restic-backups-cluster.service" ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";

      # HOWEVER THIS UNIT DIES, THE OVERLAY MUST COME OFF, or `Conflicts=` makes the
      # hazard worse: systemd kills the drill and the mirror then rewrites a tree still
      # mounted as its lower layer. `stop`, not `teardown` — a dying unit is no reason
      # to delete 560G. `-` prefixed so it cannot mask the original failure.
      ExecStopPost = "-${pkgs.bash}/bin/bash /etc/nixos/machines/odin/drill/drill-smoke.sh stop";
      # The drill's directory lives in plan-settings.nix — the live /etc/nixos checkout
      # deliberately, so a drill exercises the CURRENT scripts.
      # MUST STAY ABOVE `RunDrill`'s OWN 7h CEILING in plan/runner/src/act.rs. Two
      # ceilings over one job and the lower wins: too low here and the failure is a
      # systemd kill rather than the plan naming its own timeout.
      TimeoutStartSec = "8h";
    };
    # By store path, pinning the drill to the binary this generation was tested with.
    # Ordering GATES: a failed Nextcloud restore now blocks before nocodb is reached,
    # so that week's nocodb drill does not happen. Accepted deliberately.
    script = ''
      ${planRun}/bin/plan-run drill \
        --host odin --prod-host isis \
        --settings /etc/plan/settings.json --apply
    '';
  };
}
