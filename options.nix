# Options.
{ lib, ... }:

with lib;

let
  nodeModule = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        example = "amun";
        description = "The node hostname part before '.xinutec.org' (required).";
      };

      # Null for a node that has no public address of its own — geb sits behind
      # the house router, and only the VPN hub is ever dialled by name. The one
      # reader that matters is the WireGuard endpoint in base-configuration.nix,
      # and it reads the MASTER's ipv4, which is always set.
      ipv4 = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "219.38.29.10";
        description = "The public IPv4 address of the node, or null if it has none.";
      };

      ipv6 = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "2001:41d0:2:7a85::1";
        description = "The public IPv6 address of the node, or null if it has none.";
      };

      vpn = mkOption {
        type = types.str;
        example = "10.100.0.50";
        description = "The internal VPN IPv4 address of the node (required).";
      };

      publicKey = mkOption {
        type = types.str;
        example = "9iISDdDl9g57OE+yhQMNJjAVsaBqHurf4iUjnZ9GQF4=";
        description = "The Wireguard public key of the node (required).";
      };

      externalInterface = mkOption {
        type = types.str;
        example = "eth0";
        description = "External network interface for the node (check ifconfig for the interface with the public IP address).";
      };

      oneWay = mkOption {
        type = types.bool;
        default = false;
        description = ''
          The node may initiate into the VPN, but nothing on the VPN may
          initiate toward it. Enforced by firewall rules in
          base-configuration.nix, generated for every node carrying this flag —
          so marking a node here is what creates the rules, and there is no
          second place to remember. The node is expected to enforce the same
          locally (mac-mini does it with pf); this side is defence in depth.
        '';
      };

      intermittent = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Liveness class for the fleetwatch vpn-nodes producer. A peer that comes
          and goes (phone, laptop, arcade cabinet) is expected to be down and reads
          as SKIP, not FAIL, when it has no recent handshake. Default false =
          always-on: down is a real fault and alerts. See machines/amun/vpn-nodes.nix.
        '';
      };
    };
  };
in {
  options.node = mkOption {
    type = nodeModule;
    description = "The current machine node configuration.";
  };
}
