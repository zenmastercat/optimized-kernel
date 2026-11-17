# Kernel tuning. Values follow CachyOS's linux-cachyos-bore PKGBUILD
# defaults, plus options that fit this one PC (see ../hardware/profile.json).
{ lib, profile }:
with lib.kernel;
{
  # CachyOS base: CachyOS tweaks and the ADIOS I/O scheduler.
  cachy = {
    CACHY = yes;
    MQ_IOSCHED_ADIOS = yes;
  };

  # BORE scheduler (Burst-Oriented Response Enhancer) for desktop latency.
  bore = {
    SCHED_BORE = yes;
  };

  # Clang ThinLTO.
  lto = {
    LTO_NONE = no;
    LTO_CLANG_THIN = yes;
    LTO_CLANG_FULL = no;
  };

  # Compile for exactly the CPU that builds it (-march=native).
  # The update script refuses to build on a different CPU model.
  cpu = {
    GENERIC_CPU = no;
    X86_NATIVE_CPU = yes;
    # Only Intel CPU support code.
    CPU_SUP_AMD = no;
    CPU_SUP_HYGON = no;
    CPU_SUP_CENTAUR = no;
    CPU_SUP_ZHAOXIN = no;
    # Size per-CPU structures for this CPU's thread count.
    MAXSMP = no;
    CPUMASK_OFFSTACK = no;
    NR_CPUS = freeform (toString profile.nrCpus);
  };

  # 1000 Hz timer, tickless on busy CPUs, full (dynamic) preemption.
  timing = {
    HZ_300 = no;
    HZ_1000 = yes;
    HZ = freeform "1000";
    HZ_PERIODIC = no;
    NO_HZ_IDLE = no;
    CONTEXT_TRACKING_FORCE = no;
    NO_HZ_FULL_NODEF = yes;
    NO_HZ_FULL = yes;
    NO_HZ = yes;
    NO_HZ_COMMON = yes;
    CONTEXT_TRACKING = yes;
    PREEMPT_DYNAMIC = yes;
    PREEMPT = yes;
    PREEMPT_VOLUNTARY = no;
    PREEMPT_LAZY = no;
    PREEMPT_NONE = no;
  };

  # -O3 and transparent huge pages always on (CachyOS defaults).
  perf = {
    CC_OPTIMIZE_FOR_PERFORMANCE = no;
    CC_OPTIMIZE_FOR_PERFORMANCE_O3 = yes;
    TRANSPARENT_HUGEPAGE_MADVISE = no;
    TRANSPARENT_HUGEPAGE_ALWAYS = yes;
  };

  # NixOS needs these (same as nixpkgs and nix-cachyos-kernel).
  nixos = {
    OVERLAY_FS = module;
    OVERLAY_FS_REDIRECT_DIR = no;
    OVERLAY_FS_REDIRECT_ALWAYS_FOLLOW = yes;
    OVERLAY_FS_INDEX = no;
    OVERLAY_FS_XINO_AUTO = no;
    OVERLAY_FS_METACOPY = no;
    OVERLAY_FS_DEBUG = no;
    HID = yes;
    # BTF needs a newer pahole for Clang+LTO; it was also off in your old setup.
    DEBUG_INFO_BTF = no;
  };
}
