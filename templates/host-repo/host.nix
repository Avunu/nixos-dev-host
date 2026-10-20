# This machine's configuration beyond what the flake wires up.
#
# devHost-settings.json holds the devHost.* values the installer asked about
# (host name, user, disk, features, …). Everything else — extra packages, a
# service, a tweak — goes here as ordinary NixOS configuration.
{ config, lib, ... }:
let
  settings = builtins.fromJSON (builtins.readFile ./devHost-settings.json);
  # The read-only GitHub token the machine fetches this (private) repository
  # with. Conditional so the repository still evaluates without it, which is
  # the case for a public one.
  haveToken = builtins.pathExists ./secrets/github-token.age;
in
{
  config = lib.mkMerge [
    { devHost = builtins.mapAttrs (_: lib.mkDefault) settings; }

    (lib.mkIf haveToken {
      age.secrets.github-token.file = ./secrets/github-token.age;
      devHost.githubTokenFile = config.age.secrets.github-token.path;
    })

    # Your own configuration goes in another element of this list, e.g.
    #   { environment.systemPackages = [ pkgs.htop ]; }
    # (add `pkgs` to the arguments above).
  ];
}
