{
  description = "NixOS Development Host";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # The dev host itself. One module, assembled from ./modules — see
      # modules/default.nix for the map of which file holds what.
      nixosModules.devHost = import ./modules { inherit inputs; };

      # A configuration that exists only to be evaluated. Real hosts live in
      # their own flakes (see local/flake.nix) and set devHost.* there; this
      # one takes the bare minimum the module requires and is what the check
      # below evaluates.
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
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
      checks.${system}.eval = pkgs.runCommand "devhost-eval-check" { } ''
        echo "${builtins.unsafeDiscardStringContext self.nixosConfigurations.example.config.system.build.toplevel.drvPath}" > "$out"
      '';

      formatter.${system} = pkgs.nixfmt;
    };
}
