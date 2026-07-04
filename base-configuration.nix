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
        "--network=host"
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

      # PUBLIC EXPOSURE POLICY: closed by default; a service reaches the
      # internet only if it is *explicitly* listed. But note this list governs
      # ONLY host-level services on the public interface — it is one of TWO
      # layers, and it is NOT where most public ports live:
      #
      #   1. This firewall (nixos-fw INPUT). Governs host daemons: SSH, kubelet,
      #      WireGuard, NFS, etc. SSH (22) is opened *implicitly* by
      #      services.openssh (openFirewall defaults true) and so isn't listed
      #      here — it and WireGuard are the two remote lifelines: never drop
      #      them. kubelet (10250) is public pending the --node-ip=<vpn>
      #      migration that would move it onto WireGuard.
      #
      #   2. Docker / k8s published ports. `docker -p`, k8s hostPort, and the
      #      ingress controller open ports via their OWN nat-table DNAT, which
      #      is evaluated BEFORE this INPUT chain and BYPASSES it entirely.
      #      Deleting a port here does NOT close such a service (verified: the
      #      toktok container stayed reachable after its firewall entry was
      #      removed). To keep a containerised service private, bind its publish
      #      to the WireGuard IP (e.g. toktok: "${node.vpn}:2223:22") or route it
      #      through ingress — editing this list is the wrong lever.
      #
      # Internal services need no entry at all: VPN traffic is trusted (see
      # trustedInterfaces below), so anything is reachable over WireGuard.
      allowedTCPPorts = [ 10250 net.vpnPort ];
      allowedUDPPorts = [ net.vpnPort ];

      # Allow traffic to flow freely inside the VPN.
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

        # One-way VPN for mac-mini (${net.nodes.mac-mini.vpn}): the Mac may
        # initiate connections into the VPN, but nothing on the VPN — this
        # host, its pods, or forwarded peer traffic — may initiate toward the
        # Mac. Only return traffic for Mac-initiated connections passes. The
        # Mac enforces the same with pf; this is defense in depth (see
        # xinutec-infra/mac-mini.md). -D before -I keeps reloads idempotent.
        iptables -w -D FORWARD -d ${net.nodes.mac-mini.vpn} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        iptables -w -D FORWARD -d ${net.nodes.mac-mini.vpn} -j DROP 2>/dev/null || true
        iptables -w -I FORWARD 1 -d ${net.nodes.mac-mini.vpn} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -w -I FORWARD 2 -d ${net.nodes.mac-mini.vpn} -j DROP
        iptables -w -D OUTPUT -d ${net.nodes.mac-mini.vpn} -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
        iptables -w -I OUTPUT 1 -d ${net.nodes.mac-mini.vpn} -m conntrack --ctstate NEW -j DROP
      '';
      extraStopCommands = ''
        iptables -w -D FORWARD -d ${net.nodes.mac-mini.vpn} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        iptables -w -D FORWARD -d ${net.nodes.mac-mini.vpn} -j DROP 2>/dev/null || true
        iptables -w -D OUTPUT -d ${net.nodes.mac-mini.vpn} -m conntrack --ctstate NEW -j DROP 2>/dev/null || true
      '';
    };
  };

  # WireGuard private key for this host — an agenix secret, decrypted
  # at activation to /run/agenix/wireguard-<host>. Each host carries
  # only its own key; recipients are set in agenix/secrets.nix.
  age.secrets."wireguard-${config.node.name}".file =
    ./agenix/wireguard-${config.node.name}.age;

  # Root user's SSH private keys — agenix secrets, decrypted at
  # activation straight to /root/.ssh/ (symlink = false: a real file
  # where ssh expects it, no symlink/ramfs indirection). One shared
  # keypair of each type fleet-wide, for inter-host root SSH.
  age.secrets."root-ssh-ed25519" = {
    file = ./agenix/root-ssh-ed25519.age;
    path = "/root/.ssh/id_ed25519";
    mode = "0600";
    symlink = false;
  };
  age.secrets."root-ssh-rsa" = {
    file = ./agenix/root-ssh-rsa.age;
    path = "/root/.ssh/id_rsa";
    mode = "0600";
    symlink = false;
  };

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
      root.openssh.authorizedKeys.keys = sshKeys.pippijn;

      pippijn = {
        uid = 1000;
        isNormalUser = true;
        shell = pkgs.zsh;
        home = "/home/pippijn";
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
