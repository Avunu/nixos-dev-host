# Avunu NixOS Development Environment Host Configuration

A headless development and build host, as a single NixOS module plus a
deployment path.

The target is a bare-metal box on a LAN: no screen, no battery, nobody in
front of it. People reach it over SSH, run containers on it, and build things
on it. That last part drives most of the non-obvious choices here — this is
the machine that does the compiling, so where a workstation configuration
would throttle a build to keep a desktop responsive, this one leaves the
build alone and protects the SSH session you would need in order to stop it.

## What you get

|  |  |
| --- | --- |
| Storage | btrfs root with forced zstd compression, a swap partition with zswap in front of it, disko-declared |
| Boot | systemd-boot, systemd initrd, quiet, 10 generations |
| Containers | podman with Docker compatibility (CLI alias and socket), btrfs storage driver |
| Networking | systemd-networkd, Avahi publishing `<hostname>.local`, sshd (keys only), optional Samba |
| Toolchain | Python, Node, Bun, cmake, ccache, gh, direnv + nix-direnv, nix-ld |
| Upgrades | one daily timer that only rebuilds when the flake lock actually moved |

## Install and update

```sh
cd local
./deploy.sh <fqdn> <ip> <username>   # nixos-anywhere, first install
./update.sh <fqdn>                   # nixos-rebuild --target-host
```

On the machine itself, `system-upgrade` does a flake update and switches if
the lock changed. It is also on a daily timer (`features.autoUpgrade`).

## Configuration

Everything is under `devHost.*`. See [modules/options.nix](modules/options.nix),
which carries the reasoning for each one.

| Option | Type | Default |
| --- | --- | --- |
| hostName | string | required |
| username | string | required |
| initialPassword | string | "password" — change it |
| diskDevice | string | /dev/sda |
| swapSizeGiB | int | 96 — 0 omits the partition. Install-time |
| sshKeys | list of strings | [ ] |
| timeZone / locale | string | America/New_York / en_US.UTF-8 |
| stateVersion | string | "25.11" |
| extraPackages | list of packages | [ ] |

| features.* | Default |  |
| --- | --- | --- |
| autoUpgrade | on | the daily upgrade timer; `system-upgrade` works either way |
| buildGuards | on | cgroup limits protecting sshd and containers from a build storm |
| containers | on | podman + Docker compatibility |
| firmwareUpdates | off | fwupd — a daemon and ~200 MB for something you do deliberately |
| networkDiscovery | on | Avahi, **publishing** — the deploy scripts depend on it |
| networkTuning | on | bpftune |
| sambaShares | off | home directories to the LAN; opens 139/445 |

## Repository layout

`nixosModules.devHost` is one module, assembled from `modules/`:

|  |  |
| --- | --- |
| modules/options.nix | every devHost.* option |
| modules/boot.nix | kernel, command line, sysctls, bootloader |
| modules/storage.nix | disko table, btrfs profile, swap, zswap, block layer |
| modules/nix.nix | nix settings, the build resource guards, the upgrade timer |
| modules/networking.nix | networkd, Avahi, ssh, firewall, Samba |
| modules/services.nix | the remaining daemons |
| modules/containers.nix | podman and container storage |
| modules/packages.nix | what is installed |
| modules/system.nix | console, locale, users, documentation |
| pkgs/ | the derivations more than one module needs |

`local/` holds the per-host flake and the deploy scripts. It is not part of
the root flake.

## Verifying a change

The root flake exports a configuration and a check, so an eval error is
caught before a host tries to boot on it. This matters here more than most
places: the machine tracks `nixos-unstable` on a timer and applies what it
finds, so an option rename upstream arrives unattended.

```sh
nix build .#checks.x86_64-linux.eval          # full eval, no system build
nix build --dry-run .#nixosConfigurations.example.config.system.build.toplevel
nix fmt
```

Watch stderr for `evaluation warning:` lines, not just for success — that is
how the deprecated scripted initrd was found.

## Positions, not defaults

All reversible, and each argued where it is set:

- **The build is not throttled.** `max-jobs` and `cores` stay at their
  defaults; capping parallelism on the machine whose job is compiling is the
  wrong end of the problem. What is bounded is `nix-daemon`'s share of memory
  (`MemoryHigh` 70%), with `MemoryLow` reserved for sshd and `machine.slice`.
- **Store deduplication runs on a timer, not inline.** `auto-optimise-store`
  is off and `nix.optimise` weekly is on, so the hashing happens when nobody
  is waiting on a build.
- **The nixpkgs source is not pinned into the closure** (210 MB). The flake
  registry is pinned to the same revision as a github ref instead, so
  `nix shell nixpkgs#foo` still resolves to what this system was built from.
  Offline evaluation is what is given up.
- **Man pages and dev headers are on.** The NixOS manual is not — it would be
  rebuilt on every upgrade.
- **The upgrade timer is daily and does not reboot.** It tracks unstable HEAD
  with no staging and no rollback gate; an unattended reboot in the small
  hours kills whatever was running.
- **logrotate and fstrim are off.** journald bounds itself, and the root
  filesystem carries `discard=async`.
- **`trusted-users` includes `@wheel`**, which is root-equivalent. Intended
  on a shared dev box, but it is a posture.
- **`initialPassword` defaults to `password`** and is a console credential
  only — SSH password authentication is off.
- **`allowUnfree` is on.**

Most non-obvious choice in this repository carries its reasoning in a comment
next to it. If something here looks wrong, the argument for it is probably in
the file.
