# Report a `plan-run` plan's verdict to fleetwatch, one timer per plan.
#
# ┌─ WHY A PUSH AND NOT A UNIT GOING RED ──────────────────────────────────────┐
# │ A failing systemd unit is the obvious answer and it is the wrong one here:  │
# │ fleetwatch does NOT collect systemd unit state, so a unit that goes red is  │
# │ a red nobody sees. Every other producer in this fleet pushes — amun's       │
# │ vpn-nodes, isis's picade-health, the Mac's collectors — and a verdict that  │
# │ lands anywhere else is a verdict that has to be gone looking for.           │
# └────────────────────────────────────────────────────────────────────────────┘
#
# `plans` is a LIST because the shape is the same for every plan: run it
# read-only, translate the verdict, POST. #728's `firewall` was the first,
# `integrity` the second, `drill` the third.
#
# ⚠ This file used to say `backup`, `offsite` and `drill` were each one more
# line. That was never measured, and on 2026-08-16 it was measured and is false
# for all three — a list entry is the WIRING, not the work:
#
#   * `drill` and `deploy` take REQUIRED arguments (`--host`, `--prod-host`,
#     `--app`…), and a list of bare names could not carry them, so they exited
#     3 — "a defect in the plan" — and would have reported `fail` every hour.
#     FIXED 2026-08-17 (#977): an entry may be `{ name; args; }`, and `drill`
#     reports. `deploy` still does not: it needs four arguments and one entry
#     per app, which is a different question, but the capability is here.
#   * `backup --simulate` predicts its 37 staging steps every run, because
#     staging is what that plan DOES rather than drift it has found. Exit 2, so
#     it would report `warn` for ever: amber in the steady state is amber nobody
#     reads. STILL OPEN — #978, and note it is not the same as `drill`'s amber,
#     which arrives on day seven and means "the drill is due".
#   * `offsite` runs on the Mac, which has no NixOS module at all.
#
# ⚠ INGEST TOKEN, and it is per machine. fleetwatch derives `source` from the
# bearer token, so a producer can only ever write as its own mapped source —
# that IS the guarantee the design has, and it is why odin cannot borrow isis's.
# Each host needs its own `<host>:<token>` pair in FLEETWATCH_TOKENS (the
# fleetwatch-secret k8s secret on isis) and the token at
# /var/lib/fleetwatch/token, 0600. Until it is there the run fails visibly in
# the journal and fleetwatch shows no data for that plan — the honest state
# while a token is being minted, not a silent gap.
{ config, pkgs, lib, planRun, ... }:

