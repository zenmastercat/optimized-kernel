{
  description = "Linux kernel tuned for one PC: CachyOS + BORE, Clang ThinLTO, -march=native, trimmed modules, auto-tracked";

  inputs = {
    # Own pin, so the update script can move the toolchain and NVIDIA driver
    # forward together with the kernel. Do not make it follow another nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true; # NVIDIA driver modules
      };
      built = import ./kernel { inherit pkgs lib; };
    in
    {
      packages.${system} = {
        kernel = built.kernel;
        config = built.trimmedConfig;
        nvidia-open = built.linuxPackages.nvidiaPackages.latest.open;
        default = built.kernel;
      };

      legacyPackages.${system}.linuxPackages = built.linuxPackages;

      # Adds pkgs.linuxPackages_optimized, built with this flake's own nixpkgs.
      overlays.default = _final: _prev: {
        linuxPackages_optimized = built.linuxPackages;
      };

      apps.${system}.update = {
        type = "app";
        program = lib.getExe (
          pkgs.writeShellApplication {
            name = "optimized-kernel-update";
            # Uses the system's own nix on PATH.
            runtimeInputs = with pkgs; [
              python3
              git
            ];
            text = ''exec python3 -I ${./scripts/update.py} "$@"'';
          }
        );
      };

      formatter.${system} = pkgs.nixfmt-rfc-style;
    };
}
