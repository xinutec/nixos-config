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

  # ⚠ A ONE-WAY NODE DEFENDS ITSELF. Until 2026-09-04 this was inverted: every
  # OTHER host generated an OUTPUT/FORWARD drop toward the protected node, so the
  # machines the threat model DISTRUSTS were the ones enforcing it — and a
  # compromised server removes its own rule with one `iptables -D`.
  #
  # Pippijn, 2026-09-04: *"We have to assume the server could be hacked, but it
  # wouldn't be able to hack into the home machines from there."*
  #
  # The Mac already worked this way and always had: its pf anchor holds even
  # against a compromised hub. geb and shu had the LABEL without the defence.
  #
  # What this costs: the fleet no longer stops itself dialling home, so the
  # property now depends on the protected host being up and configured. That is
  # the right trade — an unreachable home machine is a home machine nobody can
  # damage either.
  selfOneWay = config.node.oneWay or false;

  # ⚠ CREATED ON EVERY HOST, jumped to only where `selfOneWay`. `iptables -S` on
  # a chain that does not exist is an ERROR, and the firewall plan would read
  # that as Unreadable rather than as "declares nothing" — the one distinction
  # that whole fact exists to keep apart.
  oneWayChain = "xinutec-oneway";

  # The VPN address of a node named in some other node's `reachableFrom`.
  # `throw` rather than a silent skip: a misspelled name would generate no rule
  # at all, which reads exactly like the exception having been granted — and the
  # thing being granted is the right to open connections to a machine the fleet
  # is otherwise forbidden to touch.
  vpnOf = named:
    (net.nodes.${named} or (throw
      "reachableFrom names ${named}, which is not a node in network.nix"
    )).vpn;


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
  # ⚠ EVERY DECLARED RULE CARRIES ITS ADDRESS FAMILY. Untagged the two families
  # cancel: `-A INPUT -j nixos-fw` exists in both tables and is a DIFFERENT rule
  # in each, so a v4 reading would satisfy a v6 declaration and a host missing
  # its entire v6 half would compare as converged. The reader defaults a missing
  # family to `inet`, so a host on an older generation keeps its v4 judgement.
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

  # ⚠ Spellings MEASURED on geb 2026-09-04, not predicted: ip6tables renders
  # `--ctstate ESTABLISHED,RELATED` back as `RELATED,ESTABLISHED`, exactly as
  # iptables does. A declaration written the way the command is typed would
  # compare unequal on that rule for ever.

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
    # ...and, ONLY on a node that is itself one-way, the chain it refuses the VPN
    # with. Per host now, not fleet-wide: the rule lives on the machine being
    # protected, so the declaration does too.
    #
    # ⚠ `RELATED,ESTABLISHED` here against `ESTABLISHED,RELATED` in the command
    # below is not a typo — iptables NORMALISES the order when it renders, and
    # this side must match what `iptables -S` prints, not what was typed.
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
  # ⚠ THE VPN IS IPv4-ONLY: wg0 carries no IPv6 address on any host, so a v6
  # chain jumped from `-i wg0` would be dead code. This half is about the
  # INTERNET. At home the machines hold globally routable v6 addresses with no
  # NAT in front of them, and `allowedTCPPorts` is family- and source-agnostic,
  # so "ssh is open" meant open to anyone the router let through. Measured
  # 2026-09-04: the pixel9 opened geb's public v6 :22 directly.
  #
  # ⚠ NO `reachableFrom` ADMITS HERE, deliberately. Those name VPN peers, and
  # peers have no v6 address to admit — an admit spelled in this family would be
  # a rule that can never match, and a declaration nobody can satisfy.
  oneWayTeardown6 = ''
    ip6tables -w -D INPUT -i ${config.node.externalInterface} -j ${oneWayChain} 2>/dev/null || true
    ip6tables -w -F ${oneWayChain} 2>/dev/null || true
    ip6tables -w -X ${oneWayChain} 2>/dev/null || true
  '';

  oneWayRules6 = ''
    # ⚠ CREATED ON EVERY HOST, exactly as the v4 chain is, so `ip6tables -S
    # xinutec-oneway` ANSWERS everywhere. The probe loops families x chains and
    # reads a non-zero exit as Unreadable, so a chain present in one table and
    # absent from the other would make the whole firewall fact unreadable on the
    # three hosts that are not one-way — losing the v4 judgement that works.
  '' + oneWayTeardown6 + ''
    ip6tables -w -N ${oneWayChain}
  '' + lib.optionalString selfOneWay (''
    ip6tables -w -A ${oneWayChain} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    # ⚠ ICMPv6 BEFORE THE DROP, AND THIS IS NOT POLITENESS — it is what keeps
    # IPv6 working at all. A neighbour advertisement from an ON-LINK host carries
    # that host's GLOBAL source address, not its link-local one, so the fe80::/10
    # line below does NOT cover it; without this rule the DROP eats it and the
    # machine cannot open an IPv6 connection to its own subnet. Packet Too Big
    # goes the same way, so PMTU discovery fails and large transfers HANG rather
    # than fail. The Mac shipped exactly this bug hours earlier and it verified
    # clean, because traffic via the ROUTER kept working the whole time — the
    # router answers from fe80::.
    ip6tables -w -A ${oneWayChain} -p ipv6-icmp -j ACCEPT
    # Link-local: router advertisements, DHCPv6, mDNS.
    ip6tables -w -A ${oneWayChain} -s fe80::/10 -j ACCEPT
    ip6tables -w -A ${oneWayChain} -j DROP
    # ⚠ Scoped to the EXTERNAL interface, where the v4 jump is scoped to wg0.
    # Same chain name, same meaning, different door. An unscoped jump would also
    # judge lo, and ::1 traffic would meet the DROP.
    ip6tables -w -I INPUT 1 -i ${config.node.externalInterface} -j ${oneWayChain}
  '');

  oneWayRules = ''
    # The VPN-facing chain. Empty and unreferenced except on a one-way node.
  '' + oneWayTeardown + ''
    iptables -w -N ${oneWayChain}
  '' + lib.optionalString selfOneWay (''
    # ⚠ ESTABLISHED FIRST, or this drops the replies to our OWN outbound traffic
    # and kills the VPN in the legitimate direction too. The Mac shipped exactly
    # that bug on 2026-06-10 — macOS pf needs `pass out keep state` for the same
    # reason — and fixed it the same day. Do not reorder these.
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
      '' + oneWayRules + oneWayRules6;
      extraStopCommands = oneWayTeardown + oneWayTeardown6;
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
  # ⚠ The HTTPS fix above covers `/etc/nixos` and NOT the other root consumer of
  # GitHub: `builtins.fetchGit` on the PRIVATE xinutec-infra repo, in
  # machines/{odin,isis}/plan-run.nix. A private repo cannot be fetched
  # anonymously, so from 2026-08-22 — when root's personal keys were renamed
  # away — those hosts could no longer fetch it.
  #
  # ⚠ THE FAILURE IS LATENT, which is why two days passed without it showing.
  # fetchGit only reaches the network for a rev the store does not already have,
  # so every rebuild that keeps the pin succeeds and the first pin BUMP fails.
  # Found 2026-08-24 by bumping odin's pin for #1120.
  #
  # Each host has its own key, generated on the host and never copied, whose
  # public half is a READ-ONLY deploy key on that one repository. Read-only
  # because these hosts only ever fetch, per-host so revoking one leaves the
  # other alone, and per-repo so it is not a fleet credential. Enumerate them
  # with `gh repo deploy-key list --repo xinutec/xinutec-infra`.
  #
  #   odin  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMWMrtZlJW7/JCzulLls7j1jNAewBADETjZkPdqolh4N
  #   isis  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEwI9CKCOOA0OHv43FIJzZID3BxWe/HRm5B2WgifD2on
  #   geb   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEItSyDjL29z1c8MkdHN1FWYsblOJecO3Kyp4lh8/jmr
  #
  # ⚠ geb IS ONE OF THESE, and calling its clone "inert behind a `test -d`" was
  # wrong. /opt/xinutec-infra already exists, so the guard never fires — but the
  # remote is this ssh URL and `git -C /opt/xinutec-infra pull` is geb's
  # DOCUMENTED update path (see machines/geb/configuration.nix). That pull was
  # broken from 08-22 until 08-24, and only fleet-health's
  # PRIVATE FETCH CREDENTIALS check surfaced it.
  #
  # amun offers github nothing, which is what every host did before this block
  # existed; it fetches nothing over ssh, so it needs nothing.
  #
  # The private half is NOT in agenix: it is generated in place like a host key,
  # so it never transits and a reinstall regenerates it — at the cost of a new
  # deploy key, which the line above says how to list.
  #
  # ⚠ `Host github.com` must come FIRST. ssh_config takes the FIRST value it
  # obtains for a keyword, so the `Match localuser root` below would otherwise
  # pin id_fleet for github too — and id_fleet is authorised on the fleet, not on
  # GitHub.
  programs.ssh.extraConfig = ''
    Host github.com
      IdentityFile /root/.ssh/id_github_infra

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
