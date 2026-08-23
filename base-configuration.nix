# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, lib, ... }:

let
  net = import ./network.nix;
  sshKeys = import ./ssh-keys.nix;
  # agenix — secrets encrypted in this repo, decrypted per-host at
  # activation by the host's own SSH key. Pinned by tag (nixos-config
  # is channel-based, not a flake); to bump, change the rev and refresh
  # the hash with: nix-prefetch-url --unpack <url>
  agenix = builtins.fetchTarball {
    url = "https://github.com/ryantm/agenix/archive/refs/tags/0.15.0.tar.gz";
    sha256 = "01dhrghwa7zw93cybvx4gnrskqk97b004nfxgsys0736823956la";
  };

  # Nodes the VPN may never initiate toward — see `oneWay` in options.nix. The
  # rules below are GENERATED from this list, so marking a node in network.nix
  # is the whole change; there is no second place that has to be remembered,
  # which is what went wrong when the mac-mini rules were six literal lines.
  # Deduplicated because `nodes` aliases the master, so attrValues repeats it.
  oneWayNodes =
    lib.unique (builtins.filter (n: n.oneWay or false) (builtins.attrValues net.nodes));

  # The VPN address of a node named in some other node's `reachableFrom`.
  # `throw` rather than a silent skip: a misspelled name would generate no rule
  # at all, which reads exactly like the exception having been granted — and the
  # thing being granted is the right to open connections to a machine the fleet
  # is otherwise forbidden to touch.
  vpnOf = named:
    (net.nodes.${named} or (throw
      "reachableFrom names ${named}, which is not a node in network.nix"
    )).vpn;

  # Teardown for one peer. Also used on its own by extraStopCommands, and run
  # before the inserts so a firewall reload is idempotent rather than stacking
  # a fresh copy of every rule. The admitted-peer deletes come first for the
  # same reason the rest do.
  oneWayTeardown = node:
    (lib.concatMapStrings (peer: ''
      iptables -w -D FORWARD -s ${vpnOf peer} -d ${node.vpn} -j ACCEPT 2>/dev/null || true
    '') (node.reachableFrom or [ ]))
    + ''
      iptables -w -D FORWARD -d ${node.vpn} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
      iptables -w -D FORWARD -d ${node.vpn} -j DROP 2>/dev/null || true
      iptables -w -D OUTPUT -d ${node.vpn} -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
    '';

  # The peer may initiate into the VPN; nothing here — this host, its pods, or
  # forwarded peer traffic — may initiate toward it. Only return traffic for
  # connections the peer opened gets through. The peer is expected to enforce the same
  # locally (mac-mini uses pf); this is defence in depth.
  #
  # Ordering holds at any peer count: each peer's ACCEPT is inserted immediately before
  # its own DROP, and both match on that peer's address alone.
  #
  # `reachableFrom` names the exceptions. Each goes in at position 2 AFTER the DROP
  # does, which puts it above the DROP and below the ESTABLISHED accept, so an admitted
  # peer may open a connection and nobody else may. Several admits stack in reverse
  # order among themselves, which does not matter — all ACCEPTs above the one DROP.
  #
  # ⚠ The OUTPUT rule is deliberately NOT excepted: it stops this host dialling the peer
  # itself, and forwarding somebody else's connection is not a reason to grant your own.

  # ── The rules this repository declares, AS DATA ────────────────────────────
  #
  # Rendered to /etc/plan/declared-firewall.json so the declared side becomes something
  # that can be READ. Nothing could read it before: rules come out of shell evaluation
  # — `extraCommands` below is 92 rendered lines with a function and a loop — so a
  # static parse is a guess and running the script is not a read. #727 is what that
  # cost: a hand-added rule sat in amun's FORWARD chain for at least 88 days,
  # undeclared, found because somebody happened to look.
  #
  # ⚠ Spelled in `iptables -S` FORM, not as the commands below are written, and the
  # difference is the whole point of measuring rather than assuming. iptables renders a
  # rule back canonically: `-d 10.100.0.5` returns as `-d 10.100.0.5/32`, `--ctstate
  # ESTABLISHED,RELATED` as `RELATED,ESTABLISHED`, and `--dport 6443` gains a `-m tcp`.
  # Every string here was copied from live output on geb (2026-08-12), not composed.
  #
  # ⚠ A SECOND rendering of the same values, not a generator for the first, and
  # deliberately: driving `extraCommands` from this list would mean reproducing its
  # comments, teardown ordering and `-w` placement exactly — intricacy added to a
  # firewall generator to remove intricacy from it. What keeps the two honest is the
  # check that consumes this file. A drifting declaration is the thing being detected,
  # not a weakness in detecting it.
  #
  # SCOPE: our rules only — the k8s API accepts and the one-way VPN block. NOT
  # everything the NixOS firewall module generates, nor what Docker, k3s or kube-router
  # inject: reproducing the module's own output as data would duplicate its logic and
  # become its own drift risk. #727 sat in a chain we own, so the scoped version still
  # catches its shape.
  declaredFirewall =
    # The two container→API accepts, from the same `net` values `extraCommands`
    # interpolates.
    (map (proto: {
      chain = "nixos-fw";
      spec = "-A nixos-fw -s ${net.cluster} -p ${proto} -m ${proto} --dport ${
          toString net.k8sApiPort
        } -j nixos-fw-accept";
      why = "containers reach the API and nothing else internal";
    }) [ "tcp" "udp" ])
    # Ours even though the firewall MODULE renders it rather than `extraCommands`.
    # `allowedTCPPorts`/`allowedUDPPorts` below are literally `[ net.vpnPort ]`, so this
    # reads the same value and no second list can go stale.
    #
    # ⚠ SSH's 22 is deliberately NOT here: `services.openssh.openFirewall` opens it, so
    # declaring it would be this file asserting another module's default — and if that
    # default changed, the check would go red at the declaration rather than the cause.
    ++ (map (proto: {
      chain = "nixos-fw";
      spec = "-A nixos-fw -p ${proto} -m ${proto} --dport ${
          toString net.vpnPort
        } -j nixos-fw-accept";
      why = "WireGuard, one of the two remote lifelines";
    }) [ "tcp" "udp" ])
    # ...and every one-way node's block. Fleet-wide rather than per host: the
    # rules go on every machine, which is what makes the VPN one-way at all.
    ++ (lib.concatMap (node:
      [
        {
          chain = "FORWARD";
          spec =
            "-A FORWARD -d ${node.vpn}/32 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT";
          why = "return traffic for connections ${node.name} opened itself";
        }
      ] ++ (map (peer: {
        chain = "FORWARD";
        spec = "-A FORWARD -s ${vpnOf peer}/32 -d ${node.vpn}/32 -j ACCEPT";
        why = "${peer} may initiate toward ${node.name}";
      }) (node.reachableFrom or [ ])) ++ [
        {
          chain = "FORWARD";
          spec = "-A FORWARD -d ${node.vpn}/32 -j DROP";
          why = "nothing else may initiate toward ${node.name}";
        }
        {
          chain = "OUTPUT";
          spec =
            "-A OUTPUT -d ${node.vpn}/32 -m conntrack --ctstate NEW -j DROP";
          why =
            "this host may not dial ${node.name} either; forwarding somebody else's connection is not a reason to grant your own";
        }
      ]) oneWayNodes);

  oneWayRules = node: ''
    # One-way VPN for ${node.name} (${node.vpn}).
  '' + oneWayTeardown node + ''
    iptables -w -I FORWARD 1 -d ${node.vpn} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -w -I FORWARD 2 -d ${node.vpn} -j DROP
    iptables -w -I OUTPUT 1 -d ${node.vpn} -m conntrack --ctstate NEW -j DROP
  '' + lib.concatMapStrings (peer: ''
    # ${peer} may initiate toward ${node.name}.
    iptables -w -I FORWARD 2 -s ${vpnOf peer} -d ${node.vpn} -j ACCEPT
  '') (node.reachableFrom or [ ]);
