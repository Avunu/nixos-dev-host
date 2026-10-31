{
  description = "NixOS Development Host";

  # Determinate Nix is built from nix-src, which cache.nixos.org does not
  # carry. Without this, the first `nix run` / `nix build` of this flake from a
  # machine that is not yet on Determinate compiles Nix itself. Once a machine
  # runs Determinate Nix, determinate-nixd configures its own caches and this
  # is no longer needed there. Same key as the --option flags in the readme.
  nixConfig = {
    extra-substituters = [ "https://install.determinate.systems" ];
    extra-trusted-public-keys = [
      "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    determinate = {
      url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      # imports devHost from here. Started in an empty directory, its wizard
      # instead bootstraps a repository for one machine, whose flake calls
      # lib.mkHost with `repo`.
      template = self.lib.mkHost {
        inherit self;
        upstream = "github:Avunu/nixos-dev-host";
        installer = installerDefaults // {
          guidedPrompts = [
            "hostName"
            "username"
          ];
        };
      };

      installerDefaults = {
        hints."devHost.diskDevice" = "disk-device";
        # Wiring, not identity: set by lib.mkHost or the host's Nix, never asked.
        schemaExclude = [
          "upgradeFlake"
          "githubTokenFile"
          "githubApp"
        ];
      };
    in
    {
      # The dev host itself. One module, assembled from ./modules — see
      # modules/default.nix for the map of which file holds what.
      nixosModules.devHost = import ./modules { inherit inputs; };
      nixosModules.default = self.nixosModules.devHost;

      # Self-hosted GitHub Actions runners, per repository or for the whole
      # organisation (through a GitHub App). Opt-in, and not
      # part of devHost: a host that wants them imports it beside devHost.
      nixosModules.githubRepoRunners = ./modules/github-repo-runners.nix;

      # nixos-install-helper's lib.mkHost with this project filled in: what this
      # flake's own installer is built from, and the one call a host repo's
      # flake makes.
      lib.mkHost =
        args:
        inputs.nixos-install-helper.lib.mkHost (
          {
            inherit nixpkgs;
            module = self.nixosModules.devHost;
            optionRoot = "devHost";
            installer = installerDefaults;
            devShellPackages = [
              pkgs.just
              pkgs.nixfmt
            ];
            # Determinate Nix is not in cache.nixos.org; without this, building
            # a host repo from a machine not yet on Determinate compiles Nix.
            nixConfig = {
              extra-substituters = [ "https://install.determinate.systems" ];
              extra-trusted-public-keys = [
                "cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM="
              ];
            };
          }
          // args
        );

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
            self.nixosModules.githubRepoRunners
            {
              devHost = {
                hostName = "example";
                username = "example";
                # Evaluates the disko table with the second disk in it too.
                nixDiskDevice = "/dev/disk/by-id/example-nix-disk";
              };

              # Evaluates the runners module, user and all: repository
              # runners on a PAT, organisation runners through an App.
              services.githubRepoRunners = {
                enable = true;
                owner = "example";
                tokenFile = "/run/example-runner-token";
                repos.example = 2;
                githubApp = {
                  appId = 1;
                  privateKeyFile = "/run/example-app-key";
                };
                orgRunners = 2;
                runners.labelled.extraLabels = [ "labelled" ];
              };
            }
          ];
        };

        # The same, with every GitHub App option on: the reader's token in
        # place of a stored one, and flakeAutoUpdate pushing with the writer.
        example-github-app = self.nixosConfigurations.example.extendModules {
          modules = [
            {
              devHost = {
                githubApp = {
                  reader = {
                    appId = 1;
                    privateKeyFile = "/run/example-reader-key";
                  };
                  writer = {
                    appId = 2;
                    privateKeyFile = "/run/example-writer-key";
                  };
                };
                flakeAutoUpdate.repositories.example = {
                  url = "https://github.com/example/example.git";
                  pushBranch = "flake-auto-update";
                };
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
      #
      # github-app runs the token services against a fake GitHub API in a VM
      # (tests/github-app.nix).
      checks.${system} = template.checks.${system} // {
        eval = pkgs.runCommand "devhost-eval-check" { } ''
          echo "${builtins.unsafeDiscardStringContext self.nixosConfigurations.example.config.system.build.toplevel.drvPath}" > "$out"
          echo "${builtins.unsafeDiscardStringContext self.nixosConfigurations.example-github-app.config.system.build.toplevel.drvPath}" >> "$out"
        '';
        github-app = pkgs.testers.runNixOSTest (import ./tests/github-app.nix { inherit inputs; });
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
