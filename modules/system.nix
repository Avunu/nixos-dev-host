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

  # ── tty1 ────────────────────────────────────────────────────
  # btop instead of a login prompt, as a service that owns the console — the
  # arrangement nixos-install-helper's installer uses for the same tty, and
  # for the same reasons: it is findable (`systemctl status btop-console`),
  # it does not depend on a login shell sourcing anything, and `tty-force`
  # gives it a real controlling terminal.
  #
  # Two things have to be true for the service to keep tty1. getty.target
  # wants autovt@tty1, so nothing else may start a getty there: the unit is
  # disabled, which is what nixpkgs' greetd module does for the same reason
  # (a switch would otherwise start it and take the console back). And the
  # service conflicts with getty@tty1, so starting one by hand swaps tty1 to
  # a login instead of two programs sharing a terminal. tty2…6 are untouched:
  # logind spawns autovt@ttyN for them as usual.
  systemd.services = mkIf cfg.features.consoleMonitor {
    "autovt@tty1".enable = false;

    btop-console = {
      description = "btop on the tty1 console";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-user-sessions.service" ];
      conflicts = [ "getty@tty1.service" ];
      # A bare service inherits no TERM or locale, which agetty and login would
      # have set. HOME is where btop keeps btop.conf: StateDirectory below, so
      # a setting changed at the console survives a reboot.
      environment = {
        TERM = "linux";
        LANG = config.i18n.defaultLocale;
        HOME = "/var/lib/btop-console";
      };
      serviceConfig = {
        # --tty because this is always a kernel virtual console: 16 colours and
        # no braille, so the graphs need the ANSI-safe symbols.
        ExecStart = "${getExe pkgs.btop} --tty";
        # Unprivileged: see features.consoleMonitor. systemd opens the tty
        # before it drops privileges, so this costs nothing at startup. btop
        # still lists every process; it just cannot read their I/O counters.
        DynamicUser = mkDefault true;
        StateDirectory = "btop-console";
        # Quitting btop would otherwise leave a dead screen with no way back
        # short of switching VTs.
        Restart = "always";
        RestartSec = 1;
        StandardInput = "tty-force";
        StandardOutput = "tty";
        # The journal, not the screen: btop's errors would be painted over
        # its own display.
        StandardError = "journal";
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        TTYVTDisallocate = true;
        # Wait for the rest of boot, so its output is not drawn under btop.
        Type = "idle";
      };
    };
  };

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
