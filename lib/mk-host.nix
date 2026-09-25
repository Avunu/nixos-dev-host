# lib.mkHost — the one call a dev host's flake makes.
#
# Wraps nixos-install-helper's mkProject around the devHost module, so a host
# gets every (re)deployment path from a single place — `nix run` (the wizard),
# `nix run .#deploy -- root@<ip>` (nixos-anywhere), `.#installerIso`
# (unattended, offline) and, for the generic template, `.#guidedIso` — plus a
# devShell that makes its agenix identity available to all of them.
#
# The identity. A host repo keeps its agenix key as secrets/key.age, encrypted
# to the operators (never to the host). Entering the devShell (direnv
# `use flake`) runs agenix-shell, which decrypts it into $agenix__key; every
# install path then carries it to /etc/agenix/key, where modules/secrets.nix
# has agenix look for it. The SSH host key never enters into it, so a redeploy
# — new disk, new host key — decrypts the same secrets without a re-key.
#
# Two ways a host keeps itself current afterwards:
#
#   deployedConfiguration = "github:Owner/repo#host";   (remote)
#     The host's configuration is this repository. It rebuilds straight from
#     GitHub (devHost.upgradeFlake), the repository's flake.lock decides every
#     version, and nothing lives in /etc/nixos. For a specific machine.
#
#   upstream = "github:Owner/repo";                      (local)
#     /etc/nixos gets a small synthesized flake that imports this module and
#     reads the per-host devHost-settings.json the installer writes. For the
#     generic template, where identity is chosen at install time.
{ inputs, devHost }:
{
  # The host flake's own `self` — shipped to the ISOs, and its revision is what
  # the host reports as its configuration revision.
  self,
  nixpkgs ? inputs.nixpkgs,
  system ? "x86_64-linux",
  # Host modules, layered over devHost.
  modules ? [ ],
  deployedConfiguration ? null,
  upstream ? null,
  # The host's agenix identity, age-encrypted to the operators
  # (./secrets/key.age). Setting it makes the key a required install asset and
  # has the devShell decrypt it.
  agenixKeyFile ? null,
  # Further agenix-shell secrets for the devShell: { name.file = ./x.age; }.
  shellSecrets ? { },
  # Identities agenix-shell tries, in order; unreadable ones are skipped. Shell
  # words, expanded when the devShell starts.
  identityPaths ? [
    "\${AGENIX_IDENTITY:-}"
    "$HOME/.ssh/id_ed25519"
    "$HOME/.ssh/id_rsa"
  ],
  # Anything else for mkProject (guidedPrompts, isoModules, dropZfs, …); wins
  # over what is derived here.
  installer ? { },
}:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  remote = deployedConfiguration != null;
  agenixKeyPath = import ./agenix-key-path.nix;

  hostModule = {
    imports = [ devHost ] ++ modules;
    # What `system-upgrade` compares against the repository's HEAD (remote), and
    # what `nixos-version --configuration-revision` reports. A dirty tree has no
    # revision to match, so its next upgrade always rebuilds.
    system.configurationRevision = self.rev or self.dirtyRev or null;
    devHost.upgradeFlake = lib.mkIf remote deployedConfiguration;
  };

  projectArgs = {
    inherit nixpkgs system self;
    installModules = [ hostModule ];
    diskName = "main";
    assets = [
      {
        name = "agenix-key";
        target = agenixKeyPath;
        mode = "0400";
        required = agenixKeyFile != null;
        # agenix-shell names the variable after the secret: agenix-key → agenix__key.
        source = {
          env = "agenix__key";
          prompt = "paste";
        };
      }
    ];
  }
  // (
    if remote then
      {
        flakeStyle = "remote";
        inherit deployedConfiguration;
        # The installed system already IS the deployed configuration, so there is
        # no first-boot switch to make; and install-helper's remote lifecycle
        # would turn on system.autoUpgrade next to devHost's own timer.
        lifecycle = false;
        # Every devHost value lives in the host's Nix; nothing to ask.
        optionRoots = [ ];
        guided = false;
      }
    else
      {
        flakeStyle = "local";
        inherit upstream;
        optionRoots = [ "devHost" ];
        # Wiring, not identity: set by lib.mkHost or the host's Nix, never asked.
        schemaExclude = [
          "upgradeFlake"
          "githubTokenFile"
        ];
        hints."devHost.diskDevice" = "disk-device";
      }
  )
  // installer;

  ih = inputs.nixos-install-helper.lib.mkProject projectArgs;
  installSystem = ih.nixosConfigurations.install;

  agenixShell = inputs.agenix-shell.lib.installationScript system {
    secrets = {
      agenix-key.file = agenixKeyFile;
    }
    // shellSecrets;
    inherit identityPaths;
  };
in
assert lib.assertMsg (
  remote != (upstream != null)
) "lib.mkHost: set exactly one of deployedConfiguration (remote) or upstream (local).";
{
  nixosModules.default = hostModule;

  # `install` is what every installer lays down; the same system under the
  # host's name is what the host itself rebuilds, so the two cannot drift.
  nixosConfigurations =
    removeAttrs ih.nixosConfigurations (lib.optional (!(projectArgs.guided or true)) "installTemplate")
    // {
      ${installSystem.config.networking.hostName} = installSystem;
    };

  inherit (ih) packages apps checks;

  devShells.${system}.default = pkgs.mkShell {
    packages = [
      inputs.agenix.packages.${system}.default
      pkgs.just
      pkgs.nixfmt
    ];
    shellHook = lib.optionalString (agenixKeyFile != null) ''
      source ${lib.getExe agenixShell}
      if [ -n "''${agenix__key:-}" ]; then
        echo "agenix-shell: host identity exported as \$agenix__key — installs will carry it to ${agenixKeyPath}"
      else
        echo "agenix-shell: could not decrypt the host identity (no matching key in: ${toString identityPaths})" >&2
        echo "              installs will stop and ask for it" >&2
      fi
    '';
  };
}
