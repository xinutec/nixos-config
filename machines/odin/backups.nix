# Restic-based backup for the xinutec fleet. Runs on odin, pulls Nextcloud
# and Mailu state into a staging dir, and takes one restic snapshot per run.
# See ~/Code/xinutec-infra/backups.md and the plan at
# ~/.claude/plans/golden-nibbling-island.md for rationale.

{ config, pkgs, planRun, ... }:

{
  # Expose the restic CLI on odin's system PATH so ad-hoc inspection
  # (snapshots, stats, check, mount) works without nix-shell. Only
  # declared here in backups.nix so the dependency is colocated with
  # the module that actually needs it — odin is the only host that
  # imports this file, so there's no fleet-wide footprint.
  #
  # sqlite is here for the same reason: drill-nocodb.sh inspects the RESTORED
  # database on odin to prove the restore actually carried the data, rather than
  # nocodb having silently initialised a fresh empty DB and served HTTP 200 off
  # it. Note odin does not need sqlite for the backup itself — the staging step
  # only ever runs sqlite3 on amun/isis over SSH, out of those hosts' closures.
  environment.systemPackages = [ pkgs.restic pkgs.sqlite ];

  # the staging step ships file paths to amun via SSH stdin so the
  # toktok-workspace backup step doesn't require installing a script
  # on amun. The source of truth lives beside the backup table and
  # is deployed to /etc/backup-preview.py via environment.etc, where
  # the prepare script can `< /etc/backup-preview.py` it into the
  # remote python3.
  environment.etc."backup-preview.py".source = ./backup_preview.py;

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

  # Dedicated user for the mac mini's push of ~/.claude (Claude Code's
  # transcripts, memory corpus and file history). This is the ONLY thing on
  # the fleet that travels mac -> server rather than the other way round, and
  # it has to: the mac is a one-way VPN peer, so odin cannot reach it to pull,
  # and the mac's internal disk is otherwise the single copy of ~27k files
  # nothing else holds. The mac initiates, which the one-way rule allows.
  #
  # It lands in /var/backup-staging, so the existing nightly restic snapshot
  # picks it up with no change to the staging step — the staging tree is
  # backed up wholesale (`paths = [ "/var/backup-staging" ]`), and every
  # --delete rsync in that script is scoped to the amun/ or isis/ subtree, so
  # a third top-level dir is left alone.
  users.users.mac-archive = {
    isSystemUser = true;
    group = "mac-archive";
    home = "/var/backup-staging/mac";
    # A real shell, deliberately, and NOT nologin like restic-offsite above.
    # sshd runs an authorized_keys `command=` through the user's login shell,
    # so nologin refuses the forced command itself and rsync dies with
    # "protocol version mismatch -- is your shell clean?". restic-offsite gets
    # away with nologin only because internal-sftp is handled inside sshd and
    # never execs a shell. The key is confined by `command=` + `restrict`, not
    # by the shell: there is no way to reach it interactively.
    shell = "${pkgs.bash}/bin/bash";
    openssh.authorizedKeys.keys = [
      # rrsync confines the key to one directory. `-wo` makes it write-only, so
      # a compromised mac can add to the archive but cannot read it back, and
      # `-no-del` refuses --delete server-side — the append-only property is
      # then structural rather than a flag the client script could grow later.
      # Neither /backup/restic (root-owned) nor anything else on the host is
      # reachable.
      #
      # rsync rather than SFTP because projects/ is append-mostly JSONL — the
      # largest transcript is ~480 MB and grows daily, so delta transfer is the
      # difference between a few MB a night and re-uploading the file.
      ''command="${pkgs.rrsync}/bin/rrsync -wo -no-del /var/backup-staging/mac",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFZb+BRn1YUxmseeNCEU+cD9CzvOGdgcZmk4zqYwTb7i mac-mini-claude-archive''
    ];
  };
  users.groups.mac-archive = {};

  # The repo dir needs to be readable by the offsite user for SFTP.
  systemd.tmpfiles.rules = [
    "d /backup/restic 2750 root restic-offsite -"
    # Owned by the pushing user so rrsync can write into it. Not under
    # amun/ or isis/ — those are rsync --delete targets in the staging step
    # and anything parked inside one would be erased on the next run.
    "d /var/backup-staging/mac 0750 mac-archive mac-archive -"
  ];

  # restic repo password — encrypted in the repo via agenix, decrypted
  # at activation to /run/agenix/restic-password. Consumed by the backup
  # job, the weekly integrity check, and the full restore drill.
  age.secrets."restic-password".file = ../../agenix/restic-password.age;

  # healthchecks.io check IDs for odin's two dead-man's switches. A check
  # ID is a bearer capability — see agenix/secrets.nix for why these are
  # not literals any more. Read at RUN time from /run/agenix, never at
  # eval time: agenix decrypts during activation, which happens after
  # evaluation, so a `builtins.readFile` here would read a path that does
  # not exist yet on a fresh boot.
  age.secrets."hc-ping-backup".file = ../../agenix/hc-ping-backup.age;
  age.secrets."hc-ping-drill".file = ../../agenix/hc-ping-drill.age;

  services.restic.backups.cluster = {
    repository   = "/backup/restic";
    initialize   = true;
    passwordFile = config.age.secrets."restic-password".path;

    # ⚠ `/var/backup-staging` was the ONLY path until 2026-08-12, which meant
    # odin backed up amun, isis and the mac and NOT ITSELF. The repo lives here
    # and stages the others into it, so the one host with no copy anywhere was
    # the one holding everyone else's. Found by listing what a snapshot actually
    # contains (`restic ls latest` → amun/, isis/, mac/, and no odin/) rather
    # than by reading this file, where the absence looks like nothing at all.
    #
    # odin's unique state is small, because the machine is defined by
    # `nixos-config` plus agenix: what is NOT in git is these three.
    #   /root            .ssh, .config, drill, shell history      (~200 KB kept)
    #   /home            pippijn's checkout, .unison, .local      (~19 MB)
    #   /var/lib/private systemd DynamicUser state                (2.2 MB)
    #
    # Deliberately absent: /var/lib/docker (14 GB of buildfarm containers that
    # pull again), /var/lib/grafana-agent (a WAL), /etc (generated, and
    # /etc/nixos is this repository), and the nix store.
    #
    # ⚠ `/backup` is on the SAME filesystem as `/` (both /dev/sda2), so
    # `--one-file-system` does not fence the repo out — only path selection does.
    # Never add a path that contains /backup/restic, or restic starts backing up
    # its own repository into itself.
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
      # `--exclude-caches` only skips directories carrying a CACHEDIR.TAG, which
      # ~/.cache does not — /root/.cache alone is 144 MB of nothing worth
      # restoring. Named explicitly rather than trusting the tag convention.
      "--exclude" "/root/.cache"
      "--exclude" "/home/*/.cache"
      "--tag" "cluster"
    ];

    # THE CUTOVER (2026-08-02). This was `builtins.readFile ./backup-prepare.sh`
    # — 626 lines of shell whose coverage could only be established by reading
    # it. The same staging is now a declared table of 36 artifacts in
    # xinutec-infra's `plans::backup`, and what changes is not how it copies but
    # what a failure means: each artifact is a fact, so a run that dies at the
    # eleventh resumes at the eleventh instead of re-dumping every database to
    # get back there.
    #
    # backup-prepare.sh was KEPT as the rollback until 2026-08-05, when it was
    # deleted: it had not run since the cutover, and the five tests that held it
    # in lockstep with the plan went with it. git history is the rollback now.
    # One thing it did that the reconciler does not: the vaultwarden sidecar
    # cleanup (an artifact asserts freshness, not that the tree holds ONLY what
    # is declared). The two stale files were removed by hand at cutover.
    #
    # By store path, not `plan-run` on PATH: this pins the staging step to the
    # binary this generation was built and tested with. See plan-run.nix.
    #
    # --apply because observe is the default — the runner is handed an `Effect`
    # only under apply, so a missing flag here would stage nothing and report
    # success, which is the one failure this whole port exists to make
    # impossible. Verified by hand first: a full apply ran 36/36 artifacts clean
    # on 2026-08-02 at 19:41–20:22 UTC before this line was written.
    # ⚠ **A stage that cannot run must not cost the whole fleet its backup.**
    # This was a bare command, so a non-transient staging failure exited the
    # ExecStartPre and restic — which is in ExecStart, behind it — never ran at
    # all. On 2026-08-12 the `picade-home` source had been moved off amun the
    # day before; the reconciler correctly called it non-transient, and the
    # night produced **no snapshot of anything**: not odin's own `/root` and
    # `/home`, and not one of the amun, isis and Mac artifacts that had staged
    # successfully minutes earlier. Blocking makes an incomplete backup
    # impossible, which is a defensible thing to want — but the price it charges
    # is *no* backup rather than a nearly complete one, and it recurs every night
    # until somebody notices.
    #
    # So the failure is recorded and the run continues. `ExecStartPost` reads the
    # marker, declines to check in, and fails the unit — the snapshot is taken,
    # and the alarm still goes off. Loud and nearly complete beats silent and
    # absent. Decided by Pippijn 2026-08-12.
    #
    # ⚠ **The missing artifact is STALE, not absent.** The staging tree is kept
    # between runs (see below), so restic backs up the *previous* copy of
    # whatever failed to refresh. That is better than nothing and worse than it
    # looks: the snapshot will contain a plausible file with an old timestamp, so
    # the unit failing is the only thing that says which artifact to distrust.
    # Read the journal for the `[plan] blocked:` line before trusting a snapshot
    # taken by a failed run.
    #
    # `if !` rather than `|| true`: the generated pre-start script runs under
    # `set -e`, and this way the failure is caught rather than merely ignored.
    backupPrepareCommand = ''
      if ! ${planRun}/bin/plan-run backup --settings /etc/plan/settings.json --apply; then
        echo "staging failed — backing up what IS staged, and failing this unit afterwards"
        touch /run/restic-backups-cluster/staging-failed
      fi
    '';
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
    path = with pkgs; [ bash rsync openssh zstd curl ];
    serviceConfig = {
      # Prepare script + restic + cleanup can take a long while on first
      # run (the Nextcloud PVC is ~200 GiB); lift the default timeout.
      TimeoutStartSec = "6h";
      # Create files as 0640/dirs 0750 so the restic-offsite group can
      # read the repo for off-site SFTP pulls.
      UMask = "0027";
      # Ping healthchecks.io on success (dead man's switch). The check ID
      # comes from agenix at run time; only the base URL is spelled here,
      # because where odin checks in is documentation and the ID is not.
      #
      # A script rather than a bare curl line because reading the secret
      # needs a shell. `id=$(...)` on its own line deliberately: as an
      # assignment, `set -e` catches a missing or unreadable secret here,
      # whereas the same substitution inline in curl's arguments would
      # discard its exit status and ping a URL with no ID in it.
      #
      # Still no `|| true` — an unreachable monitor fails this unit, as it
      # did before. A backup nobody can confirm is not a backup.
      #
      # ⚠ **And it does NOT check in for a run whose staging failed.** The
      # snapshot was taken — that is the point of carrying on — but an artifact
      # in it is the previous run's copy, so this is not a backup anyone should
      # be told is good. No ping means healthchecks.io alerts by absence, which
      # is the same way it caught the 2026-08-12 failure and does not depend on
      # a failing unit remembering to report itself.
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
        --password-file ${config.age.secrets."restic-password".path} \
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
    # openssh + sqlite are for drill-nocodb.sh: it ssh's to amun to run the
    # container and reads the restored DB back. A unit's `path` is not the
    # interactive PATH, so being in environment.systemPackages is NOT enough.
    path = with pkgs; [ bash docker rsync zstd curl coreutils gnutar gawk openssh sqlite ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      # The DR drill intentionally runs from the live /etc/nixos checkout so it
      # exercises the CURRENT drill scripts + config, not a store-frozen copy —
      # that's the whole point of a restore drill.
      # ast-grep-ignore: nix-root-exec-mutable-etc
      WorkingDirectory = "/etc/nixos/machines/odin/drill";
      TimeoutStartSec = "6h";
    };
    # Both drills run; the unit fails if either does. drill-run.sh is Nextcloud
    # (compose stack on odin); drill-nocodb.sh seeds on odin but runs its
    # container on amun, because odin's Atom CPU cannot execute the nocodb image
    # at all — see the header of that script.
    script = ''
      rc=0
      /etc/nixos/machines/odin/drill/drill-run.sh || rc=$?
      /etc/nixos/machines/odin/drill/drill-nocodb.sh || rc=$?
      exit $rc
    '';
  };
}
