# CoreDNS's upstreams, for every k3s host that imports this (#1621).
#
# k3s hands CoreDNS the node's resolv.conf unless told otherwise, and the node's
# names CoreDNS itself first (base-configuration.nix), so CoreDNS forwarded to
# itself; its one real upstream, OVH, answered SERVFAIL for `auth.docker.io` at
# :00 and :30, which CoreDNS cached and image pulls reported as "no such host".
# fleet_health's `coredns upstreams` line fails a cluster whose CoreDNS still
# names itself.
#
# A host puts `config.xinutec.k3sDns.flag` into its own `services.k3s.extraFlags`.
# Imported per host, never from the base: the flag restarts k3s, so a host takes
# it when a restart is planned, not with its next unrelated switch.
{ lib, ... }:

{
  options.xinutec.k3sDns.flag = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = "--resolv-conf=/etc/k3s-resolv.conf";
    description = "The k3s flag that gives CoreDNS the upstreams below.";
  };

  config.environment.etc."k3s-resolv.conf".text = ''
    nameserver 1.1.1.1
    nameserver 8.8.8.8
  '';
}
