# Clang/LLVM toolchain helpers for building the kernel with ThinLTO.
# Adapted from xddxdd/nix-cachyos-kernel (helpers.nix, GPL-2.0),
# which credits nixpkgs PR #129806 and lovesegfault/nix-config.
{ pkgs, lib, ... }:
rec {
  noBintools = {
    bootBintools = null;
    bootBintoolsNoLibc = null;
  };
  hostLLVM = pkgs.pkgsBuildHost.llvmPackages.override noBintools;
  buildLLVM = pkgs.pkgsBuildBuild.llvmPackages.override noBintools;

  ltoMakeflags = [
    "LLVM=1"
    "LLVM_IAS=1"
    "CC=${buildLLVM.clangUseLLVM}/bin/clang"
    "LD=${buildLLVM.lld}/bin/ld.lld"
    "HOSTLD=${hostLLVM.lld}/bin/ld.lld"
    "AR=${buildLLVM.llvm}/bin/llvm-ar"
    "HOSTAR=${hostLLVM.llvm}/bin/llvm-ar"
    "NM=${buildLLVM.llvm}/bin/llvm-nm"
    "STRIP=${buildLLVM.llvm}/bin/llvm-strip"
    "OBJCOPY=${buildLLVM.llvm}/bin/llvm-objcopy"
    "OBJDUMP=${buildLLVM.llvm}/bin/llvm-objdump"
    "READELF=${buildLLVM.llvm}/bin/llvm-readelf"
    "HOSTCC=${hostLLVM.clangUseLLVM}/bin/clang"
    "HOSTCXX=${hostLLVM.clangUseLLVM}/bin/clang++"
    "NIX_CC_WRAPPER_SUPPRESS_TARGET_WARNING=1"
  ];

  stdenvLLVM =
    let
      mkLLVMPlatform =
        platform:
        platform
        // {
          linux-kernel = (platform.linux-kernel or { }) // {
            makeFlags = (platform.linux-kernel.makeFlags or [ ]) ++ ltoMakeflags;
          };
        };
      stdenv' = pkgs.overrideCC hostLLVM.stdenv hostLLVM.clangUseLLVM;
    in
    stdenv'.override (old: {
      hostPlatform = mkLLVMPlatform stdenv'.hostPlatform;
      buildPlatform = mkLLVMPlatform stdenv'.buildPlatform;
      extraNativeBuildInputs = [
        hostLLVM.lld
        pkgs.patchelf
      ];
    });

  # Out-of-tree modules (nvidia, etc.) must be built with the same
  # compiler as the kernel. Their Makefiles often hard-code gcc.
  kernelModuleLLVMOverride =
    kernelPackages_:
    kernelPackages_.extend (
      _final: prev:
      lib.mapAttrs (
        n: v:
        if
          builtins.elem "LLVM=1" kernelPackages_.kernel.commonMakeFlags
          && n != "kernel"
          && lib.isDerivation v
          && ((v.overrideAttrs or null) != null)
        then
          v.overrideAttrs (old: {
            postPatch = (if (old.postPatch or null) == null then "" else old.postPatch) + ''
              if [ -f Makefile ]; then
                substituteInPlace Makefile --replace-quiet "gcc" "cc"
              fi
            '';
          })
        else
          v
      ) prev
    );
}
