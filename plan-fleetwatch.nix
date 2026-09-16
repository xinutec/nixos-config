# Report a `plan-run` plan's verdict to fleetwatch, one timer per plan.
#
# A push, not a failing unit: fleetwatch does not collect systemd state.
#
# Absent on purpose: `backup --simulate` predicts a step per artifact every run,
# so it would warn for ever (#978); `offsite` runs on the Mac, which has no module.
#
# ⚠ The ingest token is PER MACHINE — fleetwatch derives `source` from it. Each
# host needs its own pair in FLEETWATCH_TOKENS and the token at
# /var/lib/fleetwatch/token, 0600.
{ config, pkgs, lib, planRun, ... }:

let
  cfg = config.services.planFleetwatch;

  normalise = entry:
    if builtins.isString entry then { name = entry; args = [ ]; }
    else { inherit (entry) name; args = entry.args or [ ]; };

  service = entry:
    let plan = entry.name; in {
    name = "fleetwatch-plan-${plan}";
    value = {
      description = "Push the `${plan}` plan's verdict to fleetwatch";
      # Ordering only, no `requires`: a push that fails because the network is
      # down is the honest signal, and the plan still reads the host.
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # ⚠ A unit's `path` does NOT include /run/current-system/sw/bin, so
      # systemPackages does not put a tool here. Every entry is one some plan's
      # probe EXECUTES, and a missing one fails quietly: the probe answers
      # `Unreadable` and the host pushes a verdict that established nothing. A
      # new plan means asking what its probes run.
      #
      # `planRun` is the derivation this generation was built with, not the name
      # resolved against whatever generation is current when the timer fires.
      #
      # k3s conditionally: odin runs none, and would pay the closure for it.
      path = [ pkgs.iptables pkgs.rsync pkgs.openssh pkgs.curl planRun ]
        ++ lib.optional config.services.k3s.enable config.services.k3s.package;
      serviceConfig = {
        Type = "oneshot";
        # Root because `iptables -S` needs CAP_NET_ADMIN; the plan has no effects.
        #
        # ⚠ `--arg=VALUE` with the equals sign: the values are themselves flags
        # (`--host`), and argparse reads a separate `-…` value as the next option.
        # Repeated rather than joined so `escapeShellArg` keeps spaces intact.
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
        # Off the common phases: isis also runs picade-health at *:0/15 and the
        # picade plan at *:07.
        OnCalendar = cfg.onCalendar;
        # A host asleep at :23 still reports rather than waiting an hour.
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
              Arguments the plan REQUIRES and the collector cannot guess, like
              `drill`'s `--host` and `--prod-host`.

              ⚠ Not `--apply`: the push always passes `--simulate` and
              `plan-run` refuses the two together.
            '';
          };
        };
      }));
      default = [ ];
      example = [ "firewall" { name = "drill"; args = [ "--host" "odin" ]; } ];
      description = ''
        Plans to run read-only and report. Each gets its own service, timer and
        collector name (`plan-<name>`), so one can be muted alone.

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
        Declared cadence, sent with the report so fleetwatch can tell when this
        producer has gone silent. ⚠ Keep in step with `onCalendar`: too short
        makes a healthy producer look overdue, too long hides a stopped one.
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
