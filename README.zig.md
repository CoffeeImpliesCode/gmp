# GMP 6.3.0 as a Zig package

This repository is the GNU Multiple Precision Arithmetic Library 6.3.0: the
complete source tree of the official 6.3.0 release archive, imported as an
archive (GMP's canonical SCM is Mercurial, so there is no upstream Git history
and none is claimed) and packaged for Zig 0.16. `README` is upstream's own text
and is unchanged; this file documents the Zig surface, and `UPSTREAM.md`
records where the sources came from and how to re-verify them.

## What you get

* `dep.artifact("gmp")`: a static `libgmp` built from the sources in this
  repository. Its include tree carries the **generated** `gmp.h`, so linking the
  artifact is enough for a C or `translate-c` consumer. No install step, no
  download at build time, no system GMP required; `-fsys=gmp` links an installed
  GMP instead.
* `dep.module("gmp")`: the same library, linked, plus
  * `gmp.c` — the complete translated GMP API, stdio and `va_list` functions
    included,
  * `gmp.BigInt`, `gmp.Rational`, `gmp.Float`, `gmp.Rand` — owned Zig types,
  * `gmp.DivisionMode`, `gmp.Division`, `gmp.OwnedString`, `gmp.ParseError`,
    `gmp.FormatError` — the facade's public result and error types,
  * `gmp.version` and `gmp.versionString` (from the generated header),
    `gmp.upstream_version` (the release this fork tracks) and `gmp.limb_bits`
    (the target's limb width).

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
const gmp_dep = b.dependency("gmp", .{ .target = target, .optimize = optimize });
const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
module.addImport("gmp", gmp_dep.module("gmp"));
module.linkLibrary(gmp_dep.artifact("gmp"));
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
  where it was. `nbits == 0` and `n == 1` are legal and both return 0.
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
* rendering takes a base in 2..62. Base 0 is GMP's *parsing* convention, the
  one that honours the `0x`, `0b` and leading `0` prefixes, so `parse` and
  `setStr` accept it; the rendering functions do not, because
  `mpz_sizeinbase`, which is what sizes the buffer, documents 2..62 and asserts
  that range internally. Anything else fails with `error.InvalidBase`.
* `Float.writeTo(buffer, base, digits)` needs a positive `digits`. GMP reads
  `digits == 0` as "as many digits as the precision allows", a count it
  computes internally and does not export, so no capacity can be checked for
  it and `error.InvalidDigitCount` is returned. The result follows
  `mpf_get_str`: the text has no radix point and no trailing zeros and the
  exponent is separate, so 3.1416 in base 10 is the text `31416` at exponent 1.
* `toOwnedString(base)` is the separate, deliberately allocating API, for text
  that must outlive the buffer. Its `deinit` frees with GMP's own free function.
* rendering returns the caller's own buffer as a `[:0]const u8`, so the text can
  be parsed again with no copy in between: `try value.setStr(try other.writeTo(&buffer, 10), 10)`.

## Ownership and memory

GMP allocates with `gmp_allocate_func`, which defaults to `malloc`. This package
**never** installs allocator hooks, so:

* values are released with `mpz_clear`, `mpq_clear`, `mpf_clear`, `gmp_randclear`;
* strings GMP allocated are released with GMP's own free function, obtained from
  `mp_get_memory_functions`, never with `free` and never with a Zig allocator;
* that release passes the size of the block, not a placeholder. GMP documents
  `free_function` as receiving "a previously allocated block of SIZE bytes" and
  releases its own strings as `len + 1`; the default `free` ignores the argument,
  but a replaceable allocator may not, so `OwnedString` records the length and
  `deinit` reports `len + 1`;
* borrowed data (`OwnedString.slice`, `writeTo` results, `raw`) never outlives
  its owner, which is why those methods take the owner by value or return
  slices with no lifetime extension.

`zig/test/ownership.zig` proves this by counting GMP's allocations through a
test only probe, linked into the test binary and never into the library. The
probe also remembers the size each block was allocated with, so a release that
reports the wrong size is caught even though the default `free` would not care.

## Raw API

`gmp.c` is the translation of the generated `gmp.h`, in full: `mpz`, `mpq`,
`mpf`, `mpn`, `gmp_rand`, `gmp_printf`, `gmp_scanf`, `mp_get_memory_functions`,
including the stdio and `va_list` functions, which `gmp.h` only declares once
`<stdio.h>` and `<stdarg.h>` have been seen. Each facade value publishes the
two pointer types GMP itself uses, so a value goes into the raw API with no
cast and no copy:

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
| `cd consumer && zig build run` | a separate package consuming this one |

`zig build test` is meant to be run in both `Debug` and `ReleaseSafe`:

```sh
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
```

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

`-fno-sys=gmp` forces the bundled build back on, and `zig build --system`
switches the whole package to system libraries; `zig build -h` lists them with
their state.

## Licence

libgmp is LGPLv3 or later, or GPLv2 or later, at the user's option; this fork
selects LGPLv3 for the library it builds and links. See `NOTICE.md`, `COPYING`,
`COPYINGv2`, `COPYINGv3` and `COPYING.LESSERv3`. Being private does not change
any of that.
