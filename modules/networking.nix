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
  networking = {
    hostName = cfg.hostName;

    # systemd-networkd owns addressing, configured directly below rather than
    # through networking.useNetworkd. Both the scripted DHCP client and the
    # NixOS-generated networkd units are out of the way.
    useDHCP = mkDefault false;
    dhcpcd.enable = mkDefault false;
    useNetworkd = mkDefault false;

    # Left at the NixOS default, which is on, and stated so that nobody
    # copying settings across from the sibling desktop module brings its
    # `firewall.enable = false` with them. That is a defensible position for
    # a laptop with nothing listening; this box runs sshd, podman and
    # optionally Samba.
    firewall.enable = mkDefault true;
  };

  systemd.network = {
    enable = mkDefault true;
    networks."10-wan" = {
      # [Match] Name= is a single whitespace-separated glob list, not
      # repeated keys; a Nix list would render as multiple Name= lines.
      matchConfig.Name = mkDefault "en* eth*";
      networkConfig = {
        DHCP = mkDefault "yes";
        IPv6AcceptRA = mkDefault true;
      };
      dhcpV4Config = {
        RouteMetric = mkDefault 1024;
        UseDNS = mkDefault true;
      };
      # [DHCPv6] has no RouteMetric= key (it never has); the IPv6 default
      # route here is learned via Router Advertisement, so its metric is set
      # in [IPv6AcceptRA] below.
      dhcpV6Config = {
        UseDNS = mkDefault true;
      };
      ipv6AcceptRAConfig = {
        RouteMetric = mkDefault 1024;
        UseDNS = mkDefault true;
      };
    };
  };

  # Release network-online.target as soon as *one* interface is up. The
  # upgrade timer in nix.nix waits on that target, and the default — every
  # managed link must be online — means a second unplugged port holds it
  # until systemd-networkd-wait-online gives up on its timeout.
  systemd.network.wait-online.anyInterface = mkDefault true;

  # ── mDNS ────────────────────────────────────────────────────
  # Publishing is on, which is the opposite of what the sibling desktop
  # module does and is deliberate: local/deploy.sh and local/update.sh reach
  # this machine as <hostname>.local, so publishing is part of how the box is
  # administered rather than a speculative convenience.
  services.avahi = {
    enable = mkDefault cfg.features.networkDiscovery;
    nssmdns4 = mkDefault true;
    publish = {
      addresses = mkDefault true;
      enable = mkDefault true;
      workstation = mkDefault true;
    };
  };

  # ── SSH ─────────────────────────────────────────────────────
  # The only way in. Keys only — devHost.initialPassword is a console
  # credential and deliberately cannot be used over the network.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  # ── Samba ───────────────────────────────────────────────────
  services.samba = {
    enable = mkDefault cfg.features.sambaShares;
    openFirewall = mkDefault true;
    settings = {
      global = {
        "workgroup" = mkDefault "WORKGROUP";
        "server string" = mkDefault "NixOS Dev Host - ${cfg.hostName}";
        "netbios name" = mkDefault cfg.hostName;
        # RFC1918 only. "hosts deny" is evaluated after "hosts allow", so the
        # blanket deny is the default and the private ranges are the
        # exception to it.
        "hosts allow" = mkDefault "192.168.0.0/16 172.16.0.0/12 10.0.0.0/8 localhost";
        "hosts deny" = mkDefault "0.0.0.0/0";
        "map to guest" = "never";
      };
      homes = {
        "comment" = "Home Directories";
        "browseable" = "no";
        "read only" = "no";
        "create mask" = "0700";
        "directory mask" = "0700";
        "valid users" = "%S";
      };
    };
  };
}
