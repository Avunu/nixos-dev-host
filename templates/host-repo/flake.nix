# @HOST@ — a NixOS dev host managed from this repository.
#
# The machine rebuilds straight from GitHub (@OWNER@/@REPO@): push to the
# default branch and its next upgrade switches to it. flake.lock decides every
# version, so update it here (`nix flake update`), not on the machine.
#
#   nix run        install it: network (nixos-anywhere) or an offline ISO
#   nix develop    agenix for editing secrets/; also what direnv loads
{
  # Determinate Nix is not in cache.nixos.org; name its cache so building this
  # flake from a machine that is not on Determinate yet does not compile Nix.
  nixConfig = {
    extra-substituters = [ "https://install.determinate.systems" ];
    extra-trusted-public-keys = [
      "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
    ];
  };

  inputs = {
    nixos-dev-host.url = "@UPSTREAM@";
    nixpkgs.follows = "nixos-dev-host/nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-dev-host,
      ...
    }:
    let
      # The same file host.nix reads; the flake attribute the machine tracks is
      # named after its host name, so renaming the host there renames it here.
      settings = builtins.fromJSON (builtins.readFile ./devHost-settings.json);
      host = nixos-dev-host.lib.mkHost {
        inherit self nixpkgs;
        deployedConfiguration = "github:@OWNER@/@REPO@#${settings.hostName or "nix-dev-host"}";
        # This host's agenix identity, age-encrypted to the operators (secrets.nix).
        agenixKeyFile = ./secrets/key.age;
        modules = [ ./host.nix ];
      };
    in
    {
      inherit (host)
        nixosModules
        nixosConfigurations
        packages
        apps
        devShells
        ;
    };
}
