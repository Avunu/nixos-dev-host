{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-dev-host = {
      url = "github:Avunu/nixos-dev-host";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-dev-host,
    }:
    let
      # Configuration variables
      hostName = "nix-dev-host";
      username = "dylan";
      system = "x86_64-linux";
    in
    {
      nixosConfigurations = {
        "${hostName}" = nixpkgs.lib.nixosSystem {
          system = system;
          modules = [
            # No nix.nixPath pin here. It used to read
            #   nix.nixPath = [ "nixpkgs=${self.inputs.nixpkgs}" ];
            # which puts the whole nixpkgs source tree — 210 MB — into the
            # system closure so that <nixpkgs> resolves offline. The module
            # drops the equivalent flake-provided pins for the same reason and
            # replaces them with a github registry entry at the same revision,
            # so `nix shell nixpkgs#foo` still resolves to exactly what this
            # system was built from. Restoring this line would put the 210 MB
            # straight back. See modules/nix.nix.
            nixos-dev-host.nixosModules.devHost
            {
              devHost = {
                hostName = hostName;
                diskDevice = "/dev/sda";
                timeZone = "America/New_York";
                locale = "en_US.UTF-8";
                username = username;
                initialPassword = "password";
                sshKeys = [
                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILtMd4jTM9A36iVI2R6zw8cApkd7HQExr0ayfHcwaOp/"
                  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOv4SpIhHJqtRaYBRQOin4PTDUxRwo7ozoQHTUFjMGLW"
                ];
                stateVersion = "25.11";
                extraPackages = with nixpkgs.legacyPackages.${system}; [
                  # Add any additional packages here
                ];
              };
            }
          ];
        };
      };
    };
}
