# grafana-agent.nix — declarative config for the grafana/agent docker
# container defined in base-configuration.nix.
#
# Manages /etc/grafana-agent.yaml. The Mimir remote-write password is
# *not* in this file — it lives at /etc/grafana-agent-password
# (chmod 600 root:root), placed out-of-band on each host. This keeps
# the secret out of the nixos-config repo and the nix store, and lines
# up with a future agenix migration.
#
# The container is restarted whenever this config changes
# (restartTriggers on docker-grafana.service).

{ config, pkgs, lib, ... }:

let
  agentConfig = {
    server = {
      log_level = "warn";
    };

    metrics = {
      global = {
        scrape_interval = "1m";
        remote_write = [{
          url = "https://prometheus-prod-01-eu-west-0.grafana.net/api/prom/push";
          basic_auth = {
            username = "324618";
            password_file = "/etc/grafana-agent-password";
          };
        }];
      };
      wal_directory = "/var/lib/grafana-agent";
    };

    integrations = {
      agent.enabled = true;
      node_exporter = {
        enabled = true;
        include_exporter_metrics = false;
        rootfs_path = "/host/root";
        sysfs_path = "/host/sys";
        procfs_path = "/host/proc";
        udev_data_path = "/host/root/run/udev/data";

        # Exclude the k8s/docker pseudo-mounts that explode cardinality.
        # The kept set is real persistent storage: /, /boot, /home, /backup,
        # /export/home (NFS client on odin), and similar.
        filesystem_mount_points_exclude =
          "^/(dev|proc|sys|run|nix/store|var/lib/(docker|rancher|kubelet))($|/)";
        filesystem_fs_types_exclude =
          "^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|mqueue|nsfs|overlay|proc|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs|tmpfs)$";

        # Exclude virtual/ephemeral network interfaces. Two flags are
        # needed because node_exporter has separate collectors:
        # - netclass governs node_network_iface_* / info / carrier (we
        #   also drop these via metric_relabel below — belt+braces).
        # - netdev governs node_network_(receive|transmit)_(bytes|packets)_total
        #   etc. These are the ones we actually graph, but only for
        #   the *real* interfaces; veth pairs from k3s pods (28 of 32
        #   interfaces on amun) are pure noise — ~250 series saved.
        # docker0 and wg0 are kept (single persistent interfaces, real
        # traffic worth seeing).
        netclass_ignored_devices =
          "^(veth|cali|cni|flannel|kube-ipvs|nodelocaldns).*";
        netdev_device_exclude =
          "^(veth|cali|cni|flannel|kube-ipvs|nodelocaldns).*";

        disable_collectors = [
          "mdadm"
          "nfs"
        ];

        metric_relabel_configs = [
          # Cosmetic: existing rule, kept.
          {
            action = "drop";
            regex = "node_scrape_collector_.+";
            source_labels = [ "__name__" ];
          }
          # Filesystem metrics we never query: file-inode counts,
          # device-error, readonly flags. node_filesystem_size_bytes,
          # _free_bytes, _avail_bytes are kept.
          {
            action = "drop";
            regex = "node_filesystem_(device_error|files|files_free|readonly)";
            source_labels = [ "__name__" ];
          }
          # Network interface metadata we never query: 16 of the 20 entries
          # in our top-cardinality list. We keep transmit/receive byte and
          # packet totals via node_network_(receive|transmit)_(bytes|packets)_total.
          {
            action = "drop";
            regex = "node_network_(address_assign_type|carrier|carrier_changes_total|carrier_down_changes_total|carrier_up_changes_total|device_id|dormant|flags|iface_id|iface_link|iface_link_mode|info|mtu_bytes|name_assign_type|net_dev_group|protocol_type|transmit_queue_length|type)";
            source_labels = [ "__name__" ];
          }
        ];
      };
    };
  };

  yamlFormat = pkgs.formats.yaml { };
  agentYaml = yamlFormat.generate "grafana-agent.yaml" agentConfig;
in {
  environment.etc."grafana-agent.yaml" = {
    source = agentYaml;
    mode = "0644";
  };

  # Restart the docker-grafana service whenever the config changes.
  # base-configuration.nix defines the container itself; we only own
  # the bind-mounted YAML here.
  systemd.services."docker-grafana".restartTriggers = [ agentYaml ];
}