in {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./options.nix
    ./grafana-alloy.nix
    "${agenix}/modules/age.nix"
    <home-manager/nixos>
  ];

  system.stateVersion = "21.11";
  nix = {
    gc.automatic = true;
    optimise.automatic = true;
  };

  # Define on which hard drive you want to install Grub.
  boot.loader.grub.device = "/dev/sda";

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;

  environment.systemPackages = with pkgs; [ git ];

  systemd.slices = {
    docker = {
      description = "Docker slice";
    };
  };

  virtualisation.docker = {
    enable = true;
    extraOptions = "--config-file=${
        pkgs.writeText "daemon.json" (builtins.toJSON {
          "exec-opts" = [ "native.cgroupdriver=systemd" ];
          "features" = { "buildkit" = true; };
          "experimental" = true;
          "cgroup-parent" = "docker.slice";
        })
      }";
  };

  virtualisation.oci-containers.containers = {
    # grafana-agent docker container retired 2026-05-14 in favour of
    # services.alloy via grafana-alloy.nix (native NixOS service).
    # grafana-agent reached EOL on 2025-11-01; Alloy is the supported
    # successor.
    buildfarm-worker = {
      image = "toxchat/buildfarm-worker";
      extraOptions = [
        # Bazel remote-execution worker: joins the internal buildfarm cluster
        # over host networking; it's a trusted CI worker, not a public service.
        # ast-grep-ignore: nix-oci-host-namespace
        "--network=host"
        # Build actions execute from /tmp (compilers, test binaries).
        # ast-grep-ignore: nix-oci-exec-suid-tmpfs
        "--tmpfs=/tmp:exec"
      ];
      volumes = [
        "${config.users.users.pippijn.home}/.config/buildfarm/${config.node.name}.yml:/app/build_buildfarm/config.minimal.yml"
      ];
    };
  };

  programs.mosh.enable = true;
  programs.zsh.enable = true;

  programs.neovim = {
    enable = true;
    viAlias = true;
  };

  networking = {
    enableIPv6 = true;
    useDHCP = true;
#   dhcpcd.extraConfig = "static ip6_address=${config.node.ipv6}";

    extraHosts = lib.concatStrings(
      lib.lists.unique(
        lib.lists.naturalSort(
          builtins.map
            (node: "${node.vpn} ${node.name}.vpn\n" )
            (builtins.attrValues net.nodes))));

    # Resolve hostnames in domain.
    search = [ config.networking.domain ];
    nameservers = [
      "10.43.0.10" # kube-dns.kube-system.svc.cluster.local
      "213.186.33.99" # cdns.ovh.net
    ];
    hostName = config.node.name; # Define your hostname.
    domain = "xinutec.org";

    # enable NAT
    nat = {
      enable = true;
      externalInterface = config.node.externalInterface;
      internalInterfaces =
        builtins.attrNames config.networking.wireguard.interfaces;
    };

    firewall = {
      enable = true;

      # PUBLIC EXPOSURE POLICY: closed by default, explicit list to open. ⚠ But this
      # list governs ONLY host daemons on the public interface, and is NOT where most
      # public ports live — there are two layers:
      #
      #   1. This firewall (nixos-fw INPUT): SSH, kubelet, WireGuard, NFS. SSH (22) is
      #      opened implicitly by services.openssh, so it is absent here — it and
      #      WireGuard are the two remote lifelines, never drop them.
      #
      #   2. Docker / k8s published ports. `docker -p`, k8s hostPort and the ingress
      #      controller open ports via their OWN nat-table DNAT, evaluated BEFORE this
      #      INPUT chain and BYPASSING it. Deleting a port here does NOT close such a
      #      service — verified: the toktok container stayed reachable after its entry
      #      was removed. To keep a containerised service private, bind its publish to
      #      the WireGuard IP (e.g. "${node.vpn}:2223:22") or route it through ingress.
      #      Editing this list is the wrong lever.
      #
      # Internal services need no entry: VPN traffic is trusted (trustedInterfaces
      # below), so anything is reachable over WireGuard.
      #
      # kubelet 10250 is deliberately ABSENT. Both k8s nodes advertise their WireGuard
      # address as InternalIP (amun 10.100.0.1, isis 10.100.0.2), so control-plane→
      # kubelet runs over wg0; listing it only exposed it to the internet, where it
      # answered 401 to the world for no purpose.
      allowedTCPPorts = [ net.vpnPort ];
      allowedUDPPorts = [ net.vpnPort ];

      # Allow traffic to flow freely inside the VPN. docker0 is trusted so the
      # node-local containers can reach host services (metrics, DNS); the bridge
      # is not routable off-host.
      # ast-grep-ignore: nix-docker0-trusted
      trustedInterfaces = config.networking.nat.internalInterfaces ++ [ "docker0" ];

      extraCommands = ''
        # Allow containers to access the API, but don't give them full access
        # to all internal ports.
        iptables -A nixos-fw -p tcp --source ${net.cluster} --dport ${
          toString net.k8sApiPort
        } -j nixos-fw-accept
        iptables -A nixos-fw -p udp --source ${net.cluster} --dport ${
          toString net.k8sApiPort
        } -j nixos-fw-accept
      '' + lib.concatMapStrings oneWayRules oneWayNodes;
      extraStopCommands = lib.concatMapStrings oneWayTeardown oneWayNodes;
    };
  };

  # The declared side of #728's comparison, on disk where a probe can read it.
  # Beside /etc/plan/settings.json rather than anywhere else, because a plan
  # reads it and that directory is what a plan's inputs live in.
  environment.etc."plan/declared-firewall.json".text =
    builtins.toJSON { rules = declaredFirewall; };

  # WireGuard private key for this host — an agenix secret, decrypted
  # at activation to /run/agenix/wireguard-<host>. Each host carries
  # only its own key; recipients are set in agenix/secrets.nix.
  age.secrets."wireguard-${config.node.name}".file =
    ./agenix/wireguard-${config.node.name}.age;

  # ⚠ agenix WRITES AT ACTIVATION AND NEVER DELETES. The retired
  # `root-ssh-{ed25519,rsa}` entries were dropped here 2026-08-22, which left
  # their files on disk — `/root/.ssh/id_{rsa,ed25519}` had to be moved aside by
  # hand on all four hosts. **A host restored from a backup older than that
  # brings them back**, and both names are on OpenSSH's default identity list, so
  # they would silently resume carrying inter-host root logins with a key that is
  # also Pippijn. `fleet_health.py` asserts their absence for that reason.
  # What they were and why they are gone: `agenix/README.md`, #1049.

  # The fleet's own inter-host root key (#1049 step 1).
  #
  # ⚠ `id_fleet`, deliberately NOT `id_ed25519` or `id_rsa`. Those two names are
  # OpenSSH's default identity list, so a key at either is offered by every ssh
  # on the host whether anyone meant it to be or not. A name outside that list
  # means the fleet key is used where it is NAMED and nowhere else.
  age.secrets."root-ssh-fleet" = {
    file = ./agenix/root-ssh-fleet.age;
    path = "/root/.ssh/id_fleet";
    mode = "0600";
    symlink = false;
  };

  # Root's ssh must NAME the fleet key, because `id_fleet` is deliberately not on
  # OpenSSH's default identity list (see the agenix entry above). Without this
  # line, removing `id_rsa` and `id_ed25519` would leave root's outbound ssh
  # offering no key at all — and the thing that would notice is odin's nightly
  # backup, at 02:00, by failing.
  #
  # `localuser`, not `user`: in ssh_config `Match user` is the REMOTE username
  # being connected as, which is not the question.
  #
  # ⚠ NAMING AN IdentityFile REPLACES ROOT'S DEFAULT LIST — it does not add to
  # it. Measured 2026-08-22 with `ssh -v -T git@github.com` from odin: the only
  # line is `Offering public key: /root/.ssh/id_fleet`, and nothing else is
  # tried. That is the behaviour this file WANTS for the fleet, and it broke the
  # one root ssh consumer outside the fleet in the same breath: `/etc/nixos` had
  # a `git@github.com:` remote on amun, isis and odin, authenticated with the
  # very personal key #1049 is removing, and the fetch died on
  # `Permission denied (publickey)`.
  #
  # Fixed where the credential was, not where the symptom was: all three now use
  # the HTTPS remote geb always had. The repository is public, so a read-only
  # fetch needs no credential at all, and root holding a GitHub key was itself
  # a thing worth not having.
  programs.ssh.extraConfig = ''
    Match localuser root
      IdentityFile /root/.ssh/id_fleet
  '';

  networking.wireguard.interfaces = {
    # "wg0" is the network interface name. You can name the interface arbitrarily.
    wg0 = let
      networkConfig = {
        # Determines the IP address and subnet of the server's end of the tunnel interface.
        ips = [ "${config.node.vpn}/24" ];

        # The port that WireGuard listens to. Must be accessible by the client.
        listenPort = net.vpnPort;

        # Path to the private key file — the agenix-decrypted secret
        # declared above. Read by wireguard-wg0.service at runtime.
        privateKeyFile = config.age.secrets."wireguard-${config.node.name}".path;
      };
      peerConfig = if config.node.name == net.nodes.master.name then {
        # This allows the wireguard server to route your traffic to the internet and hence be like a VPN
        # For this to work you have to set the dnsserver IP of your router (or dnsserver of choice) in your clients
        postSetup = ''
          ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s ${net.vpn} -o ${config.node.externalInterface} -j MASQUERADE
        '';

        # This undoes the above command
        postShutdown = ''
          ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s ${net.vpn} -o ${config.node.externalInterface} -j MASQUERADE
        '';

        # Allow all other nodes to be peers.
        peers = builtins.map (node: {
          publicKey = "${node.publicKey}";
          allowedIPs = [ "${node.vpn}/32" ];
        }) (builtins.filter (node: node.name != config.node.name) (builtins.attrValues net.nodes));
      } else {
        peers = [
          # For a client configuration, one peer entry for the server will suffice.
          {
            # Public key of the server (not a file path).
            publicKey = net.nodes.master.publicKey;

            # Forward all the traffic via VPN.
            #allowedIPs = [ "0.0.0.0/0" ];
            # Or forward only particular subnets
            allowedIPs = [ net.vpn ];

            # Set this to the server IP and port.
            # TODO: route to endpoint not automatically configured https://wiki.archlinux.org/index.php/WireGuard#Loop_routing https://discourse.nixos.org/t/solved-minimal-firewall-setup-for-wireguard-client/7577
            endpoint = "${net.nodes.master.ipv4}:${toString net.vpnPort}";

            # Send keepalives every 25 seconds. Important to keep NAT tables alive.
            persistentKeepalive = 25;
          }
        ];
      };
    in pkgs.lib.mkMerge [ networkConfig peerConfig ];
  };

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;

  users = {
    mutableUsers = false;

    users = {
      root.openssh.authorizedKeys.keys = sshKeys.root;

      pippijn = {
        uid = 1000;
        isNormalUser = true;
        shell = pkgs.zsh;
        home = "/home/pippijn";
        # dev-lint: allow-pii — the account's own GECOS full name, by definition.
        description = "Pippijn van Steenhoven";
        extraGroups = [ "docker" "wheel" ];
        openssh.authorizedKeys.keys = sshKeys.pippijn;
      };
    };
  };

  # Keep the pippijn home checkout fast-forwarded to origin/main. Every
  # server's home dir is a clone of github.com:xinutec/pippijn, and with
  # no automation they silently drift (observed 2026-06-16: 41–261 commits
  # behind). FAST-FORWARD ONLY: if a host ever has local commits or a real
  # conflict it logs and skips — it never merges, rebases or forces, so
  # local work and the perpetually-rewritten .config/rclone/rclone.conf are
  # left untouched. Uses `git merge --ff-only` rather than `git pull` so a
  # host-local `pull.rebase=true` (isis has it) can't turn the sync into a
  # rebase that aborts on the dirty rclone.conf. Drift that can't auto-heal
  # is surfaced by the home-checkout check in xinutec-infra fleet_health.py.
  systemd.services.home-autosync = {
    description = "Fast-forward the pippijn home checkout to origin/main";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [ git git-crypt openssh ];
    serviceConfig = {
      Type = "oneshot";
      User = "pippijn";
      WorkingDirectory = config.users.users.pippijn.home;
      Environment = "HOME=${config.users.users.pippijn.home}";
    };
    script = ''
      # No `set -e`: exit codes are handled explicitly so a non-ff merge
      # is a clean skip, not a unit failure.
      if ! git fetch --quiet origin; then
        echo "home-autosync: fetch failed (offline?), skipping this run"
        exit 0
      fi
      before=$(git rev-parse --short HEAD)
      if git merge --ff-only origin/main; then
        after=$(git rev-parse --short HEAD)
        if [ "$before" = "$after" ]; then
          echo "home-autosync: already current at $after"
        else
          echo "home-autosync: fast-forwarded $before -> $after"
        fi
      else
        echo "home-autosync: SKIPPED — cannot fast-forward (local commits or conflict); manual reconcile needed" >&2
      fi
    '';
  };

  systemd.timers.home-autosync = {
    description = "Hourly fast-forward of the pippijn home checkout";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      # Stagger the three hosts so they don't all hit GitHub at :00.
      RandomizedDelaySec = "5m";
    };
  };
}