let
  cfg = config.services.planFleetwatch;

  # A list entry is either a bare name or `{ name; args; }`. Both forms rather
  # than only the record because fourteen of the fifteen call sites have no
  # arguments, and making every one of them write `{ name = "firewall"; args =
  # []; }` would be paying for `drill` everywhere.
  normalise = entry:
    if builtins.isString entry then { name = entry; args = [ ]; }
    else { inherit (entry) name; args = entry.args or [ ]; };

  service = entry:
    let plan = entry.name; in {
    name = "fleetwatch-plan-${plan}";
    value = {
      description = "Push the `${plan}` plan's verdict to fleetwatch";
      # Ordering only, no `requires`: if the network is down the push fails and
      # that failure is the honest signal, as in vpn-nodes.nix. The PLAN still
      # runs and still reads the host, which is the part that matters.
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # ⚠ A UNIT'S `path` IS ITS WHOLE PATH — it does not include
      # /run/current-system/sw/bin, so a package being in systemPackages does
      # NOT put it here. iptables is on this list because `plans::firewall`
      # probes by running `iptables -S`, and a plan-run that cannot find it
      # reports the chain as unreadable rather than failing loudly: the run
      # would push "2 could not be read" forever and look like a shy host
      # instead of a broken unit. (Measured on isis 2026-08-11 in the picade
      # module, for the same reason and with the same symptom.)
      #
      # `planRun` is the DERIVATION this generation was built and tested with,
      # from plan-run.nix's `_module.args` — not the name `plan-run` resolved
      # against whatever generation is current when the timer fires.
      path = [ pkgs.iptables planRun ];
      serviceConfig = {
        Type = "oneshot";
        # Root: `iptables -S` needs CAP_NET_ADMIN, and the plan is read-only by
        # construction (`plans::firewall` has no effects at all), so this is a
        # privileged READ and never a privileged write.
        # `--arg` is repeated rather than joined: `escapeShellArg` per element
        # keeps a value with a space intact, where one flat string would be
        # re-split by the shell this ExecStart is.
        #
        # ⚠ `--arg=VALUE`, with the equals sign, and NOT `--arg VALUE`. The
        # values here are themselves flags (`--host`, `--prod-host`), and
        # argparse refuses a separate value starting with `-` — it reads it as
        # the next option. Shipped without the `=` first and the unit died on
        # `--arg: expected one argument`.
        ExecStart = ''
          ${pkgs.python3}/bin/python3 ${./plan-fleetwatch-push.py} \
            --plan ${plan} \
            --plan-run ${planRun}/bin/plan-run \
            --settings /etc/plan/settings.json \
            --token-file ${cfg.tokenFile} \
            --url ${cfg.url} \
            --interval ${toString cfg.intervalSeconds} \
            ${lib.concatMapStringsSep " " (a: "--arg=${lib.escapeShellArg a}") entry.args}
        '';
        StateDirectory = "fleetwatch";
        StateDirectoryMode = "0700";
      };
    };
  };

  timer = entry:
    let plan = entry.name; in {
    name = "fleetwatch-plan-${plan}";
    value = {
      description = "Run the `${plan}` fleetwatch push hourly";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Off the common phases: isis already runs picade-health at *:0/15 and
        # the picade plan at *:07, and a host with one CPU worth caring about
        # should not start three jobs on the same second.
        OnCalendar = cfg.onCalendar;
        # A machine that was asleep at :23 still reports, rather than waiting an
        # hour to say anything about a firewall that may have drifted meanwhile.
        Persistent = true;
        RandomizedDelaySec = 60;
      };
    };
  };
in
{
  options.services.planFleetwatch = {
    plans = lib.mkOption {
      type = lib.types.listOf (lib.types.either lib.types.str (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "The plan, as `plan-run` names it.";
          };
          args = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = ''
              Arguments the plan REQUIRES and the collector cannot guess.
              `drill` needs `--host` and `--prod-host`; without them it exits 3
              and reports a red every hour for ever.

              ⚠ Not a place for `--apply`. The push script always passes
              `--simulate`, and `plan-run` refuses the two together rather than
              resolving them by precedence, so the read-only property is the
              runner's guarantee and not this module's promise.
            '';
          };
        };
      }));
      default = [ ];
      example = [ "firewall" { name = "drill"; args = [ "--host" "odin" ]; } ];
      description = ''
        Plans to run read-only and report. Each gets its own service and timer,
        and its own fleetwatch collector name (`plan-<name>`), so one plan going
        noisy can be muted without silencing the others.

        An entry is a bare name, or `{ name; args; }` when the plan takes
        arguments.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/fleetwatch/token";
      description = "Hand-placed ingest token, 0600. NOT in the repo.";
    };

    url = lib.mkOption {
      type = lib.types.str;
      default = "https://fleetwatch.xinutec.org/api/reports";
      description = "fleetwatch's ingest endpoint.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 3600;
      description = ''
        Declared cadence, sent with the report so fleetwatch can decide when
        this producer has gone silent. Keep it in step with `onCalendar`: a
        value shorter than the real schedule makes a healthy producer look
        overdue, and one longer hides a producer that has actually stopped.
      '';
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*:23";
      description = "systemd calendar expression for every plan's timer.";
    };
  };

  config = lib.mkIf (cfg.plans != [ ]) {
    systemd.services = lib.listToAttrs (map (e: service (normalise e)) cfg.plans);
    systemd.timers = lib.listToAttrs (map (e: timer (normalise e)) cfg.plans);
  };
}
