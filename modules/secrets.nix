# The host's secrets identity, and the GitHub access that hangs off it.
#
# agenix decrypts with a pre-provisioned identity at /etc/agenix/key, not with
# the SSH host key. Every install generates a fresh SSH host key, so secrets
# encrypted to it have to be re-keyed on every redeploy. A key that is carried
# *into* the install instead — a host repo keeps it as secrets/key.age and
# nixos-install-helper's lib.mkHost has every install path write it here —
# survives any number of them.
#
# Both halves live in nixos-install-helper's module, shared with every project
# built on lib.mkHost: `installHelper.agenixKey` points agenix at the key and
# keeps it root-only; `installHelper.githubTokenFile` hands a token to nix
# (access-tokens) and to git (a credential helper, which flake-auto-update.nix
# and the runners read too). Imported here, not only by lib.mkHost, so a local
# /etc/nixos install gets the same.
#
# A function of the flake inputs rather than a module that reads `inputs`:
# the /etc/nixos flake nixos-install-helper seeds passes its own `inputs` as a
# specialArg, which shadows this flake's `_module.args.inputs`, and that one has
# neither agenix nor nixos-install-helper in it.
{ agenix, nixos-install-helper }:
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    agenix.nixosModules.default
    nixos-install-helper.nixosModules.installHelper
    # The name every devHost module (and a host's own Nix) uses for it.
    (lib.mkAliasOptionModule [ "devHost" "githubTokenFile" ] [ "installHelper" "githubTokenFile" ])
  ];

  config = {
    installHelper = {
      agenixKey = nixos-install-helper.lib.agenixKeyPath;
      # The lifecycle stays off unless mkProject turns it on (its install
      # systems); the /etc/nixos flake of a local install does not.
      enable = lib.mkDefault false;
      # A host repo is upgraded by devHost's own timer, pointed at the repo.
      repo.autoUpgrade = false;
    };

    devHost.upgradeFlake = lib.mkIf (
      config.installHelper.enable && config.installHelper.flakeStyle == "repo"
    ) config.installHelper.repo.flakeRef;

    # `agenix -d secrets/foo.age -i /etc/agenix/key` on the box itself.
    environment.systemPackages = [ agenix.packages.${pkgs.stdenv.hostPlatform.system}.default ];
  };
}
