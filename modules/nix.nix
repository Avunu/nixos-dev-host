{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.devHost;

  # The `system-upgrade` command the timer below runs. It is also on PATH for
  # manual runs — modules/packages.nix puts it in systemPackages.
  systemUpgradeScript = import ../pkgs/system-upgrade.nix {
    inherit pkgs;
    flake = cfg.upgradeFlake;
  };
in
{
  # ── The nixpkgs source is not worth 210 MB here ─────────────
  # Building a system from a flake makes NixOS pin that flake's nixpkgs into
  # the machine, both in /etc/nix/registry.json (so `nixpkgs#foo` resolves)
  # and on NIX_PATH (so `<nixpkgs>` does). The pin is a store path, so the
  # whole nixpkgs *source tree* lands in the system closure. Measured with
  # `nix path-info -S` against this flake's own lock: 210 MB.
  #
  # On a desktop the honest answer is to drop both and let `nixpkgs` resolve
  # over the network — the same network the packages come from anyway. That
  # argument is weaker here, because `nix shell nixpkgs#foo` and `nix-shell
  # -p` are things this machine exists to do rather than things it does by
  # accident.
  #
  # So: drop the store-path pin, and replace it with a github registry entry
  # at the same revision. `nixpkgs#foo` still resolves, still resolves to
  # exactly the revision this system was built from, and costs nothing in the
  # closure — the difference between naming a commit and shipping a checkout
  # of it. What is given up is offline *evaluation*, which was the wrong half
  # of the problem: evaluating a package offline does not build it, and the
  # download that follows needs the network the pin was meant to make
  # unnecessary.
  #
  # Both halves have to go together — they reference the same store path, so
  # dropping one saves nothing. The matching `nix.nixPath` line in the
  # consuming flake (local/flake.nix) has to go too, or the 210 MB stays.
  nixpkgs.flake = {
    setNixPath = mkDefault false;
    setFlakeRegistry = mkDefault false;
  };

  nix.registry.nixpkgs.to = {
    type = "github";
    owner = "NixOS";
    repo = "nixpkgs";
  }
  // optionalAttrs (inputs.nixpkgs ? rev) { inherit (inputs.nixpkgs) rev; };

  # ── Nix configuration ───────────────────────────────────────
  nix = {
    gc = {
      automatic = mkDefault true;
      dates = mkDefault "weekly";
      options = mkDefault "--delete-older-than 1w";
    };

    # Store deduplication, moved off the build path. What it saves is not in
    # question — a Nix store carries a great many byte-identical files across
    # generations and packages, and no compression ratio touches a duplicate,
    # so this and the btrfs zstd in storage.nix save different things.
    #
    # The question is only when it runs. auto-optimise-store (set here until
    # now) ran it inline: every substituted path hashed and linked before nix
    # would call the build done, while someone was waiting on the build. The
    # timer does the same work when nobody is, and gc.dates already
    # established weekly as the cadence for store maintenance.
    #
    # The honest counter-argument: inline optimisation hashes files it has
    # just written, so they are still in page cache, whereas nix-store
    # --optimise walks the store cold. This trades more total I/O for I/O
    # that happens at night.
    optimise = {
      automatic = mkDefault true;
      dates = mkDefault [ "weekly" ];
    };

    settings = {
      auto-optimise-store = mkDefault false;

      experimental-features = [
        "nix-command"
        "flakes"
        # What makes use-cgroups below possible, and therefore what makes the
        # ceiling on nix-daemon cover builds rather than just the daemon.
        "cgroups"
      ];

      # Each build gets its own child cgroup. Without this, MemoryHigh on
      # nix-daemon bounds the daemon's own bookkeeping and lets the builders
      # it forked run unaccounted.
      use-cgroups = true;

      # max-jobs and cores are deliberately left at their defaults. The
      # sibling desktop module pins max-jobs = 1 because four concurrent
      # compilers on a 4 GB dual core is a swap storm; capping parallelism on
      # the machine whose job is compiling is the opposite mistake. Same for
      # max-substitution-jobs: 16 concurrent downloads is a stampede on a
      # home link and unremarkable on wired LAN.

      # Dev shells and direnv environments are the point of this machine, and
      # gc.options above deletes anything a week old. Keeping outputs and
      # derivations means `nix develop` in a project untouched for a fortnight
      # does not rebuild the world. angrr (programs.direnv.angrr, in
      # packages.nix) handles the GC roots themselves.
      keep-outputs = true;
      keep-derivations = true;

      substituters = [
        "https://cache.nixos.org?priority=40"
        "https://nix-community.cachix.org?priority=41"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];

      # Worth being clear about what this grants: a trusted user can hand the
      # daemon arbitrary store paths and set their own substituters, which is
      # root-equivalent. That is the intended posture on a shared dev box —
      # everyone in wheel is already an administrator here — but it is a
      # posture, not a detail.
      trusted-users = [
        "root"
        cfg.username
        "@wheel"
      ];
    };
  };

  # The store optimiser, minus the one condition NixOS ships that does not
  # survive contact with hardware that has a battery. Its unit carries
  # ConditionACPower = true, which is a reasonable default and a trap: a
  # machine on battery has the timer fire, the condition fail, the run
  # recorded as satisfied, and the store never deduplicated at all. The
  # failure is silent in both directions — nothing errors, and `systemctl
  # status` reports success. Persistent = true does not rescue it; that
  # catches up runs missed while the machine was powered OFF, not runs
  # skipped while it was on a battery.
  #
  # A mains-powered box with no battery satisfies the condition anyway, so on
  # this machine as it stands this line changes nothing. It is here so that
  # moving the configuration to a chassis that has one does not quietly turn
  # store deduplication off.
  #
  # mkForce, and it has to be: nix-optimise.nix sets the condition at normal
  # priority, so mkDefault here would lose silently.
  systemd.services.nix-optimise.unitConfig.ConditionACPower = mkForce "";

  # ── Resource guards ─────────────────────────────────────────
  # The failure this aims at is not "the machine ran out of memory". It is
  # the one where a large build drives the kernel to evict file-backed pages
  # — everybody's executables and the store itself — and then fault them
  # straight back in. The kernel counts that memory as reclaimable, so the
  # OOM killer never has grounds to fire and the machine simply thrashes.
  # Free memory and swap both read healthy right through it, which is why a
  # free-memory watchdog like earlyoom cannot see it and is not used here.
  #
  # The shape is the reverse of what a workstation wants. There, the build is
  # the intruder and gets throttled hard so the desktop stays responsive.
  # Here the build is the machine's job, so most of the effort goes into
  # protecting the things that must survive it — above all the SSH session
  # you would need in order to intervene.
  #
  # Each guard is attached by its own dotted path rather than through one
  # `systemd.services = { ... }` block, because this file also sets
  # nix-optimise above and system-upgrade below; a bare attrset here would be
  # a duplicate-attribute error at the language level, before the module
  # system ever gets a chance to merge them.

  # MemoryLow, not MemoryMin. MemoryLow marks this cgroup's pages as the ones
  # reclaim should take last; under real pressure the kernel will still dip
  # into it rather than OOM elsewhere. MemoryMin is a hard floor, which turns
  # a squeeze here into a kill somewhere else — and the somewhere else on
  # this box is a container someone is relying on.
  systemd.services.sshd.serviceConfig = mkIf cfg.features.buildGuards {
    MemoryLow = mkDefault "128M";
  };

  systemd.services.nix-daemon.serviceConfig = mkIf cfg.features.buildGuards {
    # A ceiling nix reclaims against *inside its own cgroup*, page cache
    # included — which is the whole point, since page cache is what a big
    # substitution takes. MemoryHigh throttles, it does not kill: a large
    # build or download simply goes slower and no derivation fails because
    # of it.
    #
    # 70%, not the 40% a desktop would set. Building is what this machine
    # is for; the ceiling exists to leave headroom for sshd and the
    # containers, not to make builds polite.
    MemoryHigh = mkDefault "70%";

    # Backstop, deliberately scoped to this one unit. systemd-oomd is
    # already running and polices nothing by default. Setting it here
    # rather than via systemd.oomd.enableUserSlices is what makes it safe:
    # policing the user slices would let oomd answer a build storm by
    # killing an SSH session or a container, which is exactly the outcome
    # the rest of this section is trying to prevent. This way the only
    # thing it can kill is the daemon that caused the pressure, and
    # nix-daemon is socket-activated, so it comes straight back.
    #
    # The cost is real: this can kill a legitimate build of something
    # enormous. At 80% of wall-clock time stalled on memory for thirty
    # seconds straight, that build was not going to finish in any useful
    # time anyway.
    ManagedOOMMemoryPressure = mkDefault "kill";
    ManagedOOMMemoryPressureLimit = mkDefault "80%";

    # No IOWeight here, and that is a decision rather than an omission.
    # BFQ is the only mq scheduler that implements io.weight, and
    # storage.nix deliberately leaves SATA devices on mq-deadline for
    # throughput — so an IOWeight line would be written to a file the
    # block layer ignores. See the note there.
  };

  # Containers get the same protection as sshd, for the same reason: a build
  # should not be able to evict the workloads the machine is hosting.
  #
  # machine.slice is where podman puts *rootful* containers — the ones
  # oci-containers and quadlets produce. Rootless containers started by a
  # logged-in user live under user.slice instead and are not covered by this;
  # protecting user.slice wholesale would also protect whatever else that
  # user is running, which on a dev box could be the build itself.
  systemd.slices = mkIf (cfg.features.buildGuards && cfg.features.containers) {
    machine.sliceConfig.MemoryLow = mkDefault "256M";
  };

  # No TMPDIR override for nix-daemon. The sibling desktop module moves build
  # scratch to /var/tmp because it puts /tmp on a tmpfs and then has to undo
  # the consequence — tmpfs pages are charged to the allocating cgroup, so
  # build scratch counts against the memory ceiling and gets pushed into the
  # zswap pool. boot.tmp.useTmpfs is left false here, so /tmp is already on
  # the btrfs root and there is nothing to fix. Do not switch it on.

  # ── nixpkgs ─────────────────────────────────────────────────
  nixpkgs.config = {
    allowUnfree = mkDefault true;
    allowUnfreePredicate = _: true;
  };

  # ── Automatic background upgrades ───────────────────────────
  # One mechanism, replacing three that used to race on /etc/nixos: an hourly
  # flake-update unit that committed the lock, system.autoUpgrade with its own
  # timer and unattended reboots, and a shell alias that did the same thing a
  # third way with --impure.
  #
  # NixOS's own system.autoUpgrade stays off (system.nix) — this timer is the
  # mechanism, and features.autoUpgrade is the switch. The manual
  # `system-upgrade` command always works regardless.
  systemd.services.system-upgrade = mkIf cfg.features.autoUpgrade {
    restartIfChanged = false;
    unitConfig = {
      Description = "Upgrade NixOS from ${cfg.upgradeFlake}";
      StartLimitIntervalSec = 300;
      StartLimitBurst = 5;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Environment = "HOME=/root";
      ExecStart = getExe systemUpgradeScript;
      Restart = "on-failure";
      RestartSec = "120s";
      # This is the one thing on the machine that runs a full flake
      # evaluation (hundreds of MB, transiently) and a rebuild unattended, on
      # a timer, while someone may well be in the middle of using the box. It
      # should always be the process that yields. The evaluation and the
      # rebuild driver run here; the fetching and building they trigger runs
      # in nix-daemon, under its own ceiling above.
      MemoryHigh = mkDefault "25%";
      CPUWeight = mkDefault 20;
      Nice = mkDefault 19;
    };
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = with pkgs; [
      git
      nix
    ];
  };

  systemd.timers.system-upgrade = mkIf cfg.features.autoUpgrade {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      Unit = "system-upgrade.service";
    };
  };
}
