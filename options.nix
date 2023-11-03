# Options.
{ lib, ... }:

with lib;

let
  nodeModule = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        example = "amun";
        description = "The node hostname part before '.xinutec.org'.";
      };

      ipv4 = mkOption {
        type = types.str;
        example = "219.38.29.10";
        description = "The public IPv4 address of the node.";
      };

      ipv6 = mkOption {
        type = types.str;
        example = "2001:41d0:2:7a85::1";
        description = "The public IPv6 address of the node.";
      };

      vpn = mkOption {
        type = types.str;
        example = "10.100.0.50";
        description = "The internal VPN IPv4 address of the node.";
      };

      publicKey = mkOption {
        type = types.str;
        example = "9iISDdDl9g57OE+yhQMNJjAVsaBqHurf4iUjnZ9GQF4=";
        description = "The Wireguard public key of the node.";
      };

      externalInterface = mkOption {
        type = types.str;
        example = "eth0";
        description = "External network interface for the node (check ifconfig for the interface with the public IP address).";
      };
    };
  };
in {
  options.node = mkOption {
    type = nodeModule;
    description = "The current machine node configuration.";
  };
}
