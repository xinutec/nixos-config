# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let net = import ../../network.nix;
in {
  imports = [ ../../base-configuration.nix ];

  fileSystems."/export" = {
    device = "${net.nodes.master.vpn}:/export";
    fsType = "nfs4";
  };

  virtualisation.oci-containers.containers = {
    buildfarm-redis = {
      image = "redis:alpine";
      extraOptions = [ "--network=host" ];
    };
  };

  systemd.timers."rancher-backup" = {
    wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1h";
        OnUnitActiveSec = "1h";
        Unit = "rancher-backup.service";
      };
  };
  
  systemd.services."rancher-backup" = {
    # https://docs.k3s.io/datastore/backup-restore
    script = ''
      # amun is the k3s server
      "${pkgs.rsync}/bin/rsync" --rsh="${pkgs.openssh}/bin/ssh" -avrP --delete amun:/var/lib/rancher/k3s/server/token /backup/amun/var/lib/rancher/k3s/server/
      "${pkgs.rsync}/bin/rsync" --rsh="${pkgs.openssh}/bin/ssh" -avrP --delete amun:/var/lib/rancher/k3s/server/db/ /backup/amun/var/lib/rancher/k3s/server/db/
      "${pkgs.rsync}/bin/rsync" --rsh="${pkgs.openssh}/bin/ssh" -avrP --delete amun:/var/lib/rancher/k3s/storage/ /backup/amun/var/lib/rancher/k3s/storage/
      # isis is a k3s agent
      "${pkgs.rsync}/bin/rsync" --rsh="${pkgs.openssh}/bin/ssh" -avrP --delete isis:/var/lib/rancher/k3s/storage/ /backup/isis/var/lib/rancher/k3s/storage/
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
  };
}
