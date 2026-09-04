{
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.devHost;
in
{
  virtualisation = {
    # The btrfs driver, matching the root filesystem. It is the reason image
    # layers are cheap here: each layer is a subvolume snapshot of the one
    # below rather than an overlay of copied files, so pulling a tag that
    # shares most of its history with one already present costs almost
    # nothing. The alternative (overlay on top of btrfs) would pay for
    # copy-on-write twice.
    containers.storage.settings.storage = mkIf cfg.features.containers {
      driver = "btrfs";
      graphroot = "/var/lib/containers/storage";
      runroot = "/run/containers/storage";
    };

    oci-containers.backend = "podman";

    podman = {
      enable = mkDefault cfg.features.containers;
      autoPrune.enable = mkDefault true;
      # The CLI alias and the socket, so tools that only speak Docker —
      # docker-compose, testcontainers, IDE integrations — work unmodified.
      dockerCompat = true;
      dockerSocket.enable = true;
      defaultNetwork.settings.dns_enabled = true;
    };
  };

  # No oci-containers.containers are declared. This module provides the
  # runtime; what runs on it is the business of whoever is using the machine.
}
