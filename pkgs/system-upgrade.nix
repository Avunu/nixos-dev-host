# The `system-upgrade` command: rebuild from devHost.upgradeFlake, run by hand
# or by the timer in modules/nix.nix. Lives here because both that timer and
# the package list in modules/packages.nix need it.
#
# Two shapes, fixed at build time by the flake reference:
#   /etc/nixos (a path)  update the local flake's lock, switch if it moved
#   github:Owner/repo#x  switch to the repository's HEAD, if it moved
{
  pkgs,
  # The system's own nix (config.nix.package), so the lock is updated and the
  # rebuild driven by the same Nix the daemon runs — Determinate Nix, not
  # whatever pkgs.nix happens to be.
  nix ? pkgs.nix,
  # config.system.build.nixos-rebuild, for the same reason and one more:
  # nixos-rebuild wraps the Nix it was built against onto its own PATH, ahead
  # of anything in runtimeInputs. pkgs.nixos-rebuild carries nixpkgs' Nix, so
  # the evaluation and build it drives would run on that — which does not know
  # Determinate's eval-cores or lazy-trees ("unknown setting" on every run) and
  # gets none of their speed. NixOS builds the system's own copy with
  # nix.package; that is the one to use.
  nixos-rebuild ? pkgs.nixos-rebuild,
  flake ? "/etc/nixos",
}:
let
  inherit (pkgs) lib;
  local = lib.hasPrefix "/" flake;
  ref = lib.escapeShellArg flake;
in
pkgs.writeShellApplication {
  name = "system-upgrade";
  runtimeInputs = [
    nix
    nixos-rebuild
  ]
  ++ (with pkgs; [
    coreutils
    git
    jq
  ]);
  text = ''
    if [ "$(id -u)" -ne 0 ]; then
      exec sudo "$0" "$@"
    fi
  ''
  + (
    if local then
      ''
        cd ${ref}

        # The guard that makes a daily timer cheap. `nix flake update` on a
        # machine tracking nixos-unstable moves the lock most days but not every
        # day, and a rebuild that finds nothing to do still costs a full
        # evaluation, a store scan and a generation. Comparing the lock before
        # and after turns "rebuild daily" into "rebuild when something changed".
        BEFORE=$(sha256sum flake.lock 2>/dev/null || echo "")
        nix flake update --flake ${ref}
        AFTER=$(sha256sum flake.lock 2>/dev/null || echo "")

        if [ "$BEFORE" = "$AFTER" ]; then
          echo "Flake lock unchanged, skipping rebuild" >&2
          exit 0
        fi

        nixos-rebuild switch --flake ${ref}
      ''
    else
      ''
        # The same guard, for a flake that lives in a repository. Its lock is
        # authoritative — this machine never updates one of its own — so
        # "something changed" means the repository moved: compare its current
        # revision with the one this system was built from. An unknown current
        # revision (a dirty or hand-built deploy) always rebuilds.
        REF=${ref}
        LATEST=$(nix flake metadata --refresh --json "''${REF%%#*}" | jq -r '.revision // .locked.rev // empty')
        CURRENT=$(/run/current-system/sw/bin/nixos-version --configuration-revision 2>/dev/null || true)

        if [ -n "$LATEST" ] && [ "$LATEST" = "$CURRENT" ]; then
          echo "Already at $LATEST, skipping rebuild" >&2
          exit 0
        fi

        nixos-rebuild switch --refresh --flake "$REF"
      ''
  )
  + ''
    echo "Upgrade applied. A reboot is not taken automatically; run one when it suits you." >&2
  '';
}
