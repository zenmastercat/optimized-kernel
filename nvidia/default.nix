# NVIDIA driver for this PC's GPU (RTX 5080, Blackwell GB203), built from
# github.com/NVIDIA/open-gpu-kernel-modules at the newest NVIDIA release
# (version and hashes in ./sources.json, kept current by scripts/update.py).
#
# - Userspace (libcuda, Vulkan, GL, nvidia-smi) and the open kernel modules
#   come from the same release, through nixpkgs' nvidiaPackages.mkDriver.
# - The kernel-facing part is compiled by this repo's kernel build system,
#   so it gets the kernel's Clang, -O3 and -march=native. NVIDIA's core
#   (src/) keeps NVIDIA's own flags (-O2, no SSE), as kernel code requires.
# - Fitted to the GPU: only Ampere-and-newer firmware (gsp_ga10x,
#   ucodes_ga10x) is declared, so the initrd skips ~30 MB of Turing-only
#   firmware; nvidia-peermem (InfiniBand only) is not built.
{ lib, nvidiaPackages }:
let
  src' = lib.importJSON ./sources.json;

  base = nvidiaPackages.mkDriver {
    inherit (src')
      version
      sha256_64bit
      openSha256
      settingsSha256
      persistencedSha256
      ;
  };

  open = base.open.overrideAttrs (old: {
    pname = "nvidia-open-optimized";

    postPatch = (old.postPatch or "") + ''
      h=kernel-open/common/inc/nv-firmware.h

      # Stop if this release no longer maps Blackwell (GB20X) to the
      # ga10x firmware: the trim below would then be wrong.
      gsp=$(awk '/NV_FIRMWARE_CHIP_FAMILY_GB20X:/ {f=1} f && /NV_FIRMWARE_TYPE_GSP:/ {print; exit}' "$h")
      case "$gsp" in
        *'"gsp_ga10x"'*) ;;
        *) echo "optimized-kernel: GB20X no longer uses gsp_ga10x in $h; review the firmware trim" >&2; exit 1 ;;
      esac
      grep -q 'NV_FIRMWARE_DECLARE_GSP("gsp_ga10x")' "$h"
      grep -q 'NV_FIRMWARE_DECLARE_GSP("ucodes_ga10x")' "$h"

      # Declare only the firmware this GPU loads.
      sed -i \
        -e '/NV_FIRMWARE_DECLARE_GSP("gsp_tu10x")/d' \
        -e '/NV_FIRMWARE_DECLARE_GSP("ucodes_tu10x")/d' \
        "$h"
    '';

    makeFlags = (old.makeFlags or [ ]) ++ [
      "NV_EXCLUDE_KERNEL_MODULES=nvidia-peermem"
    ];

    meta = old.meta // {
      description = "NVIDIA open GPU kernel modules ${src'.version}, fitted to an RTX 5080";
    };
  });
in
base.overrideAttrs (old: {
  passthru = old.passthru // {
    inherit open;
  };
})
