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
      hostName = "nix-dev-host"; # Replace with desired hostname
      diskDevice = "/dev/sda"; # Replace with your disk device
      timeZone = "America/New_York"; # Replace with your timezone
      locale = "en_US.UTF-8"; # Replace with your locale
      username = "dylan"; # Replace with desired username
      initialPassword = "password"; # Replace with a secure password
      stateVersion = "25.11"; # NixOS state version
      sshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILtMd4jTM9A36iVI2R6zw8cApkd7HQExr0ayfHcwaOp/"; # Replace with your SSH public key
      system = "x86_64-linux";
      extraPackages = with nixpkgs.legacyPackages.x86_64-linux; [
        # Add any non-flatpak software you want on this particular machine
        # for example, insync:
        # insync
        # insync-emblem-icons
        # insync-nautilus
      ];
    in
    {
      nixosConfigurations = {
        "${hostName}" = nixpkgs.lib.nixosSystem {
          system = system;
          modules = [
            { nix.nixPath = [ "nixpkgs=${self.inputs.nixpkgs}" ]; }
            nixos-dev-host.nixosModules.devHost
            # ./hardware-configuration.nix
            (
              {
                config,
                lib,
                pkgs,
                ...
              }:
              {
                disko.devices.disk.main.device = diskDevice;

                networking.hostName = hostName;

                time.timeZone = timeZone;

                i18n.defaultLocale = locale;

                users.users = {
                  ${username} =
                    { pkgs, ... }:
                    {
                      extraGroups = [
                        "wheel"
                      ];
                      initialPassword = initialPassword;
                      isNormalUser = true;
                      openssh.authorizedKeys.keys = [ sshKey ];
                    };
                  root = {
                    openssh.authorizedKeys.keys = [ sshKey ];
                  };
                };

                environment.systemPackages = extraPackages;

                system.stateVersion = stateVersion;
              }
            )
          ];
        };
      };
    };
}
