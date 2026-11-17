# optimized-kernel

A Linux kernel for NixOS, fitted to one PC and re-fitted on every new release.

Built for: Intel Core Ultra 9 285K (Arrow Lake, 24 threads), NVIDIA RTX 5080 (open driver) + Intel iGPU, NVMe, Realtek 2.5 GbE, Intel Wi-Fi.
The CPU and thread count are recorded in `hardware/profile.json`.

## What it does

| Step | What | Why |
|---|---|---|
| Source | CachyOS-patched kernel release ([CachyOS/linux](https://github.com/CachyOS/linux)) + BORE scheduler patch ([CachyOS/kernel-patches](https://github.com/CachyOS/kernel-patches)) | CachyOS's desktop patches and scheduler |
| Base config | `linux-cachyos-bore/config` from [CachyOS/linux-cachyos](https://github.com/CachyOS/linux-cachyos) | CachyOS's tested defaults |
| Trim | `localmodconfig` keeps only modules this PC loads or NixOS's initrd needs, then whole safety groups are put back (`hardware/safety-kconfig.txt`) | About 2,400 modules instead of about 7,500: faster builds, smaller kernel |
| CPU | `-march=native` (`X86_NATIVE_CPU`), Intel-only CPU support, `NR_CPUS` = this PC's thread count | Code for exactly this CPU |
| Compiler | Clang ThinLTO, `-O3` | Same as CachyOS's LTO kernels |
| Timing | BORE, 1000 Hz, full tickless, full dynamic preemption, THP always, ADIOS I/O scheduler | Desktop responsiveness |

The settings are in `kernel/settings.nix`; the build pipeline is in `kernel/default.nix`.

## GPU driver

`nvidia/` builds NVIDIA's driver for this PC's RTX 5080 (Blackwell GB203) from [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules), at NVIDIA's newest Linux release (`nvidia/sources.json`, from `download.nvidia.com/.../latest.txt`), not the version nixpkgs ships.

| Step | What | Why |
|---|---|---|
| Release | userspace (`.run`) + open kernel modules + nvidia-settings + nvidia-persistenced of the same version, through nixpkgs' `nvidiaPackages.mkDriver` | newest Blackwell fixes and CUDA without waiting for nixpkgs |
| Compiler | the kernel-facing layer builds with this kernel's Clang, `-O3`, `-march=native`; NVIDIA's core keeps NVIDIA's own flags (`-O2`, no SSE) | kernel code may not use SSE; changing NVIDIA's core flags is not worth the risk |
| Firmware | only `gsp_ga10x` / `ucodes_ga10x` are declared (Ampere and newer; the source maps GB20X to them); the Turing `tu10x` files stay out of the initrd | about 30 MB less per boot entry on a 1 GB `/boot`; the build stops if a release maps Blackwell to other firmware |
| Modules | `nvidia-peermem` (InfiniBand GPUDirect) is not built | no InfiniBand here |

In a NixOS config: `hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.optimized or config.boot.kernelPackages.nvidiaPackages.latest;` (the `or` keeps nixpkgs' driver for fallback kernels).

### Safety groups

Modules in these groups stay built even if the PC has not used them yet: all filesystems (NTFS, exFAT, ISO…), the firewall and container networking, VPNs (WireGuard, tun), Wi-Fi/Bluetooth stacks, USB storage/serial/network adapters, input devices and game controllers, webcams, USB audio, SD cards, disk encryption, KVM/VFIO, sensors, and Intel/Realtek network cards.
Not built: drivers for hardware this PC does not have, such as AMD and nouveau GPUs, other vendors' network cards, RAID/SCSI controllers, TV tuners and staging drivers.
Edit `hardware/safety-kconfig.txt` to add a group.

## Use it in a NixOS flake

```nix
inputs.optimized-kernel.url = "github:zenmastercat/optimized-kernel";
# no "follows": it keeps its own nixpkgs pin for a matching Clang and NVIDIA driver

nixpkgs.overlays = [ inputs.optimized-kernel.overlays.default ];
boot.kernelPackages = pkgs.linuxPackages_optimized;
```

Keep another kernel as a boot-menu fallback (a `specialisation`), since a trimmed kernel can lack a driver for a device you plug in later.

## Update

```sh
nix run .#update -- --nixos-flake /path/to/nixos-config --build --commit --push
```

Each run:

1. **Re-checks the PC.** CPU model, thread count and currently loaded modules; with `--nixos-flake`, the initrd's modules. Newly seen modules are added to the keep list, and nothing is ever removed from it. If the CPU model changed, it stops (use `--accept-new-cpu`).
2. **Finds the newest stable CachyOS release** that has a BORE patch, and notes when kernel.org already has a newer version that CachyOS has not released yet.
3. **Pins the newest BORE patch and CachyOS config**, and moves `nixpkgs` forward (newer Clang and NVIDIA driver). Use `--no-nixpkgs` to keep it.
4. **Follows NVIDIA's newest release** and pins the hashes of its four sources; if one is not published yet, it waits for the next run.
5. **`--build`** builds the kernel, the NVIDIA driver and, with `--nixos-flake`, the whole system, then checks that every setting in `kernel/settings.nix` has its value in the final config and lists modules this PC used that the new kernel lacks. On failure, every file is put back.
6. **`--commit` / `--push`** records a passing update in git.

The last line printed is a JSON summary. Build logs are in `~/.cache/optimized-kernel/`.

After an update, in the NixOS config: `nix flake update optimized-kernel`, then `nixos-rebuild switch`.

Since the kernel is built with `-march=native`, build it on this PC (or the same CPU model).

## Credits and license

The Clang/LTO helpers and the overall approach are adapted from [xddxdd/nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel) (GPL-2.0). Kernel patches and config come from the [CachyOS](https://github.com/CachyOS) project.
This repository is GPL-2.0 (see `LICENSE`).
