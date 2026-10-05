# Canonical development environment: tools only, so entering the shell never
# builds libgmp. `outputs` is lazy — `devenv build outputs.static` and
# `devenv build outputs.shared` build the same derivation package.nix returns.
#
# nixpkgs is pinned in devenv.yaml and the lock file belongs to the driver.
#
# Every task settles three things for itself before it reaches the compiler:
# which directory it runs in, where its build cache goes, and how many jobs it
# takes. None of the three is taken from the caller's working directory.
#
# The directory is `sdkRoot`, this file's own `./.` rendered as a plain string.
# A task is materialised as a generated shell program that inherits the caller's
# working directory, and that directory is not this tree: a shell entered as
# `--from path:<this SDK>` starts in the project directory, which holds no
# `build.zig`, no `tools/` and no `consumer/`. `builtins.toString` rather than an
# interpolated path literal, because the interpolated form asks Nix for a
# read-only copy of this whole tree in the store, and a copy is not the tree the
# provenance gate checksums and the consumer's path dependency names.
#
# The cache is `--cache-dir`, always named, never this SDK's own default beside
# `build.zig`. A value the caller already exported wins: `ZIG_LOCAL_CACHE_DIR`
# when it is set, otherwise one filled here from `XDG_CACHE_HOME`, otherwise
# from `TMPDIR`; with none of those there is no approved location outside this
# checkout, so the body says so and stops rather than choosing one. The same
# order fills `ZIG_GLOBAL_CACHE_DIR`. No host path, account or mount is written
# into this file, and the fill runs in the task body itself rather than only in a
# shell hook, because `devenv tasks run` never runs a hook.
#
# `-j8` and `--summary all` are this workspace's gate convention and both are
# named on every build below. No body forwards `"$@"`, which is what these
# commands have always been: each names its own step, its own optimize mode and
# its own cache. A caller who wants a different one runs `zig build` directly in
# this directory.
#
# `--prefix` is named only where the step really installs. `build.zig:238` makes
# the smoke run depend on the install step and `consumer/build.zig:142` does the
# same for the consumer's run, so those two carry a prefix beside `sdk:build`;
# `sdk:test` and `sdk:check` reach only compile and run steps
# (`build.zig:251`, `build.zig:333-336`) and name none.

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

  # This SDK's own directory, and the one shell-quoted word each body uses to
  # reach it. `lib.escapeShellArg` keeps a path holding a space or a quote a
  # single argument.
  sdkRoot = builtins.toString ./.;
  sdkRootArg = lib.escapeShellArg sdkRoot;
  consumerRootArg = lib.escapeShellArg (sdkRoot + "/consumer");

  inSdk = "cd ${sdkRootArg} || exit 1";
  inConsumer = "cd ${consumerRootArg} || exit 1";

  # The cache preamble every build body runs before the compiler, never after.
  # `$TMPDIR/zig-local-cache` and `$TMPDIR/zig-global-cache` are this SDK's
  # existing fallback names — the two `package.nix` exports under the
  # Nix-provided `TMPDIR` — so a body that has to fill one names the same place
  # the packaging route names.
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
        # No `--prefix`: the test binary is never installed (`build.zig:246-251`).
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
        # `--prefix` because `build.zig:238` makes this run depend on the install
        # step: without one, `zig build`'s own default writes `zig-out/` into
        # this checkout.
        zig build smoke --prefix "''${ZIG_LOCAL_CACHE_DIR}/gmp-prefix" --cache-dir "''${ZIG_LOCAL_CACHE_DIR}/gmp" -j8 --summary all
      '';
    };
    "sdk:check" = {
      description = "Compile the public surface for the six supported targets";
      exec = ''
        ${inSdk}
        ${requireExternalCache}
        # No `--prefix`: `check` compiles six targets and runs nothing
        # (`build.zig:333-336`), so it installs nothing.
        zig build check --cache-dir "''${ZIG_LOCAL_CACHE_DIR}/gmp" -j8 --summary all
      '';
    };
    "sdk:provenance" = {
      description = "Run the licence and provenance gate";
      exec = ''
        ${inSdk}
        # No cache preamble: this gate runs sha256sum, grep, sed, wc and cmp,
        # and reaches no compiler.
        sh tools/provenance_gate.sh .
      '';
    };
    "sdk:consumer" = {
      description = "Run the separate consumer package";
      exec = ''
        ${inConsumer}
        ${requireExternalCache}
        # `--prefix` because `consumer/build.zig:142` makes this run depend on
        # that package's install step, and the cache is named separately so the
        # consumer's `.zig-cache` is not this SDK's.
        zig build run --prefix "''${ZIG_LOCAL_CACHE_DIR}/gmp-consumer-prefix" --cache-dir "''${ZIG_LOCAL_CACHE_DIR}/gmp-consumer" -j8 --summary all
      '';
    };
  };
}