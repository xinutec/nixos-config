# Restic-based backup for the xinutec fleet. Runs on odin, pulls Nextcloud
# and Mailu state into a staging dir, and takes one restic snapshot per run.
# See ~/Code/xinutec-infra/backups.md and the plan at
# ~/.claude/plans/golden-nibbling-island.md for rationale.

{ config, pkgs, ... }:

{
  # Expose the restic CLI on odin's system PATH so ad-hoc inspection
  # (snapshots, stats, check, mount) works without nix-shell. Only
  # declared here in backups.nix so the dependency is colocated with
  # the module that actually needs it — odin is the only host that
  # imports this file, so there's no fleet-wide footprint.
  environment.systemPackages = [ pkgs.restic ];

  # Dedicated user for off-site restic pull from the mac mini. The mac
  # mini runs `restic copy --from-repo sftp:restic-offsite@odin:...`
  # which only READS from odin's repo (writes go to the mac's local
  # repo). The SSH key is pinned to read-only SFTP via sshd's
  # ForceCommand, so a compromised mac mini cannot modify odin's repo.
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

  # Pin the offsite user to read-only SFTP, chrooted to /backup.
  # ForceCommand internal-sftp -R makes it read-only; ChrootDirectory
  # confines it to /backup so it can't browse the rest of the filesystem.
  services.openssh.extraConfig = ''
    Match User restic-offsite
      ForceCommand internal-sftp -R
      ChrootDirectory /backup
      AllowTcpForwarding no
      X11Forwarding no
  '';

  # The repo dir needs to be readable by the offsite user for SFTP.
  systemd.tmpfiles.rules = [
    "d /backup/restic 0750 root restic-offsite -"
  ];

  services.restic.backups.cluster = {
    repository   = "/backup/restic";
    initialize   = true;
    passwordFile = "/etc/nixos/secrets/restic-password";

    paths = [ "/var/backup-staging" ];

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
      "--tag" "cluster"
    ];

    backupPrepareCommand = builtins.readFile ./backup-prepare.sh;
    # Intentionally NO backupCleanupCommand. The staging tree is kept
    # between runs so that the next run's rsync is incremental (seconds
    # instead of hours) instead of starting from an empty directory.
    # Restic itself deduplicates repeated content so keeping the staging
    # tree on disk doesn't bloat the restic repo.
  };

  # The prepare script shells out to rsync/ssh/zstd locally and has a
  # `#!/usr/bin/env bash` shebang, so bash must be on the service PATH too.
  # kubectl is NOT needed on odin — the script runs kubectl on amun/isis
  # over SSH.
  systemd.services.restic-backups-cluster = {
    path = with pkgs; [ bash rsync openssh zstd ];
    serviceConfig = {
      # Prepare script + restic + cleanup can take a long while on first
      # run (the Nextcloud PVC is ~200 GiB); lift the default timeout.
      TimeoutStartSec = "6h";
    };
  };

  # Weekly repo integrity check — separate unit, not coupled to the backup
  # timer. Reads 5% of the repo data on each run.
  systemd.timers.restic-check-cluster = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 04:00";
      Persistent = true;
    };
  };
  systemd.services.restic-check-cluster = {
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    script = ''
      ${pkgs.restic}/bin/restic -r /backup/restic \
        --password-file /etc/nixos/secrets/restic-password \
        check --read-data-subset=5%
    '';
  };

  # Weekly fast restore drill — runs every Sunday at 12:00 UTC.
  # Orchestrates: seed from staging → compose up → occ integrity checks
  # → teardown. See machines/odin/drill/ for the scripts.
  # Staggered after the 02:30 backup and 04:00 restic check so all
  # three jobs never overlap on odin's single HDD.
  systemd.timers.drill-weekly = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 12:00";
      Persistent = true;
    };
  };
  systemd.services.drill-weekly = {
    path = with pkgs; [ bash docker rsync zstd curl coreutils gnutar ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      WorkingDirectory = "/etc/nixos/machines/odin/drill";
      TimeoutStartSec = "6h";
    };
    script = ''
      /etc/nixos/machines/odin/drill/drill-run.sh
    '';
  };
}
