# The `.vpn` names over DNS, served by the VPN hub for the peers that are not
# NixOS hosts (the Mac, phones), which used to copy the table by hand. NixOS hosts
# read the same names from /etc/hosts (`extraHosts` in base-configuration.nix);
# both render one table, network.nix, so they cannot disagree.
#
# On the hub only, bound to its VPN address alone: a peer may ask, the internet
# cannot reach it. It answers `.vpn` and nothing else, so it is no resolver.
{ config, lib, ... }:

let
  net = import ./network.nix;
  hub = net.nodes.master;
in
{
  config = lib.mkIf (config.node.name == hub.name) {
    services.dnsmasq = {
      enable = true;
      # The hub keeps its own resolvers; this serves the VPN, not the host.
      resolveLocalQueries = false;
      settings = {
        listen-address = hub.vpn;
        # Binds when wg0 brings the address up, so boot order cannot fail it.
        bind-dynamic = true;
        no-resolv = true;
        no-hosts = true;
        local = "/vpn/";
        host-record = lib.unique (lib.naturalSort (map (n: "${n.name}.vpn,${n.vpn}") (builtins.attrValues net.nodes)));
      };
    };
  };
}
