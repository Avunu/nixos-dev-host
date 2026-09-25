{
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.devHost;

  swapPartition = {
    size = "${toString cfg.swapSizeGiB}G";
    content = {
      type = "swap";
      resumeDevice = true;
      # fstrim(8) walks mounted filesystems and never touches a swap
      # partition, so swapon's own discard is the only thing that ever trims
      # this area — and with the fstrim timer off below, the only thing at
      # all. "once" does it at swapon and then leaves the device alone,
      # rather than issuing a discard on every page freed.
      discardPolicy = "once";
    };
  };

  rootPartition = {
    size = "100%";
    content = {
      type = "filesystem";
      format = "btrfs";
      mountpoint = "/";
      mountOptions = [
        # compress-force, not compress. btrfs's heuristic samples the *first*
        # blocks of a file and, if they look incompressible, marks the whole
        # file to skip compression permanently. For an ELF binary behind an
        # incompressible header that is the wrong call, made once, for the
        # life of the file — and a Nix store is mostly ELF. Forcing it only
        # costs attempts: btrfs still stores an extent raw whenever
        # compressing it would not be smaller.
        #
        # This is a mount option, so it takes effect on remount. Files
        # already written keep the extents they have until they are rewritten.
        "compress-force=zstd:3"
        # Release extents as they are freed rather than walking the whole
        # filesystem on a timer. See services.fstrim below, which this
        # replaces.
        "discard=async"
        "noatime"
      ];
      # No -d/-m here, so mkfs.btrfs picks its own: single data, DUP
      # metadata. DUP is worth keeping on a machine whose job is to hold
      # other people's work — and it is also why max_inline is left at its
      # 2048 default rather than raised. Inline data lives in metadata, so
      # under DUP every inlined byte is written twice and anything past ~2 KB
      # costs more inlined than it would as a plain block.
      extraArgs = [
        "-L"
        "root"
      ];
    };
  };

  # Ordering is disko's job, not the attribute names': it sorts by each
  # partition's `priority`, which defaults to 9001 for size = "100%". Root is
  # therefore created last whether or not swap is present, so dropping the
  # swap partition at swapSizeGiB = 0 needs nothing else.
  diskPartitions =
    optionalAttrs (cfg.swapSizeGiB > 0) {
      swap = swapPartition;
    }
    // {
      root = rootPartition;
    };
in
{
  # ── Disk layout (disko) ─────────────────────────────────────
  # This declares the whole table, so it expects to own the disk. Note that
  # it is install-time only: changing swapSizeGiB or the mkfs arguments does
  # not repartition or reformat a machine that is already running. Mount
  # options do apply on the next mount.
  disko.devices = mkDefault {
    disk.main = {
      device = cfg.diskDevice;
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [
                "noatime"
                "umask=0077"
              ];
              extraArgs = [
                "-n"
                "ESP"
              ];
            };
          };
        }
        // diskPartitions;
      };
    };
  };

  # Off, and switched off rather than merely not switched on, because NixOS
  # enables it by default. The root filesystem carries discard=async above,
  # which releases extents as they are freed; running both means doing the
  # same job twice, and the batched whole-filesystem pass is precisely the
  # multi-second stall the async policy exists to avoid. Note this is also
  # why the swap partition carries discardPolicy = "once": fstrim only ever
  # walked mounted filesystems, so swap was never covered by it even when it
  # did run.
  services.fstrim.enable = mkDefault false;

  # ── Block layer ─────────────────────────────────────────────
  # The kernel's default is mq-deadline for everything, which is right for
  # the SATA and eMMC devices this box might have and wrong for NVMe.
  #
  # Only the NVMe rule is here, and that is a deliberate departure from the
  # sibling desktop configuration this module borrows from. That one puts BFQ
  # under every non-NVMe disk, because BFQ is the one scheduler that will
  # hold a background writer off the head long enough for an interactive read
  # to land. BFQ also spends CPU per request and measurably lowers peak
  # sequential throughput — a trade a desktop should make and a machine doing
  # bulk I/O should not.
  #
  # The one thing that would argue for BFQ here: it is the only mq scheduler
  # that implements io.weight, so systemd's IOWeight= is decorative without
  # it. The guards in nix.nix deliberately do not use IOWeight for exactly
  # that reason — throttling the build host's disk is not the goal.
  #
  # KERNEL= is not restricted on the queue-attribute match beyond the NVMe
  # name itself: a partition has no queue/ directory, so it simply fails the
  # match.
  services.udev.extraRules = ''
    # NVMe reorders in hardware across deep queues; a software scheduler in
    # front of it is pure overhead.
    ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
  '';

  # ── zswap ───────────────────────────────────────────────────
  # No native NixOS module for this, so it's plain kernel command line. A
  # RAM-resident compressed pool in front of the swap partition above: pages
  # get compressed into it first and only spill to the partition once the
  # pool is full, so the partition is reached under real pressure rather
  # than on every swap-out. Gated on the same condition as the partition
  # itself — with no backing device, zswap has nothing to spill into once
  # its pool fills, which just moves the OOM kill earlier.
  #
  # zstd, not the lz4 a CPU-constrained desktop would pick. For swap the
  # number that matters is how long a fault takes to come back, and lz4
  # decompresses several times faster — but that argument is about a
  # scarce core. There is no scarce core here: this is the machine whose
  # job is compiling, cores are the resource it has plenty of, and the
  # better ratio means more anonymous memory fits in the RAM-resident pool
  # before anything reaches the disk partition — the same trade the old
  # zram tier made, kept across the move to zswap.
  #
  # zsmalloc is the only allocator left as of 6.10 (z3fold and zbud were
  # both removed) — named explicitly rather than left to whatever the
  # kernel still defaults to.
  boot.kernelParams = mkIf (cfg.swapSizeGiB > 0) [
    "zswap.enabled=1"
    "zswap.compressor=zstd"
    "zswap.zpool=zsmalloc"
    "zswap.max_pool_percent=20"
    "zswap.shrinker_enabled=1"
  ];
}
