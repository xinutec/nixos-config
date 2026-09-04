# Restic-based backup for the xinutec fleet. Runs on odin, pulls Nextcloud
# and Mailu state into a staging dir, and takes one restic snapshot per run.
# See ~/Code/xinutec-infra/backups.md and the plan at
# ~/.claude/plans/golden-nibbling-island.md for rationale.

{ config, pkgs, planRun, ... }:

{
  # restic on PATH for ad-hoc inspection (snapshots, stats, check, mount) without
  # nix-shell. Declared here rather than fleet-wide because odin is the only host
  # importing this file.
  #
  # sqlite for drill-nocodb.sh, which inspects the RESTORED database to prove the
  # restore carried the data rather than nocodb silently initialising a fresh empty DB
  # and serving HTTP 200 off it. Not needed for the backup itself — the staging step
  # only runs sqlite3 on amun/isis over SSH, out of those hosts' closures.
  environment.systemPackages = [ pkgs.restic pkgs.sqlite ];

  # The staging step ships this to amun over SSH stdin (`< /etc/backup-preview.py`) so
  # the toktok-workspace step needs no script installed there. Deployed via
  # environment.etc so the source of truth stays beside the backup table.
  environment.etc."backup-preview.py".source = ./backup_preview.py;

  # Off-site restic pull from the mac mini, which runs `restic copy --from-repo
  # sftp:restic-offsite@odin:...` — READ-only here, since writes go to the mac's own
  # repo. Pinned to read-only SFTP by sshd's ForceCommand below, so a compromised mac
  # cannot modify odin's repo.
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

  # `internal-sftp -R` is what makes it read-only; ChrootDirectory confines it to
  # /backup so it cannot browse the rest of the filesystem.
  services.openssh.extraConfig = ''
    Match User restic-offsite
      ForceCommand internal-sftp -R
      ChrootDirectory /backup
      AllowTcpForwarding no
      X11Forwarding no
  '';

  # The mac mini's push of ~/.claude (transcripts, memory corpus, file history). The
  # ONLY fleet job travelling mac -> server, and it has to be: the mac is a one-way VPN
  # peer, so odin cannot reach in to pull, and the mac's internal disk is otherwise the
  # single copy of ~27k files. The mac initiates, which the one-way rule allows.
  #
  # It lands in /var/backup-staging, which the nightly snapshot already covers
  # wholesale, so no change to the staging step was needed — and every --delete rsync
  # there is scoped to the amun/ or isis/ subtree, leaving a third top-level dir alone.
  users.users.mac-archive = {
    isSystemUser = true;
    group = "mac-archive";
    home = "/var/backup-staging/mac";
    # ⚠ A real shell, deliberately, NOT nologin like restic-offsite above. sshd runs an
    # authorized_keys `command=` through the user's LOGIN SHELL, so nologin refuses the
    # forced command itself and rsync dies with "protocol version mismatch -- is your
    # shell clean?". restic-offsite gets away with nologin only because internal-sftp is
    # handled inside sshd and execs no shell. This key is confined by `command=` +
    # `restrict`, not by the shell.
    shell = "${pkgs.bash}/bin/bash";
    openssh.authorizedKeys.keys = [
      # rrsync confines the key to one directory, and `-wo` makes it write-only: a
      # compromised mac can add to the archive but not read it back, and neither
      # /backup/restic (root-owned) nor anything else on the host is reachable.
      #
      # ⚠ `-no-del` was here until 2026-08-14 and made the archive append-only, because
      # Claude Code was believed to prune its own transcripts and a mirror lets that
      # prune reach the last copy. Measured before removing it — the mac held 24 main
      # transcripts against this archive's 2,490 — but the 2,466 were empty sessions,
      # median 23.7 KB, about what a transcript weighs when it is only injected
      # task-reminder boilerplate. Pippijn's call on that evidence: copies of data held
      # elsewhere.
      #
      # ⚠ That call is now confirmed by the archive itself (memview#1240, #1247).
      # Diffing the last append-only snapshot against the mac on 2026-08-29: of 2,467
      # transcripts gone, 2,465 lived in temp-directory projects and the two that did
      # not are empty sessions. NOT ONE TRANSCRIPT HOLDING A CONVERSATION HAS BEEN
      # DELETED, and of the 952 in the first snapshot, zero are missing. What removes
      # them is still not established — files from the same day in the same project
      # were treated differently — so the class is measured and the rule is not.
      #
      # ⚠ So deletions propagate and restic is the only history. Retention is FOUR
      # lines, not three: keep-daily 7 / keep-weekly 4 / keep-monthly 6 / **keep-yearly
      # 1** (see pruneOpts below). Quoting the first three gives "~6 months and then
      # gone", which is right for the monthly ladder and wrong as an absolute — one
      # yearly snapshot outlives it. ⚠ And retention bounds how long a snapshot lives,
      # never how far back one exists: the oldest holding transcripts is 2026-07-31,
      # because that is when this job began.
      #
      # rsync rather than SFTP because projects/ is append-mostly JSONL — the largest
      # transcript is ~480 MB and grows daily, so delta transfer is the difference
      # between a few MB a night and re-uploading the file.
      ''command="${pkgs.rrsync}/bin/rrsync -wo /var/backup-staging/mac",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFZb+BRn1YUxmseeNCEU+cD9CzvOGdgcZmk4zqYwTb7i mac-mini-claude-archive''
    ];
  };
  users.groups.mac-archive = {};

  # The repo dir must be readable by the offsite user for SFTP.
  systemd.tmpfiles.rules = [
    "d /backup/restic 2750 root restic-offsite -"
    # Owned by the pushing user so rrsync can write into it. ⚠ Not under amun/ or isis/
    # — those are rsync --delete targets in the staging step, so anything parked inside
    # one would be erased on the next run.
    "d /var/backup-staging/mac 0750 mac-archive mac-archive -"
  ];

  # restic repo password, decrypted at activation to /run/agenix/restic-password.
  # Consumed by the backup job, the weekly integrity check and the restore drill.
  age.secrets."restic-password".file = ../../agenix/restic-password.age;

  # healthchecks.io check ids for odin's dead-man's switches. ⚠ A check id is a bearer
  # capability (agenix/secrets.nix says why these are not literals) and is read at RUN
  # time from /run/agenix: agenix decrypts during activation, AFTER evaluation, so a
  # `builtins.readFile` here would read a path that does not yet exist on a fresh boot.
  age.secrets."hc-ping-backup".file = ../../agenix/hc-ping-backup.age;
  age.secrets."hc-ping-drill".file = ../../agenix/hc-ping-drill.age;
  age.secrets."hc-ping-integrity".file = ../../agenix/hc-ping-integrity.age;

  services.restic.backups.cluster = {
    repository   = "/backup/restic";
    initialize   = true;
    passwordFile = config.age.secrets."restic-password".path;

    # ⚠ `/var/backup-staging` was the ONLY path until 2026-08-12, so odin backed up
    # amun, isis and the mac and NOT ITSELF — the one host with no copy anywhere was
    # the one holding everyone else's. Found by listing what a snapshot actually
    # contains (`restic ls latest` → amun/, isis/, mac/, no odin/), not by reading this
    # file, where the absence looks like nothing at all.
    #
    # odin's unique state is small, since the machine is defined by `nixos-config` plus
    # agenix. What is NOT in git is these three:
    #   /root            .ssh, .config, drill, shell history      (~200 KB kept)
    #   /home            pippijn's checkout, .unison, .local      (~19 MB)
    #   /var/lib/private systemd DynamicUser state                (2.2 MB)
    #
    # Deliberately absent: /var/lib/docker (14 GB of buildfarm containers that pull
    # again), /var/lib/grafana-agent (a WAL), /etc (generated, and /etc/nixos is this
    # repository), and the nix store.
    #
    # ⚠ `/backup` is on the SAME filesystem as `/` (both /dev/sda2), so
    # `--one-file-system` does not fence the repo out — only path selection does. Never
    # add a path containing /backup/restic, or restic backs its own repository up into
    # itself.
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
      # ~/.cache does not — /root/.cache alone is 144 MB of nothing worth restoring.
      "--exclude" "/root/.cache"
      "--exclude" "/home/*/.cache"
      "--tag" "cluster"
    ];

    # Staging is a declared table of artifacts in xinutec-infra's `plans::backup`,
    # replacing 626 lines of shell whose coverage could only be established by reading
    # it. What changed is not how it copies but what a failure means: each artifact is a
    # fact, so a run that dies at the eleventh resumes at the eleventh instead of
    # re-dumping every database to get back there. (One thing the shell did that the
    # reconciler does not: vaultwarden sidecar cleanup — an artifact asserts freshness,
    # not that the tree holds ONLY what is declared.)
    #
    # By store path, not `plan-run` on PATH, so the staging step is pinned to the binary
    # this generation was built and tested with. See plan-run.nix.
    #
    # --apply because observe is the default: the runner is handed an `Effect` only
    # under apply, so a missing flag here would stage nothing and report success — the
    # one failure this port exists to make impossible.
    #
    # ⚠ **A stage that cannot run must not cost the whole fleet its backup.** This was a
    # bare command, so a non-transient staging failure exited the ExecStartPre and
    # restic — in ExecStart, behind it — never ran at all. On 2026-08-12 the
    # `picade-home` source had moved off amun; the reconciler correctly called it
    # non-transient, and the night produced **no snapshot of anything**, including
    # odin's own /root and /home and the artifacts that had staged fine minutes earlier.
    # Blocking makes an incomplete backup impossible, but charges *no* backup rather
    # than a nearly complete one, every night until somebody notices.
    #
    # So the failure is recorded and the run continues: `ExecStartPost` reads the
    # marker, declines to check in, and fails the unit. Loud and nearly complete beats
    # silent and absent. Pippijn's call, 2026-08-12.
    #
    # ⚠ **The missing artifact is STALE, not absent.** The staging tree is kept between
    # runs, so restic backs up the *previous* copy of whatever failed to refresh — a
    # plausible file with an old timestamp, where the unit failing is the only thing
    # saying which artifact to distrust. Read the journal for `[plan] blocked:` before
    # trusting a snapshot from a failed run.
    #
    # `if !` rather than `|| true`: the generated pre-start script runs under `set -e`,
    # so this catches the failure rather than merely ignoring it.
    backupPrepareCommand = ''
      if ! ${planRun}/bin/plan-run backup --settings /etc/plan/settings.json --apply; then
        echo "staging failed — backing up what IS staged, and failing this unit afterwards"
        touch /run/restic-backups-cluster/staging-failed
      fi
    '';
    # Intentionally NO backupCleanupCommand: keeping the staging tree makes the next
    # run's rsync incremental (seconds instead of hours), and restic deduplicates, so
    # it does not bloat the repo.
  };

  # The staging step shells out to rsync/ssh/zstd locally, so bash must be on the
  # service PATH. kubectl is NOT needed here — it runs on amun/isis over SSH.
  systemd.services.restic-backups-cluster = {
    path = with pkgs; [ bash rsync openssh zstd curl ];
    serviceConfig = {
      # Staging + restic can take hours on a first run (the Nextcloud PVC is ~200 GiB).
      TimeoutStartSec = "6h";
      # 0640/0750 so the restic-offsite group can read the repo for SFTP pulls.
      UMask = "0027";
      # The dead-man's switch. Only the base URL is spelled here — where odin checks in
      # is documentation, the id is not.
      #
      # A script rather than a bare curl because reading the secret needs a shell.
      # ⚠ `id=$(...)` on its own line deliberately: as an assignment, `set -e` catches
      # an unreadable secret, where the same substitution inline in curl's arguments
      # would discard its exit status and ping a URL with no id in it.
      #
      # No `|| true` — an unreachable monitor fails this unit. A backup nobody can
      # confirm is not a backup.
      #
      # ⚠ **And it does NOT check in for a run whose staging failed.** The snapshot was
      # taken, but an artifact in it is the previous run's copy, so this is not a backup
      # anyone should be told is good. No ping means healthchecks.io alerts by absence,
      # which is how it caught the 2026-08-12 failure and does not depend on a failing
      # unit remembering to report itself.
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

  # Weekly repo integrity check — its own unit, not coupled to the backup timer. Reads
  # 5% of the repo data per run.
  #
  # ⚠ 06:00 is SLACK, not the mechanism. restic's lock is exclusive, so this and the
  # nightly backup cannot overlap — and on 2026-08-16 they did, this check dying at
  # 04:00:02 four minutes before the backup released it. The backup takes 43–81 minutes
  # and its ceiling is climbing, so 04:00 had been outgrown. What stops it recurring is
  # `retry_lock_s` in plan-settings.nix, which makes the check WAIT; this hour only
  # means it rarely has to.
  #
  # ⚠ THE HEALTHCHECKS SCHEDULE MUST MATCH — `cluster-integrity` is set to `Sun 06:00`.
  # At 04:00 it would alarm two hours before the job it watches.
  systemd.timers.restic-check-cluster = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 06:00";
      Persistent = true;
    };
  };
  systemd.services.restic-check-cluster = {
    # `restic` by NAME, not store path: plan-run builds `restic --repo …` as an argv
    # list and does not know where nix put it. curl is the check-in.
    path = with pkgs; [ restic curl ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    # What the plan adds over a bare restic call is the thing the shell could not do:
    # **silence becomes visible.** The old unit reported to nothing, so a timer that
    # stopped firing looked exactly like one that fired and passed — while `offsite` went
    # on pinging green about the repository it copies FROM. The check-in is a goal of the
    # plan, so a run that stops happening stops pinging.
    #
    # The repository and the check id are named in plan-settings.nix, by PATH rather than
    # by value; this unit names neither. The 5% subset and the freshness window are in
    # the plan's table.
    #
    # ⚠ That window is 6 days against a 7-day timer, deliberately. At exactly 7, a
    # Sunday run whose stamp was minutes past last Sunday's would judge itself satisfied
    # and skip, silently, for ever. Same discipline as drill.
    #
    # By store path, pinning the check to the binary this generation was tested with.
    script = ''
      ${planRun}/bin/plan-run integrity \
        --settings /etc/plan/settings.json --apply
    '';
  };

  # odin has to trust odin, because the drill reaches its own scripts over ssh.
  #
  # Every drill effect goes through `exec::over_ssh` — the plan was written to be driven
  # from the Mac, so running it on the machine it names turns the hop into a loop back to
  # localhost rather than removing it. root's known_hosts here holds amun, isis and
  # github, added by hand over the years; `odin` never was, because nothing had asked
  # odin to connect to itself. So `plan-run drill`'s first act on this host was
  # `Host key verification failed`.
  #
  # Declared rather than appended by hand, so it survives a reinstall and says why it
  # exists. A host's PUBLIC key is public by definition, so carrying it costs nothing.
  #
  # ⚠ Only odin's own key is declared; the rest of the fleet's trust is still hand-built
  # per machine in root's known_hosts. A real gap this does not close — it fixes what
  # the drill needs and leaves the general problem visible rather than half-solved.
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
    # ⚠ The scripts still need bash, docker and rsync, but they are no longer this
    # unit's children: `plan-run` reaches them over ssh, so what they see is root's
    # LOGIN environment, not this `path`. What is left is what plan-run itself execs.
    # Keeping the full list "just in case" would read as the unit still owning those
    # dependencies, and this line is where somebody would look first when one broke.
    path = with pkgs; [ openssh curl ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      # No WorkingDirectory: the drill's directory is a fact about this machine, so it
      # lives in plan-settings.nix with the rest — still the live /etc/nixos checkout,
      # deliberately, because a drill must exercise the CURRENT scripts rather than a
      # store-frozen copy.
      TimeoutStartSec = "6h";
    };
    # By store path, pinning the drill to the binary this generation was tested with;
    # /run/current-system/sw/bin would resolve at run time to whatever is current then.
    #
    # ⚠ ORDERING IS GATING, AND THAT IS A REAL BEHAVIOUR CHANGE. The unit used to run
    # both scripts and fail if either did, so a broken Nextcloud restore still left
    # nocodb drilled. Now `done:drill-restore` is a required goal ahead of
    # `done:drill-nocodb`, so a failed Nextcloud restore blocks before nocodb is reached
    # and that week's nocodb drill does not happen. Accepted deliberately: a failing
    # Nextcloud restore demands attention that week anyway, and ordering nocodb first
    # would let the cheaper, soon-retired system block the crown jewel.
    #
    # `--host odin` is odin naming itself — an ssh loop back to localhost, which the
    # knownHosts block above is what makes resolve.
    script = ''
      ${planRun}/bin/plan-run drill \
        --host odin --prod-host isis \
        --settings /etc/plan/settings.json --apply
    '';
  };
}
