# Native single-derivation package; the Zig build graph owns source selection and installation.
# GMP uses generic mpn sources with NO_ASM; -Dcpu=baseline affects Zig codegen.

{ lib, stdenv, zig, linkage ? "static" }:

assert lib.assertMsg (linkage == "static" || linkage == "dynamic")
  "gmp: linkage must be \"static\" or \"dynamic\", got \"${toString linkage}\"";

assert lib.assertMsg (stdenv.hostPlatform.system == stdenv.buildPlatform.system)
  "gmp: this derivation does not cross-compile; run the build graph directly for a target";

stdenv.mkDerivation {
  pname = "gmp";

  version =
    let
      stamp = builtins.readFile ./doc/version.texi;
      lines = lib.filter (line: lib.hasPrefix "@set VERSION " line)
        (lib.splitString "\n" stamp);
    in
    lib.removePrefix "@set VERSION " (lib.head lines);

  src = lib.cleanSourceWith {
    src = ./.;
    filter =
      path: type:
      let name = baseNameOf (toString path);
      in
      name != "result"
      && !(lib.hasPrefix "result-" name)
      && !(builtins.elem name [
        ".git"
        ".zig-cache"
        "zig-cache"
        "zig-out"
        "zig-pkg"
        ".devenv"
        ".devenv.flake.nix"
        ".direnv"
      ]);
  };

  strictDeps = true;
  nativeBuildInputs = [ zig ];

  # Keep install enabled: zig build install performs the complete build.
  dontConfigure = true;
  dontBuild = true;
  dontCheck = true;
  dontUseZigCheck = true;

  installPhase = ''
    runHook preInstall

    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"

    zig build install \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Dcpu=baseline \
      -Doptimize=ReleaseFast \
      -Dlinkage=${linkage}

    runHook postInstall
  '';

  passthru.linkage = linkage;

  meta = {
    description = "GNU Multiple Precision Arithmetic Library, built from vendored sources with Zig";
    # Select LGPLv3-or-later; NOTICE.md inventories per-file terms.
    license = lib.licenses.lgpl3Plus;
    platforms = lib.platforms.unix;
  };
}