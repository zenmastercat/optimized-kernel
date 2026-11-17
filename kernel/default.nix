# Builds the optimized kernel and its linuxPackages set.
# Pipeline: CachyOS-patched source + BORE patch -> CachyOS config
#   -> trimmed to this PC's modules (+ safety groups) -> tuned -> Clang ThinLTO build.
{
  pkgs,
  lib,
  # Set false to build every module CachyOS enables (slower, no trimming).
  trimModules ? true,
  # Extra structured kernel options that win over everything else.
  extraConfig ? { },
}:
let
  helpers = import ./helpers.nix { inherit pkgs lib; };
  inherit (helpers) stdenvLLVM ltoMakeflags kernelModuleLLVMOverride;

  src' = lib.importJSON ./sources.json;
  profile = lib.importJSON ../hardware/profile.json;
  settings = import ./settings.nix { inherit lib profile; };

  version = src'.version;
  localVersion = "-optimized";
  modDirVersion = "${lib.versions.pad 3 version}${localVersion}";

  cachyosSrc = pkgs.fetchurl { inherit (src'.source) url hash; };
  borePatch = pkgs.fetchurl { inherit (src'.bore) url hash; };
  cachyosConfig = pkgs.fetchurl { inherit (src'.config) url hash; };

  # Patched source, without the final config.
  baseSrc = pkgs.applyPatches {
    name = "linux-optimized-src-${version}";
    src = cachyosSrc;
    patches = [
      pkgs.kernelPatches.bridge_stp_helper.patch
      pkgs.kernelPatches.request_key_helper.patch
      borePatch
    ];
  };

  keepModules = ../hardware/keep-modules.txt;
  safetyKconfig = ../hardware/safety-kconfig.txt;

  # localmodconfig keeps only modules on the keep list (loaded + initrd),
  # then every module under the safety Kconfig paths that CachyOS enables
  # is switched back on. Built-in (=y) options are never touched.
  trimmedConfig = stdenvLLVM.mkDerivation {
    name = "linux-optimized-config-${version}";
    src = baseSrc;
    nativeBuildInputs = with pkgs; [
      perl
      bison
      flex
      bc
      python3
    ];
    dontConfigure = true;
    makeFlags = ltoMakeflags;
    buildPhase = ''
      runHook preBuild
      cp ${cachyosConfig} .config
      ${lib.optionalString trimModules ''
        cp .config .config.full
        make $makeFlags LSMOD=${keepModules} localmodconfig < /dev/null 2> localmod.log || {
          cat localmod.log; exit 1; }
        python3 ${./reenable-safety.py} .config.full .config ${safetyKconfig} > reenable.txt
        xargs -r -a reenable.txt bash scripts/config --file .config
        make $makeFlags olddefconfig
      ''}
      runHook postBuild
    '';
    installPhase = ''
      cp .config $out
    '';
  };

  finalSrc = pkgs.runCommand "linux-optimized-src-final-${version}" { } ''
    cp -r ${baseSrc} $out
    chmod -R u+w $out
    install -Dm644 ${trimmedConfig} $out/arch/x86/configs/optimized_defconfig
  '';

  structuredExtraConfig =
    (with lib.kernel; {
      LOCALVERSION = freeform localVersion;
      LOCALVERSION_AUTO = no;
    })
    // lib.mapAttrs (_: lib.mkForce) (
      settings.cachy
      // settings.bore
      // settings.lto
      // settings.cpu
      // settings.timing
      // settings.perf
      // settings.nixos
    )
    // extraConfig;

  kernel = pkgs.buildLinux {
    pname = "linux-optimized";
    inherit version modDirVersion structuredExtraConfig;
    src = finalSrc;
    defconfig = "optimized_defconfig";
    # Native CPU code generation (-march=native) and LLVM toolchain.
    stdenv = pkgs.stdenvAdapters.impureUseNativeOptimizations stdenvLLVM;
    extraMakeFlags = ltoMakeflags;
    # Do not turn every disabled driver back into a module: that would undo the trim.
    autoModules = !trimModules;
    # CachyOS's config lists options that some versions do not have.
    ignoreConfigErrors = true;
    extraMeta = {
      description = "Linux ${version} (CachyOS + BORE), Clang ThinLTO, -march=native, trimmed to one PC";
      platforms = [ "x86_64-linux" ];
    };
    extraPassthru = {
      inherit trimmedConfig baseSrc;
      cachyosRelease = src'.source.tag;
    };
  };

  linuxPackages = kernelModuleLLVMOverride (
    (pkgs.linuxPackagesFor kernel).extend (
      final: prev: {
        # VirtualBox and VMware host modules ignore the kernel's make flags.
        virtualbox = prev.virtualbox.overrideAttrs (old: {
          makeFlags = (old.makeFlags or [ ]) ++ final.kernel.commonMakeFlags;
        });
        vmware = prev.vmware.overrideAttrs (old: {
          makeFlags = (old.makeFlags or [ ]) ++ final.kernel.commonMakeFlags;
        });
      }
    )
  );
in
{
  inherit kernel linuxPackages trimmedConfig;
}
