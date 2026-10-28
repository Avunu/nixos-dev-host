# The devHost module. Consumers still import exactly one thing —
# self.nixosModules.devHost — and this is it; the sections below are ordinary
# NixOS modules that merge as usual, so nothing about the interface changed
# when the flake was split up.
#
# Where things live:
#
#   options.nix     every devHost.* option, features.* included
#   boot.nix        kernel, kernel command line, sysctls, bootloader
#   storage.nix     the disko partition table, the btrfs profile, swap and
#                   zswap, and the block-layer tuning
#   nix.nix         Determinate Nix (its module is imported below), nix
#                   settings, the build resource guards, the upgrade script
#                   and its timer
#   flake-auto-update.nix
#                   the timer that re-locks a repository's flake and pushes
#                   the lock (devHost.flakeAutoUpdate, off by default)
#   networking.nix  systemd-networkd, avahi, ssh, the firewall
#   services.nix    the remaining daemons, each with a reason to be here
#   containers.nix  podman and container storage
#   packages.nix    what is installed, and the shell environment
#   system.nix      console (btop on tty1), locale, users, documentation
#   secrets.nix     the agenix identity (/etc/agenix/key) and GitHub access
#                   built on it
#
# github-repo-runners.nix lives here too but is not imported below: it is its
# own opt-in module (nixosModules.githubRepoRunners), for the hosts that run
# self-hosted GitHub Actions runners.
#
# ../pkgs holds the derivations more than one module needs: the upgrade
# script (packages.nix installs it, nix.nix times it).
#
# The machine this targets is a headless bare-metal box on a LAN: no screen,
# no battery, nobody sitting in front of it. It is also the machine that does
# the building, which is why the resource guards in nix.nix protect sshd and
# the containers rather than throttling nix — the opposite of what a laptop
# would want.
{ inputs }:
{
  imports = [
    inputs.determinate.nixosModules.default
    inputs.disko.nixosModules.disko

    ./options.nix

    ./boot.nix
    ./containers.nix
    ./flake-auto-update.nix
    ./networking.nix
    ./nix.nix
    ./packages.nix
    ./services.nix
    ./storage.nix
    ./system.nix
    (import ./secrets.nix { inherit (inputs) agenix nixos-install-helper; })
  ];

  # nix.nix needs the locked nixpkgs revision to pin the flake registry
  # without dragging the source tree into the closure. Passing inputs through
  # _module.args rather than threading it into every import keeps the module
  # files ordinary NixOS modules.
  _module.args.inputs = inputs;
}
