{ config, pkgs, ... }:

let net = import ../../network.nix;
in {
  imports = [
    ../../base-configuration.nix
    ./plan-run.nix
    ./plan-settings.nix
    ./picade-health.nix
    ./plan-picade.nix
    ../../plan-fleetwatch.nix
    # Importing this is the CUTOVER (#1294), and it does not work alone: nginx
    # receives nothing until the ingress-nginx LoadBalancer Service is deleted.
    ./frontdoor.nix
  ];

  # All observe-only. `picade` is here because its absence hid six days of broken
  # convergence (#1233) — an advisory plan still exits 0 when nothing is readable.
  services.planFleetwatch.plans = [ "firewall" "picade" "frontdoor" "images" ];

  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    # Needed in the closure, not fetched at backup time: odin's backup-prepare.sh
    # runs sqlite3 here, and nix-shell -p pulled 101.6 MiB of stdenv mid-backup.
    sqlite
  ];

  # No machine-specific public ports.
  networking.firewall.allowedTCPPorts = [ ];

  # KEEP THE IMAGE HOARD DOWN (#1311, #1329). This host boots from a spinning
  # disk and containerd's startup scales with image count — a few thousand images
  # take minutes and read as a k3s deadlock. Nothing prunes it and `:latest` adds
  # one per rebuild, so check `k3s crictl images -q | wc -l` before suspecting
  # anything cleverer. If you must restart k3s, give it ~2 minutes, then
  # `kubectl delete pod` signal/messages — a reused emptyDir crash-loops them.
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags =
      "--disable traefik --advertise-address ${config.node.vpn} --flannel-iface=wg0 --secrets-encryption --resolv-conf=/etc/k3s-resolv.conf";
  };

  # CoreDNS's upstreams (#1621). The node's own list names CoreDNS first, so
  # inheriting it made CoreDNS forward to itself, and its one real upstream,
  # OVH, answers SERVFAIL for `auth.docker.io` A at :00 and :30 — which CoreDNS
  # caches and image pulls report as "no such host".
  environment.etc."k3s-resolv.conf".text = ''
    nameserver 1.1.1.1
    nameserver 8.8.8.8
  '';

  # The agent console's way in: the Mac dials out and asks sshd to listen on this
  # host's VPN address. TLS terminates at the Mac, so this host carries only
  # ciphertext. `clientspecified` keeps the listener off the public interface.
  services.openssh.settings.GatewayPorts = "clientspecified";

  # Reap a vanished client or its listener wedges the port for every redial, and
  # the console is a black hole until it clears — an ISP address change is enough
  # to cause it. Matches console-tunnel.sh's own timings on the Mac side.
  services.openssh.settings.ClientAliveInterval = 30;
  services.openssh.settings.ClientAliveCountMax = 3;

  # Its own key, restricted to that one listener: on the admin key, anything
  # holding the Mac's disk would get a root session here.
  users.users.pippijn.openssh.authorizedKeys.keys = [
    ''restrict,port-forwarding,permitlisten="${config.node.vpn}:${
      toString net.consolePort
    }" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBJAGJDba9uOuPZNe/LHngVUXao8Uv+2y5TDLvOA7icR console-tunnel@mac-mini''

  ];
}
