{ lib, ... }:
with lib;
{
  # Every devHost.* option. Kept free of `pkgs` and of any dependency on the
  # rest of the module set, so this file can be evaluated on its own to derive
  # a schema from it if that is ever wanted.
  options.devHost = {
    hostName = mkOption {
      type = types.str;
      default = "nix-dev-host";
      description = ''
        Hostname for the system.

        The default is a placeholder that lets the generic guided ISO exist
        (it bakes the module with no settings at all); a guided install asks
        for the real one on the box.
      '';
    };

    diskDevice = mkOption {
      type = types.str;
      default = "/dev/sda";
      description = ''
        Disk device for installation. The module declares the whole partition
        table from this (see modules/storage.nix), so it expects to own the
        disk.
      '';
    };

    swapSizeGiB = mkOption {
      type = types.int;
      default = 96;
      description = ''
        Size of the swap partition, in GiB. 0 omits the partition entirely.

        This is install-time: it shapes the disko table and changing it does
        not repartition a machine that is already running. An existing host
        that needs more swap wants a swapfile instead — on btrfs that means
        nodatacow and no compression, so it is a manual job rather than
        something this option can do.

        zswap sits in front of it (see the `zswap.*` kernel params in
        storage.nix, active whenever this is above 0), compressing pages
        into a RAM-resident pool before the kernel ever touches the disk.
        Without a backing device zswap has nowhere to spill once that pool
        fills, so this option is also what makes zswap itself functional,
        not just what sits behind it.

        96 GiB, not the 8 GiB a thin last-resort tier would use: this is a
        build host, where the failure mode is a linker or a large parallel
        compile getting OOM-killed at the end of an hour-long job, and a
        pool that fills early costs far more than the disk space does. It
        also covers hibernation — which needs a resume device at least as
        large as RAM — on the RAM sizes this module targets. Size it
        against the machine in front of you regardless: less is reasonable
        on a smaller disk where the space is worth more than a tier that is
        only reached under real pressure. At 0 there is no swap partition,
        no `boot.resumeDevice`, no hibernation, and zswap has nothing to
        compress into — no swap at all.
      '';
    };

    timeZone = mkOption {
      type = types.str;
      default = "America/New_York";
      description = "System timezone.";
    };

    locale = mkOption {
      type = types.str;
      default = "en_US.UTF-8";
      description = "System locale.";
    };

    username = mkOption {
      type = types.str;
      default = "dev";
      description = ''
        Primary user name.

        A placeholder default, for the same reason as hostName; a guided
        install asks for it.
      '';
    };

    initialPassword = mkOption {
      type = types.str;
      default = "password";
      description = ''
        Initial password for the user. Change it at install, or immediately
        after — this lands in the world-readable Nix store, so it is a
        first-login credential and nothing more. Password authentication over
        SSH is off (modules/networking.nix), so the exposure is console and
        `su`.
      '';
    };

    sshKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "SSH public keys for the primary user and for root.";
    };

    stateVersion = mkOption {
      type = types.str;
      default = "25.11";
      description = "NixOS state version.";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Additional packages to install system-wide.";
    };

    upgradeFlake = mkOption {
      type = types.str;
      default = "/etc/nixos";
      example = "github:Owner/host-repo#my-host";
      description = ''
        The flake `system-upgrade` (and its timer) rebuilds from.

        A local path — the default — is a flake living on the machine: its
        inputs are updated in place, and it is rebuilt only if the lock moved.

        Anything else is a remote flake reference, and the repository's own
        flake.lock is authoritative: the machine never updates a lock of its
        own, and rebuilds when the repository's revision differs from the one
        it is running (`nixos-version --configuration-revision`).
        lib.mkHost sets this for a host installed with `deployedConfiguration`.
      '';
    };

    githubTokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = literalExpression "config.age.secrets.github-token.path";
      description = ''
        A file, present at runtime, holding the nix.conf line
        `access-tokens = github.com=<token>` — typically an agenix secret.

        nix `!include`s it, for private `github:` inputs. git gets the same
        token through a credential helper, for private clones and for
        `git+https://` inputs, which nix fetches by running git. It is only
        ever read at runtime, so the token stays out of the store; a user who
        cannot read the file gets neither, silently.
      '';
    };

    features = {
      autoUpgrade = mkOption {
        type = types.bool;
        default = true;
        description = ''
          The daily upgrade timer: rebuild from upgradeFlake, only when
          something actually moved — the local flake's lock, or the remote
          repository's revision. The manual `system-upgrade` command works
          either way.

          Daily rather than hourly, and it does not reboot. Both are risk
          decisions rather than resource ones. This host tracks
          nixos-unstable HEAD with no staging and no rollback gate, so an
          hourly cadence is two dozen unvetted rebuilds a day, each preceded
          by a full flake evaluation that transiently costs hundreds of MB;
          and an unattended reboot in the small hours kills whatever build or
          container was running. Reboots happen when a person decides they
          do.
        '';
      };

      buildGuards = mkOption {
        type = types.bool;
        default = true;
        description = ''
          cgroup resource guards around building. This protects sshd and the
          container workloads with MemoryLow so that reclaim takes their
          pages last, and puts a MemoryHigh ceiling and an OOM backstop on
          nix-daemon.

          The shape is deliberately the reverse of what a desktop wants. On a
          workstation the build is the intruder and gets throttled hard; here
          the build is the machine's job, so the ceiling is generous and the
          work goes into making sure a build storm cannot cost you the SSH
          session you would need to stop it.

          Turn off on a box with enough RAM that none of this ever binds.
        '';
      };

      containers = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Podman with Docker compatibility (the CLI alias and the socket),
          plus the btrfs storage driver matching the root filesystem. No
          containers are declared by this module; it provides the runtime.
        '';
      };

      firmwareUpdates = mkOption {
        type = types.bool;
        default = false;
        description = ''
          fwupd, for firmware updates through LVFS.

          Off by default. On a headless box nothing consumes it
          opportunistically — there is no GNOME Software offering updates in
          a tray — so it is a daemon and roughly 200 MB of closure standing
          by for something a person does deliberately, perhaps twice in the
          machine's life. Turn it on for that afternoon.
        '';
      };

      networkDiscovery = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Avahi: mDNS resolution and publishing.

          On, and publishing is on with it, which is the opposite of what a
          laptop should do. It is load-bearing here: the usual way to reach a
          freshly installed box — for `nix run .#deploy`, a
          `nixos-rebuild --target-host`, or plain ssh — is as
          `<hostname>.local`, so turning publishing off breaks that path.
        '';
      };

      networkTuning = mkOption {
        type = types.bool;
        default = true;
        description = ''
          bpftune, which watches for network bottlenecks and adjusts kernel
          sysctls to match.

          Defensible on a server in a way it is not on a desktop: the
          congestion-window and buffer sizing it corrects are things a box
          serving containers over a LAN actually runs into. It is still a
          resident daemon loading BPF programs, and it changes tunables
          underneath you, so it is a flag rather than a default.
        '';
      };

      sambaShares = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Samba, exporting home directories to the local network only.
          Opens 139/445 through the firewall when on.
        '';
      };
    };
  };
}
