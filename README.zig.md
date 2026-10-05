# GMP 6.3.0 as a Zig package: the Zig interface

This file documents the Zig surface. Start with `README.md` for the fork's
deviations, support matrix and consumption; this file is the reference for the
module itself.

This repository is the GNU Multiple Precision Arithmetic Library 6.3.0: the
complete source tree of the official 6.3.0 release archive, imported as an
archive (GMP's canonical SCM is Mercurial, so there is no upstream Git history
and none is claimed) and packaged for Zig 0.16. `README` and `README.upstream.md`
are upstream's own text, byte for byte; `UPSTREAM.md` records where the sources
came from and how to re-verify them.

## What you get

* `dep.artifact("gmp")`: the `libgmp` this repository builds — static by
  default, which is this fork's existing linkage policy, with a shared variant
  available as a build option. Its include tree carries the **generated**
  `gmp.h`, so linking the artifact is enough for a C or `translate-c` consumer.
  No install step, no download at build time, no system GMP required;
  `-fsys=gmp` links an installed GMP instead, and that configuration
  publishes no artifact under this name at all — see
  [System library mode](#system-library-mode). `-Dlinkage=static` (the default) or
  `-Dlinkage=dynamic` chooses which artifact this build compiles; only `gmp.h`
  differs between them, through `__GMP_LIBGMP_DLL`. `zig build install --prefix
  DIR` writes the library, the three headers, `DIR/lib/pkgconfig/gmp.pc`, the
  example and the licence and provenance records into `DIR`: the four upstream
  grants and this fork's own `NOTICE.md`, `FORK-LICENSE.md`, `UPSTREAM.md` and
  `README.upstream.md` under `DIR/share/licenses/gmp/`, and upstream's `AUTHORS`,
  `NEWS` and `README` under `DIR/share/doc/gmp/`. The Nix packages in
  `package.nix` install the same tree and add no path of their own.
* `dep.module("gmp")`: the same library, linked, plus
  * `gmp.c` — the complete translated GMP API, stdio and `va_list` functions
    included,
  * `gmp.BigInt`, `gmp.Rational`, `gmp.Float`, `gmp.Rand` — owned Zig types,
  * `gmp.DivisionMode`, `gmp.Division`, `gmp.OwnedString`, `gmp.ParseError`,
    `gmp.FormatError` — the facade's public result and error types,
  * `gmp.version` and `gmp.versionString` (from the generated header),
    `gmp.upstream_version` (the release this fork tracks) and `gmp.limb_bits`
    (the target's limb width).
  * `gmp.runtime_loaded`, `gmp.load`, `gmp.loadedSource`, `gmp.LoadSource`,
    `gmp.LoadError`, `gmp.providerRequest`, `gmp.providerFromCEnvironment`,
    `gmp.NoProviderConfigured`, `gmp.providerVersion`, `gmp.providerErrno` and
    `gmp.providerBitsPerLimb` — the runtime-loading surface, which a linked
    build compiles away and a `-Druntime=true` build calls; see
    [Runtime loading](#runtime-loading).

## Quick start

```zig
const std = @import("std");
const gmp = @import("gmp");

pub fn main() !void {
    var buffer: [64]u8 = undefined;

    var value = try gmp.BigInt.parse("123456789012345678901234567890", 10);
    defer value.deinit();

    std.debug.print("{s}\n", .{try value.writeTo(&buffer, 10)});
}
```

```zig
// build.zig of a dependent package
// Nullable and forwarded exactly as given, so an absent option leaves the
// dependency on its own default, which is the linked route.
const runtime = b.option(bool, "runtime", "Consume GMP through the runtime-loading route, where the provider is named and loaded at run time. Forwarded to the gmp dependency unchanged.");
const gmp_dep = b.dependency("gmp", .{ .target = target, .optimize = optimize, .runtime = runtime });
const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
module.addImport("gmp", gmp_dep.module("gmp"));
// The artifact is this package's own compiled library, published by every
// bundled configuration, and only one of those configurations links it. Under
// `-fsys=gmp` this graph compiles no library, so the name resolves against
// nothing and asking for it panics rather than linking; one call answers that,
// reading the build graph every package in the process shares. Under
// `-Druntime=true` the name does resolve — the loader has to have something to
// open — and linking it would let the linker satisfy the dispatch statically,
// so `load` would never be reached and the run would prove nothing about the
// route it was asked to exercise. That is a link which must not be made, not
// an alternative to make: a run told nothing is refused, not served from here.
if (!b.systemIntegrationOption("gmp", .{}) and !(runtime orelse false)) module.linkLibrary(gmp_dep.artifact("gmp"));
```

A complete, runnable version of this is in `consumer/`:

```sh
cd consumer && zig build run
```

## The facade

`BigInt`, `Rational`, `Float` and `Rand` are thin, owned wrappers. They are not
a reimplementation: every operation is one GMP call.

```zig
var a = try gmp.BigInt.parse("2", 10);
defer a.deinit();
var b = gmp.BigInt.init();
defer b.deinit();
b.setUnsignedWord(1000);

var product = gmp.BigInt.init();
defer product.deinit();
product.mul(&a, &b);          // mpz_mul(product, a, b)

var text: [128]u8 = undefined;
std.debug.print("{s}\n", .{try product.writeTo(&text, 10)});
```

Conventions:

* methods that mirror a three argument GMP function write into the receiver;
* methods ending in `Assign` update the receiver in place;
* operands passed as `*const` are never modified;
* machine words are the target's C words, never a fixed 64 bits. GMP declares
  these parameters `unsigned long`, `signed long` or `mp_bitcnt_t`, and
  `unsigned long` is 32 bits on `x86_64-windows-gnu` and on `wasm32-wasi`, so
  the facade uses `c_ulong`, `c_long` and `c.mp_bitcnt_t` directly:
  `setUnsignedWord`/`setSignedWord`/`toUnsignedWord`/`toSignedWord`/
  `fitsUnsignedWord`/`fitsSignedWord` on `BigInt`, `setUnsignedWord`/
  `sqrtUnsignedWord`/`cmpUnsignedWord` on `Float`, and `c_ulong` for every
  `*Ui` method. A value too wide for the target's word is parsed
  (`BigInt.parse`) or built with shifts, never truncated into one.
* `Rand.nextBits(nbits)` and `Rand.nextBelow(n)` are `gmp_urandomb_ui` and
  `gmp_urandomm_ui` themselves, with the manual's own conditions checked as
  ordinary comparisons rather than assertions. A bit count wider than the
  target's `unsigned long` is `error.TooManyBits`, because GMP truncates it
  silently (`rand/randbui.c` uses `MIN (bits, BITS_PER_ULONG)`); a bound of
  zero is `error.EmptyRange`, because GMP answers it with `DIVIDE_BY_ZERO`
  (`rand/randmui.c`). Neither reaches GMP, so a refused draw leaves the state
  where it was. `nbits == 0` and `n == 1` are legal and both return 0. A fresh
  `Rand` starts at GMP's fixed Mersenne Twister default table
  (`rand/randmts.c:166-171`, `rand/randmt.c:410-414`), so the stream is
  reproducible rather than random until `seed` is called.
* `parse(text, base)` and `setStr(text, base)` take a NUL terminated
  `[:0]const u8` and pass the pointer to GMP unchanged: no copy, no scratch
  buffer, no allocation. A string literal already has that type; text that does
  not has to be terminated by the caller, because GMP reads a C string.
* `writeTo(buffer, base)` formats into **your** buffer with no allocation and no
  copy: GMP is handed the pointer directly. The capacity required is the one
  the GMP manual states for the corresponding function, no more and no less:
  `mpz_sizeinbase(value, base) + 2` for `BigInt`,
  `mpz_sizeinbase(numerator, base) + mpz_sizeinbase(denominator, base) + 3` for
  `Rational`, and `digits + 2` for `Float`. The base is validated first, then
  the capacity is checked, and only then is GMP called, so a too small buffer
  is never written to and fails with `error.BufferTooSmall`.
  That bound is sufficient, not necessary: `mpz_sizeinbase` may report one
  digit too many for a base that is not a power of two, so a buffer that
  happens to hold the text of a particular value can be shorter than the bound
  and is then rejected. Size the buffer with `BigInt.sizeinbase` plus two, or
  use `toOwnedString` and skip the arithmetic.
* parsing takes a base of 0 or 2..62, and rendering takes 2..62. What base 0
  means is not the same at every call site, which is GMP's own split rather
  than this package's: `mpz_set_str` and `mpq_set_str` read a 0 as prefix
  detection, so `0x`, `0b` and a leading `0` are honoured (`mpz/set_str.c:80-100`,
  `doc/gmp.texi:4413-4418`), while `mpf_set_str` reads a 0 as base 10 with no
  look at the text at all (`mpf/set_str.c:153-155`, `doc/gmp.texi:4877-4879`),
  precisely so that `0.23` is not taken for octal. So `Float.parse`/`Float.setStr`
  are decimal on base 0, and `BigInt.parse`/`Rational.parse` are not. The
  rendering functions reject 0 because `mpz_sizeinbase`, which sizes the
  buffer, documents 2..62 and asserts that range internally. Anything else
  fails with `error.InvalidBase`.
* `mpf_set_str` also accepts a negative base, -62 to -2, meaning the mantissa
  is in `base` and the exponent is in decimal (`doc/gmp.texi:4869-4871`). The
  facade's `base: u8` cannot express a negative value, so that one GMP feature
  is reached through `gmp.c.mpf_set_str` rather than through `Float.setStr`.
* `Float.writeTo(buffer, base, digits)` needs a positive `digits`. GMP reads
  `digits == 0` as "as many digits as the precision allows", a count it
  computes internally and does not export, so no capacity can be checked for
  it and `error.InvalidDigitCount` is returned. The result follows
  `mpf_get_str`: the text has no radix point and no trailing zeros and the
  exponent is separate, so 3.1416 in base 10 is the text `31416` at exponent 1.
* `toOwnedString(base)` is the separate, deliberately allocating API, for text
  that must outlive the buffer. Its `deinit` frees with GMP's own free function,
  once per string.
* `Float` truncates; it does not round to nearest. The precision `init` asks
  for is a minimum that GMP rounds up to whole limbs, every `mpf` result is
  truncated toward zero at the destination's precision, and `mpf_set_prec`
  truncates the value it keeps (`doc/gmp.texi:4700-4702`, `:4807-4809`;
  `mpf/set.c:46-50`, `mpf/set_prc.c:61-65`). `getDouble` truncates toward zero
  as well (`doc/gmp.texi:4944-4946`), and `mpf` has no infinity and no NaN, so
  an exponent that outruns the type is unpredictable (`doc/gmp.texi:4711-4713`).
  The manual is explicit that `mpf` is not a smooth extension of IEEE 754
  (`doc/gmp.texi:4715-4718`); a caller that needs round-to-nearest with a
  chosen precision wants MPFR. `mpf_get_str`'s half-up rounding at the last
  requested digit belongs to the rendering, not to the value
  (`mpf/get_str.c:256-262`).
* rendering returns the caller's own buffer as a `[:0]const u8`, so the text can
  be parsed again with no copy in between: `try value.setStr(try other.writeTo(&buffer, 10), 10)`.

## Ownership and memory

GMP has one allocator for the whole library, held in the global slots
`gmp_allocate_func`, `gmp_reallocate_func` and `gmp_free_func`, and
`mp_set_memory_functions` is the only thing that replaces them
(`doc/gmp.texi:7440-7450`). No built library code or facade method calls the
setter. The facade uses the provider's current hooks, which default to `malloc`
and matching reallocation/free functions. This fork's Zig tests replace them
through `zig/test/alloc_probe.c`, linked only into tests. A program that replaces
the hooks changes
the allocator for every value the facade owns, before the change and after it,
and GMP asks for that only while no GMP object is live
(`doc/gmp.texi:7448-7450`). Because the provider is the library's and not a Zig
one:

* values are released with `mpz_clear`, `mpq_clear`, `mpf_clear`,
  `gmp_randclear`, or `BigInt.deinit` and friends, which are those calls;
* strings GMP allocated are released with GMP's own free function, obtained from
  `mp_get_memory_functions`, never with `free` and never with a Zig allocator;
* that release passes the size of the block, not a placeholder. GMP documents
  `free_function` as receiving "a previously allocated block of SIZE bytes" and
  releases its own strings as `len + 1`; the default `free` ignores the argument,
  but a replaceable allocator may not, so `OwnedString` records the length and
  `deinit` reports `len + 1`;
* a failed native allocation is never an `error.OutOfMemory`. GMP's allocator
  functions may not return `NULL` (`doc/gmp.texi:7487-7490`) and the default one
  prints and aborts (`memory.c:53-58`), so a Zig leak checker sees none of these
  blocks and there is no Zig recovery path to promise.

Every `init`, `parse` and `toOwnedString` produces one owned value and each has
exactly one `deinit`. Zig has no move: a copy made by assignment, by a struct
field, or by returning the value into a second binding is a *second name for
one GMP allocation*, so releasing both names is a double free. `BigInt.clone`,
`Rational.clone` and the values returned by `div`, `divexact`, `mod`,
`numerator` and `denominator` are GMP's own copies into second allocations,
each with its own `deinit`; they are not moves.

`raw` is a reachable field rather than a borrow, so writing to it through
`gmp.c` is the caller's decision and `deinit` still releases what GMP allocated.
What is genuinely borrowed is `OwnedString.slice`, the `writeTo`
results and `Float`'s `Rendered`: they point into the caller's own buffer or
into the owner and never outlive it, which is why those methods take the owner
by value or return slices with no lifetime extension.

`zig/test/ownership.zig` proves this by counting GMP's allocations through a
test only probe, linked into the test binary and never into the library. The
probe also remembers the size each block was allocated with, so a release that
reports the wrong size is caught even though the default `free` would not care.

## Raw API

`gmp.c` is the translation of the generated `gmp.h`, in full: `mpz`, `mpq`,
`mpf`, `mpn`, `gmp_rand`, `gmp_printf`, `gmp_scanf`, `mp_get_memory_functions`,
including the stdio and `va_list` functions, which `gmp.h` only declares once
`<stdio.h>` and `<stdarg.h>` have been seen. It is a supported route, not an
accident of the translation: it is exported from `dep.module("gmp")`, so a
dependent that adds that module and links `dep.artifact("gmp")` reaches it. The
artifact alone is the other route, for a C or `translate-c` consumer that wants
the headers without the Zig module — a bundled build only, since `-fsys=gmp`
publishes no artifact. Each facade value publishes the two
pointer types GMP itself uses, so a value goes into the raw API with no cast
and no copy:

* `rawPtr()` takes `*Self` and returns the mutable `mpz_ptr` / `mpq_ptr` /
  `mpf_ptr` / `gmp_randstate_ptr`, for the calls GMP writes through;
* `rawSrcPtr()` takes `*const Self` and returns `mpz_srcptr` / `mpq_srcptr` /
  `mpf_srcptr` / `gmp_randstate_srcptr`, for everything GMP only reads.

```zig
var value = gmp.BigInt.init();
defer value.deinit();
gmp.c.mpz_mul_ui(value.rawPtr(), value.rawSrcPtr(), 6);
```

## Steps

| command | what it does |
| --- | --- |
| `zig build` | builds and installs the library and the example |
| `zig build test` | runs the test suite in the current optimize mode |
| `zig build smoke` | runs the example, which prints and verifies deterministic results |
| `zig build run` | the same example, as a named step |
| `zig build check` | compiles the facade, the tests and the example for all six targets, running nothing |
| `zig build provenance` | licence and provenance integrity gate |
| `zig build -Druntime=true` | builds the runtime-loading configuration: the module's `c` import becomes the generated dispatch, nothing in the graph links `libgmp`, and a run has to name the provider with `--provider <path>` or `GMP_TEST_PROVIDER` — see [Runtime loading](#runtime-loading) |
| `cd consumer && zig build run` | a separate package consuming this one; under `-Druntime=true` it names the provider with `-- --provider <path>`, or in `GMP_TEST_PROVIDER` |
| `zig build -fsys=gmp` | builds against an installed GMP: no artifact of this tree, the installed library linked through the module — see [System library mode](#system-library-mode) |
| `cd consumer && zig build run -fsys=gmp` | the same dependent, in that configuration; the installed GMP it binds to must be on the host's linker search path |
| `zig build install --prefix DIR` | installs `DIR/lib/libgmp.*`, `DIR/lib/pkgconfig/gmp.pc`, `DIR/include/{gmp.h,gmp-mparam.h,gmp_all.h}`, `DIR/bin/gmp-example` and the upstream licence and authorship records |
| `devenv task sdk:*` | the canonical environment's namespaced tasks: `sdk:build`, `sdk:test`, `sdk:test-release-safe`, `sdk:smoke`, `sdk:check`, `sdk:provenance`, `sdk:consumer` |
| `devenv build outputs.static`, `devenv build outputs.shared` | the packaging route from the shell; builds the same derivation `package.nix` returns, on demand |
| `nix build .#static`, `nix build .#shared` | the same two variants from the flake; `.#default` is the static one |

`zig build test` is meant to be run in both `Debug` and `ReleaseSafe`:

```sh
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
```

## Runtime loading

`-Druntime=true` builds the second shape this module has, and
`gmp.runtime_loaded` is a comptime constant that says which shape was built, so
a consumer can write both paths and have only the one it chose analysed. That
is the whole runtime surface: it lives in this tree, and it is the module's own.

```zig
if (comptime gmp.runtime_loaded) {
    try gmp.load(.{ .path = try gmp.providerRequest(init) });
}
```

* **One explicit call.** `gmp.load(source)` is the whole contract, and it is
  one call. `gmp.LoadSource` is a tagged union with exactly two cases:
  `.path`, an absolute file path, and `.system`, a name for the platform
  loader's own search. Neither falls back to the other, this package has no
  search path of its own, and nothing is loaded that a caller did not name.
* **The provider is named, never inferred.** `gmp.providerRequest(init)` reads
  `--provider <path>` and falls back to the `GMP_TEST_PROVIDER` environment
  variable; `gmp.providerFromCEnvironment()` reads the environment alone, which
  is what a program with no `main` of its own needs, a test binary in
  particular, because the test runner owns that entry point. A run that was
  told nothing gets `error.NoProviderConfigured`, which is a distinct error
  because nothing was attempted: a smoke run that quietly fell back to the
  bundled linkage would prove nothing about the route its configuration claims.
  `zig/test/bootstrap.zig` is that same one-line step, and every test in
  `zig/test/` calls it first; in a linked build it compiles away entirely.
* **The table belongs to the configuration, and it is independent of the
  linkage.** A `-Druntime=true` graph builds and installs `libgmp` — the loader
  has to have something to open — but nothing links it: the archive is built and
  installed, and no module imports it, because linking it as well would let the
  linker resolve the symbols before `load` ever ran and quietly turn the route
  back into a linked one. The `__gmp*` entry points this build's `gmp.h`
  declares arrive through the platform loader when `load` runs, and every routed
  function reads one acquire-loaded readiness flag before it dereferences the
  table. A call before `load` has succeeded stops the program with a message
  naming the function, in every optimize mode: that is a programming error
  rather than a recoverable condition, because the table does not exist yet and
  there is no partial state to fall back on.
* **Live data, not a copy taken at load time.**
  `gmp.providerVersion()`, `gmp.providerErrno()` and
  `gmp.providerBitsPerLimb()` read the provider's own `__gmp_version`,
  `__gmp_errno` and `__gmp_bits_per_limb` where those objects live, through
  one guarded accessor per object. `providerVersion` returns a `[:0]const u8`
  that borrows the provider's string constant; the other two return pointers,
  because `gmp.h` declares `__gmp_errno` writable and the C library's `errno` is
  per-thread, so copying the number out would snapshot one instant and writing
  to a copy would write nowhere. They are not `gmp.version` and
  `gmp.upstream_version`: those two come from the macros in this build's
  `gmp.h` and say what the build was compiled against, while these say what the
  loaded library says it is.
* **Failure publishes nothing.** `gmp.LoadError` is the whole set, and every
  member is a condition this code checked itself: `EmptySource` and
  `SourceTooLong` are refused before the platform is touched, `InvalidSource`
  covers a relative path, a path component in a system name and a NUL byte,
  `UnsupportedTarget` means the target has no dynamic loader, `OpenFailed` is
  the platform refusing, `MissingSymbol` is a file that opens without exporting
  everything the header declares, `ValidationFailed` is GMP's own check
  declining the candidate, `ProviderMismatch` is a second, different request,
  and `ReentrantLoad` is a call from inside an attempt. A candidate that fails
  at any step is closed and the table is never published, so a partial table is
  not reachable. There is no automatic retry and no implicit second source: a
  failed attempt is retried by calling `load` again. After a success, the same
  request again succeeds and changes nothing, a different request is
  `ProviderMismatch` and the provider already in use stays in use. `load` is
  safe from any thread, and a thread that arrives while an attempt for the same
  request is in flight waits for it and gets that attempt's result.
* **Process lifetime.** There is no unload and no reset. The handle and the
  loader's own copy of the request live until the process exits, because the
  table is process-global state and the code that filled it may already have
  been called from anywhere. `gmp.loadedSource()` returns that retained request
  or null, and is null in a linked build, which has no request.
* **The allocator follows the provider.** GMP's three hooks are its own globals
  and the only setter a program has is the one the provider exports, so
  `gmp.setMemoryFunctions` installs into the provider and `gmp.freeNativeBlock`
  frees through the provider's current free function. Every block must be
  released through the provider that allocated it; see
  [Ownership and memory](#ownership-and-memory).
* **The configured ABI boundary.** The one load-time check is limb width: the
  provider's `__gmp_bits_per_limb` must equal the `GMP_LIMB_BITS` this build's
  `gmp.h` was generated for, because that number decides the layout of
  `__mpz_struct`, `__mpq_struct` and `__mpf_struct`, which cross the boundary by
  pointer on every call. Everything else is compiled into both sides and is not
  checked at run time: `mp_limb_t` and its signed counterpart, limb endianness,
  `GMP_NAIL_BITS` (0 here), and the platform's C calling convention, which is
  the type of every routed function pointer. Symbol presence is not ABI proof
  and neither is the version string; `runtime/library.zig` states the whole
  boundary, and the header's own `__gmp` renaming is in `README.md` under
  [Runtime loading](README.md#runtime-loading).

`-fsys=gmp` is not one of these two shapes: that route links an installed
library by name through the system library integration, so `-Druntime` does not
apply there and nothing above describes it. See
[System library mode](#system-library-mode).

## Supported targets

`zig build check` covers `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`aarch64-macos-none`, `x86_64-windows-gnu`, `riscv64-linux-gnu` and
`wasm32-wasi`. `check` compiles; it does not run cross binaries, so it proves
the public surface builds, not that the results match on every architecture.
Native runs of the test suite are the behavioural evidence. With no `-Dtarget=`
it covers all six at once; with one it covers only that target, which is what
CI uses so a failure names the target.

`wasm32-wasi` does not compile, and this is a property of the vendored source
rather than of the packaging. `invalid.c` reports an invalid operation by
raising `SIGFPE` (`src/invalid.c:80`), `Makefile.am:285` compiles that file
unconditionally, and wasi-libc has no signal support: its `signal.h` refuses to
be included without `_WASI_EMULATED_SIGNAL`. Upstream's own `configure` has no
wasm handling either. The target stays in the matrix and the attempt stays
visible; CI marks that one target `continue-on-error` rather than dropping it.
A project that compiles `invalid.c` directly meets the same wall.

## Backend differences

The library is GMP's portable C backend on every target, with `NO_ASM` defined.
It is correct and ABI compatible on all six targets, and it is slower than GMP's
tuned assembly. `CHANGELOG.md` lists what that costs and which configuration
macros differ from what `configure` would pick.

Three consequences worth knowing:

* the public `gmp.h` is generated per target, because it encodes the limb type.
  On LP64 targets `mp_limb_t` is `unsigned long` with 64-bit limbs, on
  `x86_64-windows-gnu` it is `unsigned long long`, and on `wasm32-wasi` it is a
  32-bit `unsigned long`. `gmp.limb_bits` reports it.
* the generic C backend omits the 29 internal mpn functions that have no
  portable C source, the same set `configure` omits for a generic build. They
  are internal, not `gmp.h` API, so nothing a caller can name is missing; what
  is lost is the tuned-assembly fast path GMP would use for them.
* libgmpxx, the C++ binding, is not built. `mini-gmp` is not used.

## System library mode

`zig build -fsys=gmp` builds against an installed GMP instead of compiling
this tree. In that mode the generated header is deliberately **not** put on the
include line, so the translated declarations come from the installed `gmp.h` and
always describe the library that is linked. The facade uses only long standing
public GMP API, so it works against GMP 5 or later; the limb size then follows
the installed library.

**This configuration publishes no artifact.** It compiles no library of this
tree, so `dep.artifact("gmp")` does not resolve — asking for it panics and
lists the artifacts that do exist — and a dependent must not link it. Nothing
is missing from the link line: `dep.module("gmp")` carries the installed
library, because the graph puts `gmp` on the translated `c` module it imports
and every module in a compilation's graph is on that compilation's link line.
Adding the artifact as well would be a second `-lgmp`, not a second library.

**How a dependent reads the selection.** `-fsys=gmp` and `-fno-sys=gmp` are
the toolchain's own system library integration, not an option of this
package. The build runner records them before any package's `build` runs, and
every `std.Build` in the process shares the one `Graph` holding them
(`createChildOnly` passes the parent's `graph` down), so a dependent calls
`b.systemIntegrationOption("gmp", .{})` and gets the identical answer this
build gets. There is nothing to forward to a dependency — and a dependent
should not invent a second spelling for it — because `b.dependency` runs the
dependency's `build` in the same process against the same graph.

**`-Dlinkage` means something else here.** With no artifact to compile, the
option names the kind of *installed* library to prefer, and the default is
dynamic — the default of `Module.linkSystemLibrary`. Forward a pinned default
from a dependent and a host that ships only `libgmp.so` fails to link, which
reads as a broken system library rather than as a wrong default.

**`-Druntime` is refused here, not ignored.** `-fsys=gmp` links a library and
`-Druntime=true` resolves the same symbols through the platform loader;
combining them is refused by name at configure time, before any source is
generated, and neither configuration is ever substituted for the other.

`-fno-sys=gmp` forces the bundled build back on, and `zig build --system`
switches the whole package to system libraries; `zig build -h` lists them with
their state.

## Licence

libgmp is LGPLv3 or later, or GPLv2 or later, at the user's option; this fork
selects LGPLv3 for the library it builds and links. See `COPYING`, `COPYINGv2`,
`COPYINGv3` and `COPYING.LESSERv3` for the four upstream texts.

`NOTICE.md` is the per-file inventory, because this tree is not one licence:
the upstream test suite and several demonstrations are GPLv3 or later, the
manual is GFDL 1.3 or later, and the autotools scaffolding carries Free Software
Foundation, GNU Libtool and X Consortium terms of its own. The Zig code, the
build files, the Nix and devenv files and this documentation are
`LGPL-3.0-or-later` under the repository owner's authorization; `FORK-LICENSE.md`
records that grant and which files it covers. Being private does not change any
of this.
