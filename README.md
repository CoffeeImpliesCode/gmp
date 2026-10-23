# GMP

GMP 6.3.0 is packaged for Zig 0.16 as a dependency.
It publishes a Zig module and C-library artifact named `gmp`.

## Source deviations from upstream

No file in the GMP 6.3.0 source tree is patched. The fork adds the Zig facade, runtime loader, build graph, tests, example and package files.

## Build deviations from upstream

- The Zig build replaces `configure` and `make`. It derives configuration from the target and writes `config.h`, `gmp.h`, and generated tables to the build cache.
- The library uses GMP's portable C `mpn` backend with `NO_ASM`, which is slower than GMP's tuned assembly. It omits 29 internal `mpn` functions that have no generic C source, as an upstream generic build does.
- In non-Debug modes, the build disables the C `function` sanitizer for GMP sources because GMP's `printf` dispatch uses incompatible function-pointer types. Other C undefined-behaviour checks and Zig safety checks remain enabled.
- The build compiles this package's tests and example with `libgmp`. It does not build `libgmpxx`, `mini-gmp`, the upstream test suite, or upstream demos.
- `-Dlinkage=static` is the default. `-Dlinkage=dynamic` builds a shared library with GMP's libtool version and soname.
- `-Druntime=true` builds the facade's runtime-loading route. It does not link `libgmp`; the program must name a provider and call `gmp.load` before using GMP.
- `-fsys=gmp` uses an installed GMP and publishes the `gmp` module without a `gmp` artifact. This mode cannot be combined with `-Druntime=true`.

## Support matrix

`zig build check` compiles the facade, tests, and example for these configured targets. It does not run cross-compiled binaries.

| Target | Build configuration |
| --- | --- |
| `x86_64-linux-gnu` | Portable C backend with target-derived ABI and headers. |
| `aarch64-linux-gnu` | Portable C backend with target-derived ABI and headers. |
| `aarch64-macos-none` | Portable C backend with target-derived ABI and headers. |
| `x86_64-windows-gnu` | Portable C backend with LLP64 limb type and target-derived headers. |
| `riscv64-linux-gnu` | Portable C backend with target-derived ABI and headers. |
| `wasm32-wasi` | 32-bit limbs. Enables `_WASI_EMULATED_SIGNAL` and links `wasi-emulated-signal`. |

## Consumption

### `build.zig.zon`

For a local checkout at `../gmp`, add this dependency:

```zig
.dependencies = .{
    .gmp = .{ .path = "../gmp" },
},
```

### `build.zig`

Import the facade module in a Zig consumer:

```zig
const gmp_dep = b.dependency("gmp", .{ .target = target, .optimize = optimize });
module.addImport("gmp", gmp_dep.module("gmp"));
```

`dep.module("gmp")` provides the Zig facade and translated C API. `dep.artifact("gmp")` provides `libgmp` with generated `gmp.h`, `gmp-mparam.h`, and `gmp_all.h` for C consumers.

### Build options

- `-Dlinkage=static|dynamic` selects the bundled library form. Static is the default. With `-fsys=gmp`, the default system-library preference is dynamic.
- `-Druntime=true|false` selects runtime loading or direct linkage. The default is `false`. Runtime loading requires a named provider and a call to `gmp.load`.
- `-fsys=gmp` links an installed library instead of compiling this tree. It is a Zig system-library option, not a package build option.
- `-Dtarget` and `-Doptimize` use Zig's standard build options.

Nix outputs are `.#static`, `.#shared`, and `.#default` (static). `nix develop` provides the development tools without building the library.
