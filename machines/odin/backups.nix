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
      # a compromised mac can add to the archive but cannot read it back.
      # Neither /backup/restic (root-owned) nor anything else on the host is
      # reachable.
      #
      # `-no-del` was here until 2026-08-14 and made the archive append-only:
      # Claude Code prunes its own old transcripts, and a mirror would have let
      # that prune reach the only remaining copy. Measured before removing it —
      # the mac held 24 main transcripts against this archive's 2,490, so the
      # property was demonstrably load-bearing — but the 2,466 it was holding
      # were empty sessions, median 23.7 KB, which is about what a transcript
      # weighs when it is nothing but injected task-reminder boilerplate.
      # Pippijn's call, on that evidence: they are copies of data held
      # elsewhere and not worth mirroring for.
      #
      # ⚠ So deletions now propagate, and restic is the only history: retention
      # here is keep-daily 7 / keep-weekly 4 / keep-monthly 6, so anything the
      # mac drops is recoverable for about six months and then gone.
      #
      # rsync rather than SFTP because projects/ is append-mostly JSONL — the
      # largest transcript is ~480 MB and grows daily, so delta transfer is the
      # difference between a few MB a night and re-uploading the file.
      ''command="${pkgs.rrsync}/bin/rrsync -wo /var/backup-staging/mac",restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFZb+BRn1YUxmseeNCEU+cD9CzvOGdgcZmk4zqYwTb7i mac-mini-claude-archive''
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
  # Third switch, minted 2026-08-16. #52 read as "blocked on a healthchecks id"
  # for months, which sounded like a decision nobody had taken; half of it was
  # that a public settings file had nowhere to PUT an id, and that half was
  # fixed by monitor.check_files. This is the other half.
  age.secrets."hc-ping-integrity".file = ../../agenix/hc-ping-integrity.age;

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
  #
  # ⚠ 06:00, not 04:00, and the two hours are not padding. restic takes an
  # EXCLUSIVE LOCK on the repository, so this and the nightly backup cannot
  # overlap — and on 2026-08-16 they did: the backup ran 02:42→04:03 and this
  # check died at 04:00:02 with `unable to create lock in backend: repository is
  # already locked`, four minutes short.
  #
  # 04:00 was chosen when the backup finished by 03:20. Measured over the nine
  # nights to 2026-08-16 it takes 43–81 minutes and the ceiling is climbing:
  # 03:12, 03:17, 03:22, 03:23, 03:27, 03:35, 03:38, 04:03. So this was not a
  # freak — it is the first of a recurring collision, and the margin has to be
  # sized to the worst night rather than the median. 06:00 clears 04:03 by two
  # hours and still leaves the Sunday 12:00 drill alone.
  #
  # ⚠ THE HEALTHCHECKS SCHEDULE MUST MATCH. The `cluster-integrity` check is
  # configured OnCalendar `Sun 06:00`; leaving it at 04:00 would alarm two hours
  # before the job it watches has run, every week.
  #
  # The real fix is `restic --retry-lock`, so this waits for the backup instead
  # of relying on a gap someone guessed — that is a plan-table change and a pin
  # bump, filed rather than done here.
  #
  # ⚠ And note what found this: NOTHING DID, for as long as it mattered. The
  # 04:00 failure was silent because the old unit reported to nobody, which is
  # exactly the gap `plan-run integrity` closes. It surfaced only because
  # somebody read the journal by hand while cutting the unit over.
  systemd.timers.restic-check-cluster = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 06:00";
      Persistent = true;
    };
  };
  systemd.services.restic-check-cluster = {
    # `restic` by NAME now, not by store path: plan-run builds `restic --repo …`
    # as an argv list and does not know where nix put it. curl is the check-in.
    path = with pkgs; [ restic curl ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    # `plan-run integrity --apply`, replacing the bare restic call.
    #
    # What the plan adds is the thing the shell could not do: **silence becomes
    # visible.** The old unit reported to nothing, so a timer that stopped firing
    # looked exactly like one that fired and passed — while `offsite` went on
    # pinging green about the repository it copies FROM. The check-in is a goal
    # of the plan, so a run that stops happening stops pinging and the switch
    # goes red on its own.
    #
    # The repository and the check id are both named in plan-settings.nix, by
    # PATH rather than by value; this unit names neither. The 5% subset and the
    # six-day freshness window are in the plan's table, not here.
    #
    # ⚠ The window is 6 days against a 7-day timer, deliberately. At exactly 7 a
    # Sunday run whose stamp was minutes past 04:00 last Sunday would judge
    # itself satisfied and skip, silently, for ever. Same discipline as drill.
    #
    # By store path for the same reason the staging step is: this pins the check
    # to the binary this generation was built and tested with.
    script = ''
      ${planRun}/bin/plan-run integrity \
        --settings /etc/plan/settings.json --apply
    '';
  };

  # odin has to trust odin, because the drill reaches its own scripts over ssh.
  #
  # Every drill effect goes through `exec::over_ssh` — the plan was written to be
  # driven from the Mac, and running it on the machine it names does not remove
  # the hop, it turns it into a loop back to localhost. root's ~/.ssh/known_hosts
  # here holds amun, isis and github, all added by hand over the years; `odin`
  # was never among them, because nothing had ever asked odin to connect to
  # itself. So the first thing `plan-run drill` did on this host was fail
  # `Host key verification failed` — measured 2026-08-16, before this block.
  #
  # Declared rather than appended to known_hosts by hand, so it survives a
  # reinstall and says why it exists. A host's PUBLIC key is public by
  # definition — anyone who connects is shown it — so it costs this repo nothing
  # to carry.
  #
  # ⚠ Only odin's own key is declared, and the rest of the fleet's trust is
  # still hand-built per machine in root's known_hosts. That is a real gap and
  # not one this change closes: it fixes what the drill needs, and leaves the
  # general problem visible rather than half-solved.
  programs.ssh.knownHosts.odin = {
    hostNames = [ "odin" "odin.xinutec.org" "10.100.0.3" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBGB7SpLmQnKQZIiYgigWvyk3Gr5kRJ6LXlVASgnunC/";
  };

  # Weekly fast restore drill — runs every Sunday at 12:00 UTC.
  # Orchestrates: seed from staging → compose up → occ integrity checks
  # → teardown. See machines/odin/drill/ for the scripts.
  # Staggered after the 02:30 backup and 06:00 restic check so all
  # three jobs never overlap on odin's single HDD.
  systemd.timers.drill-weekly = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun 12:00";
      Persistent = true;
    };
  };
  systemd.services.drill-weekly = {
    # The scripts still need bash, docker, rsync and the rest — but they are no
    # longer this unit's children. `plan-run` reaches them over ssh, so what
    # they see is root's LOGIN environment on odin, not this `path`. What is
    # left here is what plan-run itself execs: ssh, and curl for the check-in.
    #
    # Keeping the full list "just in case" would be worse than useless: it would
    # read as the unit still owning the scripts' dependencies, and the day one
    # of them broke, this line is where somebody would look first.
    path = with pkgs; [ openssh curl ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      # No WorkingDirectory any more. The drill's directory is a fact about this
      # machine, so it moved to plan-settings.nix where the rest of them live —
      # still the live /etc/nixos checkout, deliberately, because a drill has to
      # exercise the CURRENT scripts and not a store-frozen copy.
      TimeoutStartSec = "6h";
    };
    # `plan-run drill --apply`, replacing the two bare script calls.
    #
    # By store path, for the reason the staging step is: this pins the drill to
    # the binary this generation was built and tested with, where
    # /run/current-system/sw/bin would resolve at run time to whatever is
    # current by then.
    #
    # ⚠ ORDERING IS GATING, AND THAT IS A REAL BEHAVIOUR CHANGE. The unit used
    # to run both scripts and fail if either did, so a broken Nextcloud restore
    # still left nocodb drilled. Under the plan, `done:drill-restore` is a
    # required goal ahead of `done:drill-nocodb`, so a failed Nextcloud restore
    # blocks before nocodb is reached and that week's nocodb drill does not
    # happen. Accepted deliberately: a failing Nextcloud restore demands
    # attention that week anyway, and ordering nocodb first would let the
    # cheaper, soon-retired system block the crown jewel.
    #
    # What the plan adds in exchange: the preflight is now two goals rather than
    # a stage inside drill-run.sh (hence `--restore-only` in the effect), the
    # image-match check REFUSES rather than remedies, the five-minute dbload
    # check runs first so a broken dump is found before four hours are spent on
    # it, and the check-in is a goal of its own instead of a line at the end of
    # a script that only runs if everything before it did.
    #
    # `--host odin` is odin naming itself; see plan-settings.nix and the
    # knownHosts block above for why that is an ssh loop rather than a local
    # call.
    script = ''
      ${planRun}/bin/plan-run drill \
        --host odin --prod-host isis \
        --settings /etc/plan/settings.json --apply
    '';
  };
}
