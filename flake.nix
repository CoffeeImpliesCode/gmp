{
  description = "GMP 6.3.0 built from vendored sources with Zig, as static and shared variants";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";

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
        static = pkgs.callPackage ./package.nix { zig = pkgs.zig_0_16; };
        shared = pkgs.callPackage ./package.nix {
          zig = pkgs.zig_0_16;
          linkage = "dynamic";
        };
        default = pkgs.callPackage ./package.nix { zig = pkgs.zig_0_16; };
      });

      # Tools-only shell; package derivations remain lazy.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_16
            pkgs.pkg-config
          ];
        };
      });
    };
}