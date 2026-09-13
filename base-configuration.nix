# Shared base for every fleet host. Machine files undo what does not suit them.

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

  # A one-way node defends ITSELF. This was inverted until 2026-09-04, so the
  # machines the threat model distrusts were the ones enforcing it.
  selfOneWay = config.node.oneWay or false;

  # Created on EVERY host, jumped to only where `selfOneWay`: `iptables -S` on a
  # missing chain errors, and the firewall plan reads that as Unreadable rather
  # than as "declares nothing" — the one distinction that fact exists to keep.
  oneWayChain = "xinutec-oneway";

  # `throw`, not a silent skip: a misspelled name would generate no rule at all,
  # which reads exactly like the exception having been granted.
  vpnOf = named:
    (net.nodes.${named} or (throw
      "reachableFrom names ${named}, which is not a node in network.nix"
    )).vpn;


  # ── The rules this repository declares, AS DATA ───────────────────────────
  #
  # Rendered to /etc/plan/declared-firewall.json so the declared side can be READ;
  # rules otherwise exist only as shell evaluation. #727 is what that cost.
  #
  # Spelled in `iptables -S` OUTPUT form, copied from live output, not composed:
  # iptables re-renders canonically (`-d X` becomes `-d X/32`, ctstate reorders).
  # A second rendering of the same values, deliberately NOT a generator for the
  # first. A drifting declaration is the thing being detected.
  # Every rule carries its family, or a v4 reading satisfies a v6 declaration.
  # Scope is OUR rules only, not what the firewall module, Docker or k3s inject.
  withFamily = f: rules: map (r: r // { family = f; }) rules;

  declaredFirewall = withFamily "inet" declaredFirewall4
    ++ withFamily "inet6" declaredFirewall6;

  # ...only on a one-way node; the chain is empty and unreferenced elsewhere.
  declaredFirewall6 = lib.optionals selfOneWay [
    {
      chain = "INPUT";
      spec = "-A INPUT -i ${config.node.externalInterface} -j ${oneWayChain}";
      why = "everything arriving from outside the house is judged by our own chain";
    }
    {
      chain = oneWayChain;
      spec = "-A ${oneWayChain} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT";
      why = "replies to connections this host opened itself";
    }
    {
      chain = oneWayChain;
      spec = "-A ${oneWayChain} -p ipv6-icmp -j ACCEPT";
      why = "ICMPv6 is what makes IPv6 work: neighbour discovery and Packet Too Big";
    }
    {
      chain = oneWayChain;
      spec = "-A ${oneWayChain} -s fe80::/10 -j ACCEPT";
      why = "link-local carries router advertisements, DHCPv6 and mDNS";
    }
    {
      chain = oneWayChain;
      spec = "-A ${oneWayChain} -j DROP";
      why = "nothing on the internet may initiate toward this host";
    }
  ];

  declaredFirewall4 =
    # The two container→API accepts, from the same `net` values `extraCommands`
    # interpolates.
    (map (proto: {
      chain = "nixos-fw";
      spec = "-A nixos-fw -s ${net.cluster} -p ${proto} -m ${proto} --dport ${
          toString net.k8sApiPort
        } -j nixos-fw-accept";
      why = "containers reach the API and nothing else internal";
    }) [ "tcp" "udp" ])
    # Reads the same `net.vpnPort` the module does, so no second list can go stale.
    # SSH's 22 is deliberately absent: openssh.openFirewall opens it, and
    # declaring it here would assert another module's default.
    ++ (map (proto: {
      chain = "nixos-fw";
      spec = "-A nixos-fw -p ${proto} -m ${proto} --dport ${
          toString net.vpnPort
        } -j nixos-fw-accept";
      why = "WireGuard, one of the two remote lifelines";
    }) [ "tcp" "udp" ])
    # `RELATED,ESTABLISHED` here against `ESTABLISHED,RELATED` in the command
    # below is not a typo — this side must match what `iptables -S` prints.
    ++ (lib.optionals selfOneWay ([{
      chain = "INPUT";
      spec = "-A INPUT -i wg0 -j ${oneWayChain}";
      why = "everything arriving over the VPN is judged by our own chain";
    }
    {
      chain = oneWayChain;
      spec =
        "-A ${oneWayChain} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT";
      why = "replies to connections this host opened itself";
    }] ++ (map (peer: {
      chain = oneWayChain;
      spec = "-A ${oneWayChain} -s ${vpnOf peer}/32 -j ACCEPT";
      why = "${peer} may initiate toward this host";
    }) (config.node.reachableFrom or [ ])) ++ [{
      chain = oneWayChain;
      spec = "-A ${oneWayChain} -j DROP";
      why = "nothing else on the VPN may initiate toward this host";
    }]));

  # Teardown runs before the inserts so a firewall reload is idempotent rather
  # than stacking a second copy of every rule, and is used on its own by
  # extraStopCommands. `-X` last: a chain still jumped to cannot be deleted.
  oneWayTeardown = ''
    iptables -w -D INPUT -i wg0 -j ${oneWayChain} 2>/dev/null || true
    iptables -w -F ${oneWayChain} 2>/dev/null || true
    iptables -w -X ${oneWayChain} 2>/dev/null || true
  '';

  # ── The same property, one address family over ────────────────────────────
  #
  # The VPN is IPv4-only, so this half is about the INTERNET: at home the boxes
  # hold globally routable v6 addresses with no NAT in front of them.
  # No `reachableFrom` admits here — those name VPN peers, which have no v6
  # address, so such a rule could never match.
  oneWayTeardown6 = ''
    ip6tables -w -D INPUT -i ${config.node.externalInterface} -j ${oneWayChain} 2>/dev/null || true
    ip6tables -w -F ${oneWayChain} 2>/dev/null || true
    ip6tables -w -X ${oneWayChain} 2>/dev/null || true
  '';

  oneWayRules6 = ''
    # Created on every host. Asserted by scripts/firewall_order.py.
  '' + oneWayTeardown6 + ''
    ip6tables -w -N ${oneWayChain}
  '' + lib.optionalString selfOneWay (''
    ip6tables -w -A ${oneWayChain} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    # Before the DROP. Order asserted by scripts/firewall_order.py.
    ip6tables -w -A ${oneWayChain} -p ipv6-icmp -j ACCEPT
    # Link-local: router advertisements, DHCPv6, mDNS.
    ip6tables -w -A ${oneWayChain} -s fe80::/10 -j ACCEPT
    ip6tables -w -A ${oneWayChain} -j DROP
    # Scoped to the external interface, where v4 scopes to wg0 — an unscoped
    # jump would also judge lo, and ::1 traffic would meet the DROP.
    ip6tables -w -I INPUT 1 -i ${config.node.externalInterface} -j ${oneWayChain}
  '');

  oneWayRules = ''
    # The VPN-facing chain. Empty and unreferenced except on a one-way node.
  '' + oneWayTeardown + ''
    iptables -w -N ${oneWayChain}
  '' + lib.optionalString selfOneWay (''
    # First. Order asserted by scripts/firewall_order.py.
    iptables -w -A ${oneWayChain} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  '' + lib.concatMapStrings (peer: ''
    # ${peer} may initiate toward this host.
    iptables -w -A ${oneWayChain} -s ${vpnOf peer}/32 -j ACCEPT
  '') (config.node.reachableFrom or [ ]) + ''
    iptables -w -A ${oneWayChain} -j DROP
    iptables -w -I INPUT 1 -i wg0 -j ${oneWayChain}
  '');

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

      # PUBLIC EXPOSURE POLICY: closed by default, explicit list to open — but this
      # governs ONLY host daemons. Docker/k8s published ports DNAT in the nat table
      # BEFORE this chain and bypass it, so deleting an entry here does not close such
      # a service; bind its publish to the VPN address or use ingress instead.
      # SSH is opened by services.openssh; kubelet 10250 is absent on purpose, since
      # both k8s nodes advertise their WireGuard address as InternalIP.
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
      '' + oneWayRules + oneWayRules6;
      extraStopCommands = oneWayTeardown + oneWayTeardown6;
    };
  };

  # The declared side of #728's comparison, beside the other plan inputs.
  environment.etc."plan/declared-firewall.json".text =
    builtins.toJSON { rules = declaredFirewall; };

  # Each host carries only its own key; recipients are in agenix/secrets.nix.
  age.secrets."wireguard-${config.node.name}".file =
    ./agenix/wireguard-${config.node.name}.age;

  # agenix WRITES AT ACTIVATION AND NEVER DELETES. The retired root-ssh-* entries
  # left their files on disk, and a host RESTORED FROM AN OLDER BACKUP brings them
  # back — both names are on OpenSSH's default identity list, so they would silently
  # resume carrying root logins. fleet_health.py asserts their absence. See #1049.

  # The fleet's inter-host root key. `id_fleet`, deliberately NOT `id_ed25519` or
  # `id_rsa`: those are OpenSSH's default identity list and would be offered to
  # everything. A name outside that list is used where NAMED and nowhere else.
  age.secrets."root-ssh-fleet" = {
    file = ./agenix/root-ssh-fleet.age;
    path = "/root/.ssh/id_fleet";
    mode = "0600";
    symlink = false;
  };

  # Root's ssh must NAME the fleet key, since id_fleet is off the default list.
  # `localuser`, not `user`: `Match user` means the REMOTE username.
  #
  # Naming an IdentityFile REPLACES root's default list rather than adding to it.
  # That broke the one root ssh consumer outside the fleet; /etc/nixos uses the
  # HTTPS remote now, which needs no credential for a public repo.
  #
  # The private xinutec-infra fetch in machines/{odin,isis}/plan-run.nix still
  # needs a key, and its failure is LATENT: fetchGit only hits the network for a rev
  # the store lacks, so every rebuild succeeds until the first pin BUMP. Each host
  # has its own read-only deploy key, generated in place and never in agenix; list
  # them with `gh repo deploy-key list --repo xinutec/xinutec-infra`.
  #
  # Order asserted by scripts/ssh_config_order.py.
  programs.ssh.extraConfig = ''
    Host github.com
      IdentityFile /root/.ssh/id_github_infra

    Match localuser root
      IdentityFile /root/.ssh/id_fleet
  '';

  networking.wireguard.interfaces = {
    wg0 = let
      networkConfig = {
        ips = [ "${config.node.vpn}/24" ];

        listenPort = net.vpnPort;

        privateKeyFile = config.age.secrets."wireguard-${config.node.name}".path;
      };
      peerConfig = if config.node.name == net.nodes.master.name then {
        # Masquerade so the hub can route peer traffic to the internet.
        postSetup = ''
          ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s ${net.vpn} -o ${config.node.externalInterface} -j MASQUERADE
        '';

        postShutdown = ''
          ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s ${net.vpn} -o ${config.node.externalInterface} -j MASQUERADE
        '';

        peers = builtins.map (node: {
          publicKey = "${node.publicKey}";
          allowedIPs = [ "${node.vpn}/32" ];
        }) (builtins.filter (node: node.name != config.node.name) (builtins.attrValues net.nodes));
      } else {
        peers = [
          {
            publicKey = net.nodes.master.publicKey;

            # Split tunnel: fleet addresses only.
            allowedIPs = [ net.vpn ];

            endpoint = "${net.nodes.master.ipv4}:${toString net.vpnPort}";

            # Keeps the NAT mapping alive so the hub can reach back.
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

  # Every server's home dir is a clone of xinutec/pippijn, and they silently drift.
  # FAST-FORWARD ONLY — local commits or a conflict log and skip, never merge or
  # force. `merge --ff-only` rather than `pull`, so a host-local pull.rebase cannot
  # turn this into a rebase that aborts on the dirty rclone.conf.
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
