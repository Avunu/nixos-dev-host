# Avunu NixOS Development Environment Host Configuration

A headless development and build host, as a single NixOS module plus every
way to (re)deploy it.

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
| Upgrades | one daily timer that only rebuilds when something actually moved — a local flake's lock, or the host repository's revision |
| Secrets | agenix, decrypting with a pre-provisioned identity at `/etc/agenix/key` — not the SSH host key, so a redeploy never needs a re-key |
| Deployment | [nixos-install-helper](https://github.com/Avunu/nixos-install-helper): nixos-anywhere, an unattended offline ISO, a guided ISO |

## Install and update

From a checkout (the apps build `.`):

```sh
nix run                             # wizard: settings, then network / unattended ISO / guided ISO
nix run .#deploy -- root@<ip>       # nixos-anywhere onto a box booted into any Linux with SSH
nix build --impure .#installerIso   # offline ISO that installs this exact host, unattended
nix build .#guidedIso               # generic offline ISO: asks hostname, user, disk and key on the box
```

Per-host answers (`nix run .#configure`) land in `installer/devHost-settings.json`,
which is gitignored; the wizard and `deploy` read it by path. A host installed
from here gets `/etc/nixos` as a small flake that imports `devHost` from this
repository and reads those settings, plus a `local.nix` for anything else.

On the machine itself, `system-upgrade` rebuilds from `devHost.upgradeFlake`
when something moved, and a daily timer runs it (`features.autoUpgrade`).

## Secrets

agenix on a dev host decrypts with `/etc/agenix/key`, a key made for the host
and carried into every install, rather than the SSH host key every install
generates afresh. Secrets are encrypted to it (and to the operators) once.

The key itself lives in the host's repository as `secrets/key.age`, encrypted to
the operators only. Enter that repository's devShell (`direnv allow`, via
`use flake`) and agenix-shell decrypts it into `$agenix__key`; `deploy`, the
wizard and `installerIso` all pick it up from there and write it to
`/etc/agenix/key` on the target. A missing key stops the install rather than
producing a machine that cannot decrypt anything. agenix-shell tries
`$AGENIX_IDENTITY`, then `~/.ssh/id_ed25519` and `~/.ssh/id_rsa` (hosts can
override the list).

`devHost.githubTokenFile` points at a secret holding the nix.conf line
`access-tokens = github.com=<token>`. nix `!include`s it and git gets the same
token through a credential helper — both at runtime, so the token never enters
the store.

## A specific machine

A machine with its own repository calls `lib.mkHost` and gets all of the above:

```nix
{
  inputs.nixos-dev-host.url = "github:Avunu/nixos-dev-host";
  inputs.nixpkgs.follows = "nixos-dev-host/nixpkgs";

  outputs = { self, nixpkgs, nixos-dev-host, ... }:
    let
      host = nixos-dev-host.lib.mkHost {
        inherit self nixpkgs;
        # The host rebuilds straight from its repository; nothing in /etc/nixos.
        deployedConfiguration = "github:Owner/my-host#my-host";
        agenixKeyFile = ./secrets/key.age;
        modules = [ ./host.nix ];   # devHost.* values and anything else
      };
    in
    { inherit (host) nixosModules nixosConfigurations packages apps devShells; };
}
```

With `deployedConfiguration` the repository's `flake.lock` decides every
version: `system-upgrade` rebuilds when the repository's revision differs from
the running one, and never updates a lock of its own. Update the lock in the
repository.

## Configuration

Everything is under `devHost.*`. See [modules/options.nix](modules/options.nix),
which carries the reasoning for each one.

| Option | Type | Default |
| --- | --- | --- |
| hostName | string | "nix-dev-host" — a placeholder for the guided ISO |
| username | string | "dev" — likewise |
| initialPassword | string | "password" — change it |
| diskDevice | string | /dev/sda |
| swapSizeGiB | int | 96 — 0 omits the partition. Install-time |
| sshKeys | list of strings | [ ] |
| timeZone / locale | string | America/New_York / en_US.UTF-8 |
| stateVersion | string | "25.11" |
| extraPackages | list of packages | [ ] |
| upgradeFlake | string | /etc/nixos — or a `github:` ref (set by `lib.mkHost`) |
| githubTokenFile | string or null | null — runtime path of an `access-tokens` line |

| features.* | Default |  |
| --- | --- | --- |
| autoUpgrade | on | the daily upgrade timer; `system-upgrade` works either way |
| buildGuards | on | cgroup limits protecting sshd and containers from a build storm |
| containers | on | podman + Docker compatibility |
| firmwareUpdates | off | fwupd — a daemon and ~200 MB for something you do deliberately |
| networkDiscovery | on | Avahi, **publishing** — reaching a new box as `<hostname>.local` depends on it |
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
| modules/secrets.nix | the agenix identity and GitHub access |
| pkgs/ | the derivations more than one module needs |
| lib/mk-host.nix | `lib.mkHost`: a host flake's installers, devShell and configuration |

## Verifying a change

The root flake exports a configuration and a check, so an eval error is
caught before a host tries to boot on it. This matters here more than most
places: the machine tracks `nixos-unstable` on a timer and applies what it
finds, so an option rename upstream arrives unattended.

```sh
nix build .#checks.x86_64-linux.eval          # full eval, no system build
nix build --dry-run .#nixosConfigurations.example.config.system.build.toplevel
nix build .#checks.x86_64-linux.offline-install-guided   # slow: installs from the ISO in a VM
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
