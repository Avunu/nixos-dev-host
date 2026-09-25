{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.devHost;
in
{
  # ── Console ─────────────────────────────────────────────────
  # No console.packages. It used to carry terminus_font, which never loaded:
  # console.font is null here, so NixOS writes no FONT= line into
  # /etc/vconsole.conf and systemd-vconsole-setup leaves the kernel's
  # built-in font alone. console.packages only extends the search path
  # setfont would have looked in — with nothing selecting a font from it, the
  # package was installed on every machine and read by nothing. On a headless
  # box there is not even a screen for it to have been read on.
  console.keyMap = mkDefault "us";

  # ── Documentation ───────────────────────────────────────────
  # Man pages and development headers are ON, which reverses what this
  # configuration used to do. All four switches were false, copied from a
  # desktop module whose target was a 16 GB disk and whose README says so
  # outright.
  #
  # That trade does not survive the move to a development host. The whole
  # point of the machine is that people SSH into it to write code, and `man
  # 3 <anything>` not existing is a daily cost paid to save disk on a box
  # that has plenty.
  #
  # doc and nixos stay off: the first is packages' HTML and info manuals, the
  # second builds the NixOS manual itself on every rebuild. `man
  # configuration.nix` goes with the latter, which is the one real loss —
  # worth it against rebuilding the manual daily on a machine that upgrades
  # itself.
  documentation = {
    enable = mkDefault true;
    dev.enable = mkDefault true;
    man.enable = mkDefault true;
    doc.enable = mkDefault false;
    nixos.enable = mkDefault false;
  };

  # ── System ──────────────────────────────────────────────────
  system = {
    stateVersion = cfg.stateVersion;
    # Off deliberately. modules/nix.nix carries the upgrade mechanism — one
    # timer, lock-guarded, with resource limits and no unattended reboot —
    # and this option would be a second one racing it.
    autoUpgrade.enable = mkDefault false;
  };

  # ── Time & locale ───────────────────────────────────────────
  time.timeZone = cfg.timeZone;
  i18n.defaultLocale = cfg.locale;

  # ── Users ───────────────────────────────────────────────────
  users = {
    defaultUserShell = pkgs.bashInteractive;
    users = {
      ${cfg.username} = {
        extraGroups = [ "wheel" ];
        initialPassword = cfg.initialPassword;
        isNormalUser = true;
        openssh.authorizedKeys.keys = cfg.sshKeys;
      };
      root = {
        openssh.authorizedKeys.keys = cfg.sshKeys;
      };
    };
  };
}
