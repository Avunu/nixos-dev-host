{
  description = "NixOS Development Host";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.darwin.follows = "";
      inputs.home-manager.follows = "";
    };
    # Decrypts a host repo's secrets/key.age into $agenix__key when its devShell
    # starts, which is where every install path picks the key up (lib/mk-host.nix).
    agenix-shell = {
      url = "github:aciceri/agenix-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-install-helper = {
      url = "github:Avunu/nixos-install-helper";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # This repository's own installer: a generic dev host whose identity is
      # chosen at install time, living on as a small /etc/nixos flake that
      # imports devHost from here. A specific machine with its own repository
      # calls lib.mkHost with deployedConfiguration instead (see
      # lib/mk-host.nix).
      template = self.lib.mkHost {
        inherit self;
        upstream = "github:Avunu/nixos-dev-host";
        installer.guidedPrompts = [
          "hostName"
          "username"
        ];
      };
    in
    {
      # The dev host itself. One module, assembled from ./modules — see
      # modules/default.nix for the map of which file holds what.
      nixosModules.devHost = import ./modules { inherit inputs; };
      nixosModules.default = self.nixosModules.devHost;

      lib = {
        mkHost = import ./lib/mk-host.nix {
          inherit inputs;
          inherit (self.nixosModules) devHost;
        };
        agenixKeyPath = import ./lib/agenix-key-path.nix;
      };

      # The template's installers: `nix run` (the wizard), .#deploy,
      # .#installerIso, .#guidedIso — and a devShell.
      inherit (template) packages apps devShells;

      # A configuration that exists only to be evaluated. Real hosts live in
      # their own flakes and set devHost.* there; this one takes the bare
      # minimum and is what the eval check below evaluates.
      nixosConfigurations = template.nixosConfigurations // {
        example = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.devHost
            {
              devHost = {
                hostName = "example";
                username = "example";
              };
            }
          ];
        };
      };

      # `nix flake check` used to verify nothing at all: the only output was a
      # module, and a module is not a derivation. Nothing caught an option
      # rename or a removed setting until a real host tried to build — which
      # matters more here than most places, because this machine tracks
      # nixos-unstable on a timer and applies what it finds.
      #
      # This forces a full evaluation of the configuration — every option
      # merge, every assertion, every deprecation warning — and then throws
      # the result away. unsafeDiscardStringContext is what keeps it an
      # evaluation rather than a build: without it the .drv would be a
      # build-time dependency and `nix flake check` would compile the entire
      # system to tell you the eval worked.
      #
      # The offline-install-* checks beside it are nixos-install-helper's: they
      # build an ISO and install from it in a network-less VM, so they take a
      # while. Build `.#checks.x86_64-linux.eval` alone for the quick answer.
      checks.${system} = template.checks.${system} // {
        eval = pkgs.runCommand "devhost-eval-check" { } ''
          echo "${builtins.unsafeDiscardStringContext self.nixosConfigurations.example.config.system.build.toplevel.drvPath}" > "$out"
        '';
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
