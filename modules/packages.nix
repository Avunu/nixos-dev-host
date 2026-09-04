{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.devHost;

  systemUpgradeScript = import ../pkgs/system-upgrade.nix { inherit pkgs; };
in
{
  environment.systemPackages =
    with pkgs;
    flatten [
      (python3.withPackages (
        python-pkgs: with python-pkgs; [
          black
          flake8
          isort
          pandas
          requests
        ]
      ))
      [
        bun
        ccache
        cmake
        corepack_22
        curl
        docker-compose
        gh
        # Full git, not gitMinimal. The sibling desktop module trims it on the
        # grounds that git there is plumbing for `nixos-rebuild --flake` and
        # nothing else, so the Perl scripts, Tcl/Tk and 16 MB of HTML
        # documentation are dead weight. That reasoning inverts here: this is
        # the machine people write code on.
        git
        gnumake
        nano
        nixfmt
        nixos-container
        # Kept alongside nixfmt, which is what `nix fmt` runs here. Retained
        # because it was already installed and something may still call it,
        # not because two formatters is a good idea — nixpkgs-fmt is
        # superseded and this is the obvious next thing to drop.
        nixpkgs-fmt
        nodejs_24
        podman-compose
        podman-tui
        service-wrapper
        tzdata
        wget
        # Also on a daily timer — see modules/nix.nix.
        systemUpgradeScript
      ]
      cfg.extraPackages
    ];

  # environment.defaultPackages is deliberately left alone. It is perl, rsync
  # and strace here, and the sibling module's instinct to empty it does not
  # transfer: rsync and strace are things you reach for on a development host,
  # and the saving is small against the annoyance of finding them missing at
  # the moment you need them.

  programs = {
    direnv = {
      enable = true;
      # angrr keeps direnv's GC roots from accumulating without letting
      # nix.gc tear out an environment that is still in use. It pairs with
      # keep-outputs / keep-derivations in modules/nix.nix.
      #
      # This option lives on programs.direnv but is declared by the angrr
      # module (nixos/modules/services/misc/angrr.nix), not by the direnv one.
      angrr = {
        autoUse = true;
        enable = true;
      };
      nix-direnv.enable = true;
      enableBashIntegration = true;
    };

    git = {
      enable = true;
      config.safe.directory = [
        "/etc/nixos"
        "/home/${cfg.username}/"
      ];
    };

    # Lets unpatched dynamically-linked binaries run — the language toolchains
    # and vendored dev tools that assume a filesystem hierarchy NixOS does not
    # have.
    nix-ld.enable = mkDefault true;
  };
}
