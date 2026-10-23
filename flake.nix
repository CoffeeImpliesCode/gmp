{
  description = "GMP 6.3.0 built from vendored sources with Zig, as static and shared variants";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system: f nixpkgs.legacyPackages.${system}
        );
    in
    {
      # Expose static/shared variants; static is the default.
      packages = forAllSystems (pkgs: {
        static = pkgs.callPackage ./package.nix { zig = pkgs.zig_0_17; };
        shared = pkgs.callPackage ./package.nix {
          zig = pkgs.zig_0_17;
          linkage = "dynamic";
        };
        default = pkgs.callPackage ./package.nix { zig = pkgs.zig_0_17; };
      });

      # Tools-only shell; package derivations remain lazy.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_17
            pkgs.pkg-config
          ];
        };
      });
    };
}