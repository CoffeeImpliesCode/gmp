# One derivation. `linkage` selects the variant; the entry points supply it.
# No flake, no sibling import, no host path, no build-time download.
# `zig build` owns the C flags, the source list, the generated headers and
# every installed artifact, header, licence record and pkg-config file, the
# fork's own records included, so this file writes no path of its own and no
# installed file has a second writer.
#
# `-Dtarget` is deliberately absent: this derivation is native (guarded below),
# so the build graph derives GMP's configuration from the host target.
# `-Dcpu=baseline` is declared and consumed by `b.standardTargetOptions`, which
# this build graph calls; it constrains Zig's own codegen, not GMP's mpn
# selection, which stays `generic` with `NO_ASM`.

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

  # Install only: `zig build install` is the single real build. dontInstall stays
  # unset, or the install phase below would never run.
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
    # Upstream offers LGPLv3 or later, or GPLv2 or later; this build selects the
    # LGPLv3 option. NOTICE.md is the per-file inventory.
    license = lib.licenses.lgpl3Plus;
    platforms = lib.platforms.unix;
  };
}