# Fork notes

## Source changes

No upstream GMP source file is modified.

| File | Change and reason |
|---|---|
| `include/gmp_all.h` | Includes `<stdarg.h>` and `<stdio.h>` before `gmp.h` to expose its gated declarations; adds guarded `mpn_*` aliases to their `__gmpn_*` symbols for translated calls; removes NetBSD's unused `__ALIGNBYTES` after preprocessing. |

## Build graph

- Replaces `configure` with target-derived configuration. Generates `gmp.h` from `gmp-h.in` and `config.h` from `config.in`, using the target's C data model, limb width, endianness, and optimization mode. `config.h` defines only true feature macros, including `WANT_TMP_ALLOCA` and the release version.
- Builds `libgmp` only; does not build `libgmpxx`, `mini-gmp`, upstream tests, or demos. The default is static. Dynamic mode uses PIC and GMP's libtool version and soname.
- Compiles the portable generic `mpn` source set: 180 C files and 16 wrappers for five multi-operation templates. It omits 29 functions with no generic C implementation, as GMP's generic configuration does. `NO_ASM` disables assembly on every target.
- Builds GMP's seven table generators for the host, then runs them with the target's limb and nail sizes. Generated headers, tables, and wrappers live in the Zig cache, not the source tree.
- Translates `include/gmp_all.h` to expose the complete C API. Aro handles most targets; NetBSD and OpenBSD use `zig cc -E -dD` first because Aro cannot parse parts of their system headers. A depfile tracks the headers read by that preprocessing step.
- Adds `-fno-sanitize=function` to GMP's native C sources outside Debug. Upstream's `printf` callback table casts incompatible function-pointer types; other C and Zig safety checks remain enabled.
- `-fsys=gmp` translates and links the installed GMP without building an artifact. It cannot be combined with `-Druntime=true`. The bundled runtime route uses a generated dispatch and does not link the library into the module; provider validation checks limb width.
- Renders `gmp.pc` with paths relative to its installed location. The build installs the library, public headers, licence records, and upstream release records.

## Platform boundaries

The cross-target check lists `x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos-none`, `x86_64-windows-gnu`, `riscv64-linux-gnu`, and `wasm32-wasi`.

- `config_gen.zig` rejects architectures absent from its pointer-width table, including Hexagon.
- NetBSD and OpenBSD use target-compiler preprocessing for the aggregate header. Other targets use Aro.
- WASI defines `_WASI_EMULATED_SIGNAL` and links `wasi-emulated-signal` for GMP's `raise(SIGFPE)` paths; no source substitution is used.
- Runtime providers must match the generated header's limb ABI. The loader checks `GMP_LIMB_BITS`; it does not prove endianness or all other ABI properties.