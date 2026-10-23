# Tools-only environment; outputs build static/shared derivations lazily.
# Tasks run from the SDK or consumer root; build caches and install prefixes stay outside the checkout.
{ pkgs, lib, ... }:
let
  version =
    let
      stamp = builtins.readFile ./doc/version.texi;
      lines = lib.filter (line: lib.hasPrefix "@set VERSION " line)
        (lib.splitString "\n" stamp);
    in
    lib.removePrefix "@set VERSION " (lib.head lines);

  gmpPackage =
    { linkage ? "static" }:
    pkgs.callPackage ./package.nix { zig = pkgs.zig_0_16; inherit linkage; };

  # Quote roots so spaces remain one shell argument.
  sdkRoot = builtins.toString ./.;
  sdkRootArg = lib.escapeShellArg sdkRoot;
  consumerRootArg = lib.escapeShellArg (sdkRoot + "/consumer");

  inSdk = "cd ${sdkRootArg} || exit 1";
  inConsumer = "cd ${consumerRootArg} || exit 1";

  # Respect exported caches; otherwise use XDG_CACHE_HOME, then TMPDIR.
  requireExternalCache = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ] && [ -n "''${XDG_CACHE_HOME:-}" ]; then
      export ZIG_LOCAL_CACHE_DIR="''${XDG_CACHE_HOME}/foundation-libs/gmp/zig-local-cache"
    fi
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ] && [ -n "''${TMPDIR:-}" ]; then
      export ZIG_LOCAL_CACHE_DIR="''${TMPDIR}/zig-local-cache"
    fi
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      echo "gmp devenv: ZIG_LOCAL_CACHE_DIR is unset, and neither XDG_CACHE_HOME" >&2
      echo "nor TMPDIR names scratch either, so there is nowhere approved outside" >&2
      echo "this checkout for build state. Export one of them and run again." >&2
      exit 1
    fi
    if [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ] && [ -n "''${XDG_CACHE_HOME:-}" ]; then
      export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME}/foundation-libs/gmp/zig-global-cache"
    fi
    if [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ] && [ -n "''${TMPDIR:-}" ]; then
      export ZIG_GLOBAL_CACHE_DIR="''${TMPDIR}/zig-global-cache"
    fi
    if [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      echo "gmp devenv: ZIG_GLOBAL_CACHE_DIR is unset, and neither XDG_CACHE_HOME" >&2
      echo "nor TMPDIR names scratch either. Export one of them and run again." >&2
      exit 1
    fi
    mkdir -p "''${ZIG_LOCAL_CACHE_DIR}" "''${ZIG_GLOBAL_CACHE_DIR}"
  '';
in
{
  packages = [
    pkgs.zig_0_16
    pkgs.pkg-config
  ];

  outputs = {
    static = gmpPackage { };
    shared = gmpPackage { linkage = "dynamic"; };
    default = gmpPackage { };
  };

  env.GMP_FORK_VERSION = version;

  tasks = {
    "sdk:build" = {
      description = "Install libgmp, the example and the licence records into $ZIG_LOCAL_CACHE_DIR";
      exec = ''
        ${inSdk}
        ${requireExternalCache}
        zig build install --prefix "''${ZIG_LOCAL_CACHE_DIR}/gmp-prefix" --cache-dir "''${ZIG_LOCAL_CACHE_DIR}/gmp" -j8 --summary all
      '';
    };
    "sdk:test" = {
      description = "Run the test suite in Debug";
      exec = ''
        ${inSdk}
        ${requireExternalCache}
        zig build test -Doptimize=Debug --cache-dir "''${ZIG_LOCAL_CACHE_DIR}/gmp" -j8 --summary all
      '';
    };
    "sdk:test-release-safe" = {
      description = "Run the test suite in ReleaseSafe";
      exec = ''
        ${inSdk}
        ${requireExternalCache}
        zig build test -Doptimize=ReleaseSafe --cache-dir "''${ZIG_LOCAL_CACHE_DIR}/gmp" -j8 --summary all
      '';
    };
    "sdk:smoke" = {
      description = "Run the self-checking example; its run step installs, so a prefix is named";
      exec = ''
        ${inSdk}
        ${requireExternalCache}
        # The smoke run installs, so keep its prefix outside the checkout.
        zig build smoke --prefix "''${ZIG_LOCAL_CACHE_DIR}/gmp-prefix" --cache-dir "''${ZIG_LOCAL_CACHE_DIR}/gmp" -j8 --summary all
      '';
    };
    "sdk:check" = {
      description = "Compile the public surface for the six supported targets";
      exec = ''
        ${inSdk}
        ${requireExternalCache}
        # Check compiles without running or installing.
        zig build check --cache-dir "''${ZIG_LOCAL_CACHE_DIR}/gmp" -j8 --summary all
      '';
    };
    "sdk:provenance" = {
      description = "Run the licence and provenance gate";
      exec = ''
        ${inSdk}
        # Provenance checks source records without a compiler or build cache.
        sh tools/provenance_gate.sh .
      '';
    };
    "sdk:consumer" = {
      description = "Run the separate consumer package";
      exec = ''
        ${inConsumer}
        ${requireExternalCache}
        # Keep the consumer cache and install prefix outside the checkout.
        zig build run --prefix "''${ZIG_LOCAL_CACHE_DIR}/gmp-consumer-prefix" --cache-dir "''${ZIG_LOCAL_CACHE_DIR}/gmp-consumer" -j8 --summary all
      '';
    };
  };
}