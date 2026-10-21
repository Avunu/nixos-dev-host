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

    nixDiskDevice = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/dev/disk/by-id/ata-Example_SSD_2TB_S1A2B3C4D5E6";
      description = ''
        A second disk that holds /nix and nothing else: one btrfs filesystem
        with the root's mount options (but its own compression level, see
        nixDiskCompression), mounted ahead of the rest of the system. Null,
        the default, leaves /nix on the root filesystem, on diskDevice.

        For a machine whose store outgrows its system disk — a CI runner, a
        build host — since /nix is what such a machine fills: the store
        itself, its database and the garbage collector's roots all live
        under it.

        Like diskDevice this is install-time, and the disk is wiped. On a
        machine that is already running it adds a /nix mount that nothing has
        formatted, and the machine will not boot; move an installed store
        over by hand instead.

        Prefer a /dev/disk/by-id/ path. /dev/sdX is whichever disk the kernel
        probed first, so it can name the installer's own USB stick.
      '';
    };

    nixDiskCompression = mkOption {
      type = types.strMatching "(zstd|zlib)(:[0-9]+)?|lzo";
      default = "zstd:6";
      description = ''
        The btrfs compression (always forced, see modules/storage.nix) of the
        filesystem on nixDiskDevice. It has no effect without one: the root
        filesystem is always zstd:3.

        A Nix store is written once and read for as long as it lives, so it
        can afford more than the root does. Measured over a random sample of
        a real store, compressed the way btrfs does it (128 KiB extents):

        | level | ratio | single-thread speed |
        | --- | --- | --- |
        | zstd:1 | 1.78 | 566 MB/s |
        | zstd:3 | 1.84 | 418 MB/s |
        | zstd:6 | 1.90 | 140 MB/s |
        | zstd:9 | 1.91 | 94 MB/s |
        | zstd:12 | 1.92 | 40 MB/s |
        | zstd:15 | 1.99 | 18 MB/s |

        The default is where the curve bends: 9 and 12 buy almost nothing, and
        15 is slow enough to throttle writes to a SATA SSD. A change of level
        applies to what is written after the next mount; extents already
        on disk keep theirs.

        A typo here fails at mount time, in the initrd, so the type rejects
        anything that is not a btrfs compression name.
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

    flakeAutoUpdate = {
      stateDirectory = mkOption {
        type = types.str;
        default = "/var/lib/flake-auto-update";
        description = ''
          Where the working clones live, one directory per repository under
          it. Each clone belongs to its service and is reset to the remote on
          every run, so local edits made here are discarded.
        '';
      };

      repositories = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              url = mkOption {
                type = types.str;
                example = "https://github.com/Owner/host-repo.git";
                description = "The repository to clone.";
              };

              branch = mkOption {
                type = types.str;
                default = "main";
                description = ''
                  The branch whose flake.lock is refreshed. Each run starts
                  from this branch's remote head, so the lock is always
                  re-locked against the latest commit.
                '';
              };

              pushBranch = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Where the refreshed lock is pushed. Null means back onto
                  `branch`, which is the normal case, and it moves that branch
                  for every node that pulls it.

                  Anything else is a side branch, rebuilt from `branch` plus a
                  single lock commit on every change, force-pushed with a
                  lease so a human push to it is never silently overwritten.
                  Nothing downstream applies a side branch until someone merges
                  it, so a pull request into `branch` is opened for it when
                  none is open. Pushing to the open one updates it; one that
                  was closed or merged for the very same lock is not reopened.
                '';
              };

              interval = mkOption {
                type = types.str;
                default = "10min";
                description = ''
                  How often this repository is refreshed, as a systemd time
                  span. The first run is two minutes after boot.
                '';
              };
            };
          }
        );
        default = { };
        example = literalExpression ''
          {
            my-host = { url = "https://github.com/Owner/my-host.git"; };
          }
        '';
        description = ''
          Repositories whose flake.lock this host keeps current, keyed by a
          short name. Each one gets its own timer and service, named
          flake-auto-update-<name>, so one failing repository does not hold up
          the others.

          Each run clones (if needed), runs `nix flake update`, and commits and
          pushes the lock only if it moved. This is the lock only. A host that
          rebuilds from a remote repository (upgradeFlake) picks the pushed
          lock up on its own system-upgrade run, so the rebuild cadence is still
          set by features.autoUpgrade.

          Pushing needs write access. The push goes through the same GitHub
          credential helper as the reads, so githubTokenFile has to be a token
          that can write to every repository listed here. A repository with a
          pushBranch also gets pull requests opened through the GitHub API with
          that token, so it needs pull-request write access there too.
        '';
      };
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

      consoleMonitor = mkOption {
        type = types.bool;
        default = true;
        description = ''
          btop on tty1 instead of a login prompt, so a screen plugged into the
          machine shows what it is doing. It is a systemd service that owns
          the console the way a display manager would (modules/system.nix),
          not a program started from a login shell, so there is no login to
          get past and nothing to log out of.

          tty2 to tty6 keep their login prompts (Ctrl-Alt-F2), SSH is
          untouched, and `systemctl start getty@tty1` swaps tty1 over to a
          login until the next boot.

          It runs as an unprivileged dynamic user, deliberately: a console
          that asks for no password should be able to look, not to signal or
          renice anything. Quitting btop starts it again.

          On a box that never has a screen attached this is sampling for an
          audience of nobody, and a reason to turn it off — tty1 then gets an
          ordinary login prompt like the others.
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
