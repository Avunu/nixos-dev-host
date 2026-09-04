{
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.devHost;
in
{
  services = {
    # ── Kept ──────────────────────────────────────────────────
    btrfs.autoScrub = {
      enable = mkDefault true;
      fileSystems = [ "/" ];
      interval = mkDefault "weekly";
    };

    bpftune.enable = mkDefault cfg.features.networkTuning;

    fwupd.enable = mkDefault cfg.features.firmwareUpdates;

    # ── Bounded ───────────────────────────────────────────────
    # journald's default SystemMaxUse is 10% of the filesystem, up to 4 GB,
    # and this box logs the stdout of every container it runs. Unbounded was
    # not a decision anyone made; it was the default arriving because nothing
    # said otherwise.
    #
    # 512 MB rather than the 64 MB a small-disk laptop would take: on a
    # machine people SSH into to work out why something broke, journal
    # history is the diagnosis. 64 MB files keep rotation granular enough
    # that the cap evicts in useful increments instead of dropping one huge
    # file at a time.
    #
    # Two mechanics worth knowing before editing this. extraConfig is
    # types.lines, which CONCATENATES definitions rather than letting one
    # win — a second block elsewhere would leave both key sets in the file
    # and make the result depend on which systemd read last. And Storage= and
    # the rate limits have their own NixOS options because NixOS writes those
    # into journald.conf *before* appending extraConfig, so setting them here
    # would leave each key in the file twice.
    journald.extraConfig = mkDefault ''
      SystemMaxUse=512M
      SystemMaxFileSize=64M
    '';

    # ── Off ───────────────────────────────────────────────────
    # An hourly timer, on a machine with very little else periodic about it,
    # rotating two files it will never rotate.
    #
    # NixOS enables logrotate by default and ships it a generated config, and
    # on this system that config has exactly two stanzas in it:
    # /var/log/btmp and /var/log/wtmp, both "monthly", both "minsize 1M".
    # Nothing else here writes to /var/log — journald keeps its own directory
    # and does its own rotation (above), there is no syslog and no cron. So
    # the timer fires every hour, forever, to stat two login records that
    # take years to reach a megabyte, and then does nothing. The same unit
    # also costs a checkconf at every boot and at every nixos-rebuild switch.
    #
    # A host that adds something which genuinely writes to /var/log should
    # set services.logrotate.enable = true and get the timer back with it.
    logrotate.enable = mkDefault false;

    # ── Desktop and laptop residue ────────────────────────────
    # All four came across from a configuration written for a machine with a
    # screen, a battery and someone sitting in front of it. This one is a
    # headless box in a cupboard on a LAN.
    #
    # libinput reads input devices there are none of. upower reports on a
    # battery that does not exist, to consumers that are not installed.
    # power-profiles-daemon arbitrates a platform profile nothing asks it to
    # change, and takes the same D-Bus name tuned and TLP want if either is
    # ever added. udisks2 exists to automount removable media for a desktop
    # session.
    #
    # None of them is large. The point is the process and the D-Bus name, not
    # the memory: each one is a daemon standing by for an event that cannot
    # happen on this hardware.
    libinput.enable = mkDefault false;
    power-profiles-daemon.enable = mkDefault false;
    udisks2.enable = mkDefault false;
    upower.enable = mkDefault false;
  };
}
