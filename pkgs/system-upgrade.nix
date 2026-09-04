# The `system-upgrade` command: flake update + nixos-rebuild switch, run by
# hand or by the timer in modules/nix.nix. Lives here because both that timer
# and the package list in modules/packages.nix need it.
{ pkgs }:
pkgs.writeShellApplication {
  name = "system-upgrade";
  runtimeInputs = with pkgs; [
    coreutils
    git
    nix
    nixos-rebuild
  ];
  text = ''
    if [ "$(id -u)" -ne 0 ]; then
      exec sudo "$0" "$@"
    fi

    cd /etc/nixos

    # The guard that makes a daily timer cheap. `nix flake update` on a
    # machine tracking nixos-unstable moves the lock most days but not every
    # day, and a rebuild that finds nothing to do still costs a full
    # evaluation, a store scan and a generation. Comparing the lock before
    # and after turns "rebuild daily" into "rebuild when something changed".
    BEFORE=$(sha256sum flake.lock 2>/dev/null || echo "")
    nix flake update --flake /etc/nixos
    AFTER=$(sha256sum flake.lock 2>/dev/null || echo "")

    if [ "$BEFORE" = "$AFTER" ]; then
      echo "Flake lock unchanged, skipping rebuild" >&2
      exit 0
    fi

    nixos-rebuild switch --flake /etc/nixos
    echo "Upgrade applied. A reboot is not taken automatically; run one when it suits you." >&2
  '';
}
