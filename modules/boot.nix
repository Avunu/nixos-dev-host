{ lib, ... }:
with lib;
{
  boot = {
    initrd = {
      # A plain list rather than mkDefault, so a host adding a module for its
      # own controller appends to this instead of having to restate it. That
      # is how list-typed options merge when every definition is at the same
      # priority; an mkDefault list is all-or-nothing.
      availableKernelModules = [
        "ahci"
        "ehci_pci"
        "nvme"
        "uhci_hcd"
        "xhci_pci"
      ];
      kernelModules = [ "kvm-intel" ];

      systemd = {
        # On, and it had to go on. The scripted initrd this used to run is
        # deprecated and scheduled for removal in 26.11 — evaluating the
        # module against current nixpkgs prints exactly that — and this host
        # tracks nixos-unstable on a timer, so "deprecated" arrives as
        # "stopped booting" rather than as a warning someone reads.
        #
        # It also makes the line below mean something: tpm2.enable is an
        # option of the systemd initrd, so with the scripted initrd it was
        # set, merged, and had no effect whatsoever.
        enable = mkDefault true;
        tpm2.enable = mkDefault true;
      };

      # Was true, next to consoleLogLevel = 0 below, which is the
      # configuration asking for a loud boot and a silent console at the same
      # time. Quiet is the half worth keeping: a headless box's boot output
      # goes to a screen nobody is looking at, and journalctl -b has it
      # afterwards either way.
      verbose = mkDefault false;
    };

    # Kernel package deliberately left at the nixpkgs default (LTS) — see
    # commit 97b60b1. linuxPackages_latest on a machine that rebuilds itself
    # unattended is a way to find out about regressions at 4am.

    kernelParams = [
      "boot.shell_on_fail"
      "quiet"
      "rd.udev.log_level=3"
      "udev.log_priority=3"
      #
      # No "loglevel=" in this list on purpose: consoleLogLevel below already
      # produces one, and NixOS appends it *after* these, so a second value
      # stated here would be silently overridden by the option's. That is the
      # same kind of contradiction the initrd note above just removed.
      #
      # Huge pages only where a program asks for one. The kernel default
      # ("always") has khugepaged compacting memory in the background to
      # manufacture 2 MB pages; on a box whose memory is mostly page cache
      # for a Nix store and anonymous memory for compilers, that compaction
      # is work done for nobody. Pairs with vm.compaction_proactiveness = 0
      # below — one turns off the demand, the other the background effort.
      "transparent_hugepage=madvise"
    ];

    # What is deliberately NOT here, having been removed:
    #
    #   i915.enable_guc=3, i915.modeset=1 — there is no display output on
    #   this machine and nothing renders.
    #
    #   pcie_aspm.policy=powersupersave — actively wrong on a server. It
    #   trades link wake latency for idle power on every PCIe device,
    #   including the NIC this box is reached over and the NVMe it builds on.
    #
    #   mem_sleep_default=deep — a headless host should not be suspending at
    #   all, so the question of which sleep state it picks does not arise.
    #
    #   init_on_alloc=0 / init_on_free=0 — tempting, and not taken. Zeroing
    #   pages on allocation costs real memory bandwidth, but what it buys is
    #   that uninitialised heap and page contents are reliably zero, which is
    #   what keeps a class of info-leak and use-after-free bugs from becoming
    #   exploitable. That is a trade a single-user laptop can make and a box
    #   with listening services should not.

    kernel.sysctl = {
      # ── Writeback ──────────────────────────────────────────
      # Bound the dirty-page backlog. The defaults (20% hard, 10%
      # background) let a large fraction of RAM queue up dirty before
      # anything is forced out, and this machine has no fast way to drain
      # that: every page goes through zstd compression on the way to the
      # disk. Whoever hits the hard limit then blocks until the queue
      # empties. Starting earlier keeps each stall short — which matters
      # most exactly when it is worst, at the end of a build writing a large
      # output.
      "vm.dirty_ratio" = mkDefault 10;
      "vm.dirty_background_ratio" = mkDefault 5;

      # ── Reclaim ────────────────────────────────────────────
      # High swappiness on purpose. With zram present the cheap thing to
      # evict is anonymous memory — it is compressed and stays in RAM —
      # and the expensive thing is file-backed pages, which have to be read
      # back off the disk. On a build host those file-backed pages are the
      # Nix store and the compiler's own text, so refaulting them is the
      # stall you actually feel.
      "vm.swappiness" = mkDefault 100;

      # No swap-in readahead. Right for zram, which is the tier that is
      # actually hot: reading one compressed page back is cheap and guessing
      # at its neighbours is not.
      "vm.page-cluster" = mkDefault 0;

      # kswapd wakes when free memory drops to 0.1% of the zone. A burst of
      # allocation — say, several compilers starting at once — overruns that
      # runway and lands in *direct* reclaim, which stalls the allocating
      # thread rather than a background kernel thread. Giving kswapd room to
      # stay ahead costs a little memory kept free that could have been
      # cache.
      "vm.watermark_scale_factor" = mkDefault 200;

      # Background CPU spent keeping high-order pages available. With
      # transparent_hugepage=madvise above, almost nothing here asks for one.
      "vm.compaction_proactiveness" = mkDefault 0;
    };

    consoleLogLevel = mkDefault 0;

    loader = {
      efi.canTouchEfiVariables = mkDefault true;
      systemd-boot = {
        configurationLimit = mkDefault 10;
        enable = mkDefault true;
      };
    };

    plymouth.enable = mkDefault false;
  };
}
