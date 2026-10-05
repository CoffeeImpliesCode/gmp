# Changelog

Numbered entries record divergences introduced by this fork. Upstream's own
history is in `ChangeLog` and `NEWS`, which are unchanged.

## 1. Zig package build, portable C backend

The library is built by `build.zig` instead of autotools. For every target the
mpn path is `generic` and `NO_ASM` is defined, that is the same portable C code
GMP builds with `--disable-assembly`. No tuned assembly backend is selected, and
none is claimed. Consequences:

* The mpn path is the 180 translation units upstream's own selection loop picks
  for a generic build, not every file in `mpn/generic`. The five multi-function
  templates are compiled once per operation through a generated wrapper, the way
  `configure:25553` and `mpn/Makefile.am:33` do it, and the three files that no
  generic build selects are not compiled. Because `NO_ASM` is defined, the inline
  assembly helpers a few of those files would otherwise use for `__amd64__` and
  `__ia64__` are not used. This is what makes one source path valid for all six
  checked targets, including `wasm32-wasi`, where clang has no GNU style inline
  assembly.
* Arithmetic is correct and ABI compatible everywhere but slower than GMP's own
  per-architecture assembly. Speed parity is not claimed.
* `HAVE_HOST_CPU_*` and `HAVE_NATIVE_mpn_*` stay undefined, so no CPU specific
  routine is reported as existing.
* 29 internal functions in `$gmp_mpn_functions` have no generic C source and are
  omitted, exactly as `configure:25581-25588` omits them for a generic build.
  They are `umul`, `udiv`, `invert_limb`, `mul_2..6`, `addmul_2..8`, the
  `addlsh`/`sublsh`/`rsblsh` families, `rsh1add_n`, `rsh1sub_n`, `sqr_diagonal`,
  `sqr_diag_addlsh1` and `addaddmul_1msb0`. `gmp-impl.h` only references them
  under `HAVE_NATIVE_*`, which stays undefined, so nothing compiled here refers
  to them. No `gmp.h` API is lost: every `mpz`, `mpq`, `mpf`, `mpn`, `rand`,
  `printf` and `scanf` entry point upstream builds for a generic path is present.

## 2. `config.h` and `gmp.h` are derived from the target, not from the host

`configure` probes the build machine. This fork derives the same values from the
resolved Zig target, so cross compilation is correct without probing:

* limb size and limb type: 64-bit limbs from `unsigned long` on LP64, from
  `unsigned long long` on LLP64 (Windows), 32-bit limbs on 32-bit pointer
  targets. `SIZEOF_UNSIGNED_LONG`, `SIZEOF_MP_LIMB_T` and `SIZEOF_VOID_P` in
  `config.h` and `GMP_LIMB_BITS` in `gmp.h` agree by construction.
* endianness: `HAVE_DOUBLE_IEEE_*_ENDIAN` and `HAVE_LIMB_*_ENDIAN` follow the
  target, so a big endian target is configured correctly rather than silently
  assuming little endian.
* no host macros are copied to a cross target.

## 3. Table generation runs at build time, for the target's limb size

`gen-fib`, `gen-bases`, `gen-fac`, `gen-sieve`, `gen-psqr`, `gen-trialdivtab`
and `gen-jacobitab` are compiled for the host and run with the target's
`GMP_LIMB_BITS` and `GMP_NAIL_BITS`, exactly as the upstream `Makefile.am` rules
do. Their outputs (`fib_table.h`, `mp_bases.h`, `fac_table.h`, `sieve_table.h`,
`perfsqr.h`, `trialdivtab.h`, `jacobitab.h`, `mpn/fib_table.c`, `mpn/mp_bases.c`)
land in the build cache, never in the source tree.

## 4. Deliberate configuration choices

These differ from what `configure` would choose on the same machine, each for a
reason:

| choice | reason |
| --- | --- |
| `HAVE_LONG_DOUBLE 0` on `wasm32-wasi` | Zig's clang gives that target a 128-bit `long double`, and it affects only GMP's `%Lf` handling in `gmp_printf`. Everywhere else it stays 1. |
| `HAVE_LANGINFO_H 0` on Windows targets | MinGW has no `<langinfo.h>`; GMP falls back to `localeconv()->decimal_point`, which is correct. |
| `HAVE_ALLOCA_H 0` on macOS | macOS has no `alloca.h`. clang takes the `__builtin_alloca` branch regardless. |
| `WANT_ASSERT` on in Debug, off otherwise | mirrors the `-DNDEBUG` driven configure default |
| static linkage, `__GMP_LIBGMP_DLL` 0 | `__GMP_DECLSPEC` stays empty, so the ABI is identical on LP64, LLP64 and wasm32 |

## 5. Scope: libgmp, not libgmpxx, not mini-gmp

The build produces the real libgmp: `mpz`, `mpq`, `mpf`, the portable `mpn`
layer, `printf`, `scanf` and the random state code: 498 library translation
units, plus eighteen generated sources, namely the two table sources
(`fib_table.c`, `mp_bases.c`) and one wrapper for each of the 16 operations of
the multi-function mpn templates. It does **not** build:

* `libgmpxx`, the C++ binding in `cxx/`. It needs a C++ compiler and is not part
  of the C library;
* `mini-gmp`, the small alternative implementation in `mini-gmp/`. It is a
  different project with a different API subset.

The public C API is complete: `gmp.c` is the full translation of the generated
`gmp.h`, including rationals, floats, random states and the printf and scanf
families.

## 6. GMP 6.3 API facts this facade had to respect

* `mpf_set_str` takes three arguments in 6.3; there is no digit count.
* GMP 6.3 declares neither `mpf_const_pi` nor `mpf_set_inf`, so the float facade
  has no constant for pi. MPFR is the package that provides one.
* There is no `mpf_sgn`; the facade reads the documented `_mp_size` field.
* The random interface is `gmp_urandomb_ui` and `gmp_urandomm_ui`. There is no
  `gmp_rand_ui32` in 6.3's public header.

## 7. Tests, example and consumer

Added `zig/test/*` (independent known answers, division semantics, parse
failures, ownership accounting), `zig/example/main.zig` (runnable, self
checking), and `consumer/`, a separate package that uses this one through
`b.dependency("gmp", ...)`. Fixtures are independent mathematical facts or
values computed in the test itself; no test asserts a round trip against itself.

## 8. Upstream sources left unbuilt but kept

`tests/`, `demos/`, `tune/`, `mini-gmp/`, `cxx/`, `doc/` and the per-CPU
assembly directories under `mpn/` are kept byte identical so the import stays
pristine. None of them is compiled by this fork, and none of them is claimed to
be tested by it.

## 9. Caller storage capacity is the manual's, and rendering needs a real base

`writeTo` no longer invents a bound of its own. The required capacities are
exactly the ones the GMP manual states for the corresponding function, and
nothing more:

| call | capacity |
| --- | --- |
| `BigInt.writeTo(buffer, base)` | `mpz_sizeinbase(value, base) + 2` |
| `Rational.writeTo(buffer, base)` | `mpz_sizeinbase(numerator, base) + mpz_sizeinbase(denominator, base) + 3` |
| `Float.writeTo(buffer, base, digits)` | `digits + 2`, with `digits` at least 1 |

The earlier `mpz_sizeinbase + 3` for integers and `2 * mpq_sizeinbase + 8` for
rationals were padding with nothing behind them, and the claim that the bound
"never rejects text that fits" was false. `mpz_sizeinbase` may report one digit
too many for a base that is not a power of two, so the bound is an upper bound:
sufficient, but not necessary, and a buffer that happens to hold the text of a
particular value can be shorter and is then rejected. That is now what the
documentation says and what the tests check.

Corrected in the same change:

* `Rational.writeTo` called `c.mpq_sizeinbase`, which GMP does not export. The
  bound is now computed from `mpz_sizeinbase` of the two parts, which is what
  the manual and `mpq/get_str.c` use. There is no `mpq_sizeinbase`.
* The null return of `mpz_get_str`, `mpq_get_str` and `mpf_get_str` is no longer
  read as "the buffer was too small". None of them inspects a non null buffer;
  they return null only for a base outside their range.
* Rendering, and `BigInt.sizeinbase` with it, now take base 2..62 and return
  `error.InvalidBase` otherwise. Base 0 stays valid for `parse` and `setStr`,
  where it is GMP's `0x`, `0b` and leading `0` detection; `mpz_sizeinbase`
  asserts `base >= 2` and, with the assertion compiled out, divides by
  `mp_bases[0].big_base`, which is 0.
* `Float.writeTo` rejects `digits == 0` with the new `error.InvalidDigitCount`.
  GMP reads zero as "as many digits as the precision allows", a count it
  computes internally and does not export, so no capacity can be checked for it.
  Previously `writeTo(buffer, base, 0)` passed a three byte check and then let
  GMP write the precision derived number of digits into the buffer.
* `BigInt.sizeinbase` returns `FormatError!u64` instead of `u64`.

## 10. Float rendering fixtures were impossible outputs

`mpf_get_str` returns the significant digits with no radix point and with
trailing zeros removed, and reports the exponent separately: the manual's own
example is that 3.1416 in base 10 is the text `31416` at exponent 1. Three
fixtures in the example, the test suite and the facade exercise asked for text
with a radix point, or for trailing zeros, neither of which the function can
produce. They now assert the digits GMP returns, with the exponent beside them.

## 11. The build script and the config generator follow Zig 0.16

* `Target.Query` has no `arch_os_abi` field, so `check` parses each checked
  triple with `std.Build.parseTargetQuery`, the same call
  `standardTargetOptions` makes for `-Dtarget`.
* `Module.CSourceFiles.files` is `[]const []const u8`, so the two generated
  translation units are passed as `&sources.generated`.
* `++` only concatenates comptime known operands, so `renderGmpH` and
  `renderConfigH` now write their own prologue and each generated header is
  produced in a single buffer. The public `gmpHPrologue` and `configHPrologue`
  helpers are gone rather than kept as aliases.
* `generate` lost the `target` parameter it never read; the derived values are
  all in `Params` already.
* `readPackageFile` reads through `b.build_root.handle`, and the provenance
  step passes its paths with `Run.addFileArg`. Both replace deprecated
  `LazyPath.getPath2` calls.
* `pointerBits` no longer lists `sparcel`, which is not in the current
  `Cpu.Arch` because LLVM dropped the tag, and it now lists `arceb`,
  `riscv32be`, `riscv64be` and `xtensaeb` next to their little endian siblings.
  `arc` moved from the 64-bit group to the 32-bit one, where it belongs.

## 12. String input and string release follow GMP's own contract

* `parse` and `setStr` on `BigInt`, `Rational` and `Float` take a
  `[:0]const u8` and pass the pointer to GMP unchanged. They used to take a
  `[]const u8`, copy the text into a 128 byte stack scratch buffer, and fall
  back to a `c_allocator` allocation for longer input. Both paths were wrong:
  the stack return counted the terminating NUL as a data byte and pointed its
  sentinel at the uninitialised byte after it, and the heap path formatted
  `"{s}\x00"`, which gave `allocPrintSentinel` two terminators. The scratch
  buffer, the fallback allocation and the `CString` type are removed, not kept
  as aliases, and `error.OutOfMemory` is no longer in `ParseError` because
  parsing cannot fail that way any more. A string literal already has the
  required type; anything else is terminated by the caller, which is what GMP
  reads. GMP's parsing semantics are unchanged.
* `writeTo` on all three types, and `Rendered.text`, now return `[:0]const u8`,
  so rendered text can be parsed again with no copy in between.
* `OwnedString` records the text length, and its `deinit` passes `len + 1` to
  GMP's free function. GMP documents `free_function` as receiving "a
  previously allocated block of SIZE bytes" and releases its own strings that
  way (`gmp-impl.h`), and both `mpz_get_str` and `mpq_get_str` shrink their
  block to exactly the text plus its NUL. The old release passed 0, which the
  default `free` ignores and a real allocator would not.
* `zig/test/alloc_probe.c` remembers the size each live block was allocated
  with and counts releases that report a different one, so the free size is
  tested rather than assumed.
* The test module's C probe includes the public header by name, and the
  generated header is in the build cache rather than the source tree, so the
  build now passes the generated include directory to that module. Linking the
  artifact does not add include paths.

## 13. Facade corrections from the read-only review

* `probabPrime` passes the round count as the C `int` GMP declares, not a
  fixed-width Zig integer that had to be cast.
* `mpz_t`, `mpq_t` and `mpf_t` are one element arrays, so the `_mp_size`,
  `_mp_num` and `_mp_den` reads index element zero.
* `Rational.parse` does not canonicalise, because `mpq_set_str` does not. The
  documentation says that and the test proves it, canonicalising explicitly.
* `bitLength` returns `usize` instead of truncating GMP's `size_t` to `u32`,
  which panicked for values above 2^32 bits.
* Test-only repairs: the allocation probe's mismatch counter was declared
  under one name and used under another; `Division` and moved values were bound
  with `const` although `deinit` takes a mutable pointer; two call sites named
  facade methods that do not exist; the rational lifetime test asserted an
  absolute allocation count where an `mpq` owns two limb arrays; and the bit
  sequence in the facade exercise contradicted GMP's own semantics.
* The machine-word cutover and the removal of the numeric helper discussed in
  the first revision of this entry are settled in entry 14, which supersedes
  the rest of this entry.

## 14. Facade uses the target's C words, and the raw value is a C pointer

* The facade no longer takes or returns a fixed-width integer for anything GMP
  declares `unsigned long`, `signed long` or `mp_bitcnt_t`. The word methods
  are `setUnsignedWord`, `setSignedWord`, `toUnsignedWord`, `toSignedWord`,
  `fitsUnsignedWord` and `fitsSignedWord` on `BigInt`, and `setUnsignedWord`,
  `sqrtUnsignedWord` and `cmpUnsignedWord` on `Float`, all in terms of
  `c_ulong`; `Float.pow` takes `c_ulong` too, GMP's own exponent type. The
  `*_ui` and `*Ui` methods keep the names they mirror from GMP and take
  `c_ulong`; bit indices take `c.mp_bitcnt_t`; `probabPrime` takes the C `int`
  GMP declares; `bitLength` returns `usize`. No aliases are kept: the
  fixed-width spellings are gone rather than forwarded, and a value wider than
  one machine word is parsed or assembled through GMP's own entry points, never
  truncated into a word.
* `probabPrime` takes a C `int` for the round count, as GMP declares it.
* The complement is one method, `comAssign`, which is `mpz_com`; the second
  spelling, which GMP does not have, is deleted and its caller moved.
* A numeric helper that was not a GMP operation, a nibble swap, is deleted with
  its fixture. Keeping it meant maintaining a reimplemented algorithm in a
  binding; `gmp.c` is the escape hatch for anything the facade does not cover.
* `Rand` works in the native word throughout and adds no algorithm of its own.
  `nextBits` is `gmp_urandomb_ui` and `nextBelow` is `gmp_urandomm_ui` itself:
  the latter's own rejection loop maps any positive `n` uniformly, power of two
  or not, and `n == 1` returns 0. Entry 15 replaces the assertions that guarded
  their two conditions with ordinary comparisons and named errors.
* The raw GMP value is reached through GMP's own pointer typedefs. `mpz_t`,
  `mpq_t`, `mpf_t` and `gmp_randstate_t` are `typedef ... [1]`, so every
  accessor returns `&raw[0]`: `rawPtr()` yields the mutable
  `c.mpz_ptr`/`c.mpq_ptr`/`c.mpf_ptr`/`c.gmp_randstate_ptr`, and `rawSrcPtr()`
  yields the read-only source pointer of the same four types. All four facade
  types are converted: no call site forms `&self.raw` any more, and no cast is
  needed, because GMP's operand prototypes are const correct.

## 15. Translated pointers, rejected bounds and the recovery wave

Everything here follows from the same two facts about this tree, both read out
of source rather than observed from a run.

* `translate-c` makes a pointer **optional** only when the pointee is a
  function prototype or an opaque type
  (`lib/compiler/translate-c/Translator.zig`, the `.pointer` case of the type
  translator). Every other `T *` becomes a non optional `[ *c ]T`, which admits
  address 0 but is neither an optional nor an error union, so `orelse`,
  `== null` and unwrapping it are all rejected. GMP's `gmp.h` declares plain
  `char *` returns, so `mpz_get_str` and `mpq_get_str` come back as
  `[ *c ]u8`. `toOwnedString` on `BigInt` and on `Rational` now binds the
  result to an explicit `?[*c]u8` and tests *that*, so the documented null
  return is reachable without inventing a second pointer layer.
* The same translator renders a pointer to a function pointer as the optional
  `?*const fn (...) callconv(.c) void`. `mp_get_memory_functions` takes exactly
  that shape for its three out parameters, and the address of a local of that
  type is a `*?*const fn (...)`, which is a different Zig type with the same
  representation. `zig/memory.zig` therefore declares the one call it makes
  with that out parameter spelled as the exact pointer to the optional, so
  `&free_func` is passed unchanged. The C function is GMP's, unaltered, and
  `memory.zig` no longer imports the translated header at all.

Corrected in the same wave:

* `Rand.nextBits` and `Rand.nextBelow` return `Rand.Error!c_ulong`. The manual's
  two conditions are now ordinary comparisons reported as
  `error.TooManyBits` and `error.EmptyRange` rather than `std.debug.assert`,
  which disappears in a release build and hands a truncated bit count back as
  if it were the requested one. Both are refused before GMP is called, so a
  refused draw leaves the state where it was, and the test suite proves that.
* `zig/api_exercise.zig` drew from only one of two identically seeded states
  before comparing them, which compared two different positions of the
  Mersenne Twister stream and asserted that they were equal. Every draw is now
  taken from both states, in step.
* `zig/test/rational_float_random.zig` asserted
  `nextBits(32) < std.math.maxInt(u32)`, which is false whenever the draw is
  exactly `2^32 - 1` and is vacuous where `unsigned long` is 32 bits. The
  range is now stated as `2^32` in `u64`, which is the same claim on every
  checked target.
* `zig/test/alloc_probe.c` declared its size-mismatch counter under the same
  name as the function that reports it, which is a redefinition in C. The
  counter is `gmp_probe_free_size_mismatch_count`; the function keeps the name
  the Zig side calls.
* `build.zig` no longer passes `-DHAVE_ALLOCA=1` to the C compiler. The
  generated `config.h` defines it, `gmp-impl.h` includes that header, and the
  old comment claimed the opposite.
* `build.zig.zon` listed a `demo` path that does not exist in the 6.3.0 tree,
  next to the `demos` that does, and omitted `AUTHORS`, which `NOTICE.md` cites.
  The count comment above `zig/sources.zig`'s list said sixteen root sources
  where the list holds fifteen. The total then was 505; selecting the mpn
  sources the way `configure` does brings it to 498.
* `root.zig` re-exported the facade files themselves, so `gmp.BigInt` named a
  file namespace with no members instead of the `BigInt` struct it declares.
  It now exports that struct, for all four types.

## 7. `wasm32-wasi` is attempted, not delivered

`invalid.c` reports an invalid operation by raising `SIGFPE`
(`src/invalid.c:80`), `Makefile.am:285` compiles that file unconditionally, and
wasi-libc has no signal support: its `signal.h` refuses to be included at all
without `_WASI_EMULATED_SIGNAL`. So `zig build check` fails on
`wasm32-wasi` with four diagnostics and succeeds on the other five. Upstream's
`configure` has no wasm handling either.

The target is kept in the matrix, `zig build check -Dtarget=wasm32-wasi`
reproduces the failure, and CI runs one job per target with
`continue-on-error` on that one. Nothing in this package declares WebAssembly
support, and no substitute for `raise` was invented: a fake signal would be a
different library from the one upstream ships.

`zig build check` now honours `-Dtarget=`: without one it still covers all six
at once, and with one it covers only that target, so a CI failure names the
target that failed instead of reporting one aggregate result.

## 8. Zig API contract alignment — 2026-10-03

**Condition.** GMP `mpf` uses limb-based precision and truncation, not MPFR
or IEEE nearest-even rounding. Owner copies alias allocations and global
allocator hooks govern native values and allocated strings.

**Fix.** Correct precision, rounding and parsing-base descriptions. State
single-owner/copy rules, matching native releases, string size/sentinel duties,
input borrow fences and parse-error residue. Separate positive facade bases
from raw negative-base features; scope allocator-hook claims to compiled
code. Supply a complete executable module sequence without redundant linkage.
Synchronize these authored Zig/docs into MPFR's vendored provider.

**Verification and bound.** Standalone supplier, Zig 0.16.0, native Linux
x86-64: install, Debug/ReleaseSafe tests, smoke, package consumer and module
example pass. Compile-only `check` builds five targets and fails WASI because
the native signal path lacks the required WASI emulation configuration.
No native source/header, generated binding, allocator implementation or
provenance pin changed. No system-provider result is claimed.

## 16. Foundation contract migration: README, licence record and Nix packaging — 2026-10-04

**Scope.** Documentation and packaging metadata only. No upstream file was
touched, no native source, header, table or algorithm changed, no generated
input changed, and no test, fixture or example was added or removed. The build
files this entry describes (`build.zig`, `build.zig.zon`) belong to the native
delivery role; this entry records what its packaging contract is, not a change
to it.

**README.** `README.md` now follows the canonical order: current native-source
deviations, current native-build deviations with a link to the dated history in
this file, the current build/run/test matrix, and consumption. The Zig interface
documentation stays separate, in `README.zig.md`. Upstream's own README is
preserved twice: under its upstream name `README`, and as the byte-identical
`README.upstream.md` (SHA-256
`5e9f9325fd702bc4bcda27d7a78fea88a2a09fa39b4b15ac7b9b205e0863dc7e`).

**Licence of the fork's own files.** `FORK-LICENSE.md` records the owner's
direct authorization and the actual grant, `LGPL-3.0-or-later`, for everything
this fork adds: `build.zig`, `build.zig.zon`, `root.zig`, `include/`, `zig/`,
`consumer/`, `tools/`, `.github/`, `.gitignore`, the Nix and devenv files and
this documentation. The copyright in those files is held by the repository
owner; no upstream author is credited for them and no individual is named.
`README.upstream.md` is excluded from that grant because it is a copy of an
upstream file.

**NOTICE.md inventory corrected against the files, not from memory.** The
previous inventory called the upstream test suite and the demo programs
"GPLv2 or later". Every header in `tests/` and `tests/cxx/` says
`GPL-3.0-or-later` (`tests/misc/t-printf.c:1-13`, `tests/devel/README:1-13`),
and so do `demos/calc/`, `demos/factorize.c`, `demos/isprime.c` and
`demos/primes.c`; `demos/expr/` and `demos/perl/` are dual
`LGPL-3.0-or-later OR GPL-2.0-or-later`. Also recorded now, with anchors:

* `COPYING` and `COPYINGv3` are the same GPLv3 text differing in three lines
  (648, 667, 674: `http` versus `https`), so all four `COPYING*` texts are kept
  and all four digests are enforced;
* `install-sh:7-25` carries the X Consortium permission notice from
  X11R5/X11R6 `install.sh`, a permissive file inside an LGPL tree;
* `ltmain.sh:8-26` is GNU Libtool 2.4.6 under `GPL-2.0-or-later` with the Libtool
  linking exception, and `aclocal.m4:37-50` and `configure:29837-29850` carry
  the same Libtool notice inside their embedded text;
* `config.guess`/`config.sub` are dual, `configfsf.guess`/`configfsf.sub` are
  `GPL-3.0-or-later`;
* every generated `*/Makefile.in` carries three notices at once: the automake
  grant for the generated file, the notice of the `.am` it came from, and the
  embedded upstream notices;
* the manual is `GFDL-1.3-or-later` (`doc/gmp.texi:13-23`, and the prebuilt
  `doc/gmp.info` it produced), `doc/texinfo.tex` is `GPL-3.0-or-later`,
  `doc/version.texi` and `doc/stamp-vti` carry no notice at all;
* `demos/calc/calc.c:21-32` and `demos/calc/calc.h:21-32` add the Bison skeleton
  special exception, and `demos/primes.h` has no header but is included by
  `demos/factorize.c:27-29`;
* `gmp.pc.in` and `gmpxx.pc.in` carry no notice. `gmp.pc.in` is the template the
  build renders into the installed `lib/pkgconfig/gmp.pc`; `gmpxx.pc.in` is
  unused, because libgmpxx is not built. No `.pc` file is hand-written.

**Build options, as the native delivery role landed them.** Recorded here
because they are divergences from `configure`, not because this role wrote
them: `-Dlinkage=static|dynamic` selects the artifact, with `static` the
preserved default; `dynamic` compiles every object PIC, gives the shared object
libtool's own version and soname, and sets `__GMP_LIBGMP_DLL` to 1 in the
generated `gmp.h` so `__GMP_DECLSPEC` exports, while static keeps it at 0 and
leaves `config.h` identical. The installed closure is the library, the three
public headers, `lib/pkgconfig/gmp.pc`, the example, the four upstream licence
texts under `share/licenses/gmp/`, and upstream's `AUTHORS`, `NEWS` and
`README` under `share/doc/gmp/`. The library's external link closure is libc
only; the three host table generators that link `libm` are build-time programs
and are not part of the artifact. That is not a wholly static closure claim.

**Nix and the development environment.** `package.nix` is one uncurried
derivation taking `{ lib, stdenv, zig, linkage ? "static" }` and returning one
package; the variants are the entry points, which both build it with
`pkgs.callPackage ./package.nix { zig = pkgs.zig_0_16; ... }`. `flake.nix` pins
nixpkgs and exposes `packages.<system>.static`, `.shared` and `.default`, where
default keeps this fork's static policy; its dev shell is tools only. `devenv.nix`
is the canonical environment: tools only, with lazy `outputs.static` and
`outputs.shared` built from the same `package.nix` on demand
(`devenv build outputs.static`), and namespaced tasks `sdk:build`, `sdk:test`,
`sdk:test-release-safe`, `sdk:smoke`, `sdk:check`, `sdk:provenance`,
`sdk:consumer`. No scratch location, account or store path is written into any of
these files, and the caller's Zig caches are left alone.

The derivation is install-only (`dontConfigure`, `dontBuild`, a real
`installPhase`): it exports `ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR` under
the Nix-provided `TMPDIR` and runs one `zig build install` with
`-j"${NIX_BUILD_CORES:-1}"`, `-Dcpu=baseline`, one `-Doptimize=ReleaseFast`,
`-Dlinkage=<variant>` and `--prefix "$out"`, refusing to evaluate on a cross
platform rather than building for the wrong target. `-Dcpu` is declared and
consumed by `b.standardTargetOptions`, which this build calls, so it constrains
Zig's own codegen; GMP's own configuration is still derived from the target query
and the mpn path stays `generic` with `NO_ASM`. The derivation writes only the
four records the build graph does not — `NOTICE.md`, `FORK-LICENSE.md`,
`UPSTREAM.md`, `README.upstream.md` — into the same `share/licenses/gmp/`
directory the four upstream texts already occupy, so no path has two writers.

**Provenance gate.** `tools/provenance_gate.sh` additionally checks that
`README.upstream.md` is byte-identical to `README` and differs from
`README.md`, that `FORK-LICENSE.md` records the `LGPL-3.0-or-later` grant and
the owner's authorization, that `NOTICE.md` still carries the terms that are easy
to get wrong, that both entry points pin and inject the agreed inputs into the
one `package.nix`, that the four upstream texts are installed by the build and
the four fork records by the derivation, that no packaging file imports a
sibling, names a host path, reads host state or downloads anything, and that no
source, document or packaging file reintroduces a permissive claim for this
copyleft library. It still needs no Zig build.

**Verification and bound.** Every row of the README matrix that predates this
entry keeps its earlier dated receipt and is labelled as historical. Everything
this entry adds — the static and shared variants, the installed outputs, the
runtime-loaded path, the Nix derivations and the devenv shell — is
`PENDING-VERIFICATION`: this role ran no build, no test, no Nix evaluation and
no devenv invocation, and records no result for any of it. The only things
asserted as read are the file contents and digests cited above.

**Superseded in part, later.** That bound described this entry's own runs and is
kept as written. Entry 18 records the runs that came after it, which do cover
the static and shared variants and the installed outputs on this host; the
runtime-loaded path, the Nix derivations and the devenv shell are still
unexercised. Its installer-ownership sentences are superseded too: entry 24
moves the four fork records out of `package.nix` and into the build graph's own
install step, so `build.zig` writes every installed path and `package.nix`
writes none.

## 17. Per-file provenance record: `UPSTREAM.sha256` — 2026-10-04

**Scope.** Records and verification tooling only. No upstream file was added,
removed, renamed or edited, no native byte changed, no build, test, formatter
or linter was run for this entry.

**What was added.** `UPSTREAM.sha256`: a SHA-256 record of every one of the
2156 regular files of the pinned `gmp-6.3.0.tar.xz`, 16998222 bytes in total,
covering the portable core (`mpn/generic`, `mpz`, `mpq`, `mpf`, `printf`,
`scanf`, `rand`, the root-level library sources and the four root headers), the
1144 tuned assembly files under the 27 `mpn/<cpu>/` directories, upstream's own
test suite, the demos, the tuning programs, `mini-gmp`, `cxx/`, the manual, the
autotools scaffolding, the configuration and packaging templates, the four
licence texts and upstream's prose. Its header states the pin and the fact that
the detached signature is UNVERIFIED, the per-area counts, what is deliberately
absent from the record and why, and the commands to re-derive and re-check it.

**One finding worth recording.** GMP 6.3.0's release archive ships no
`.gitignore` at all — `.gdbinit` is its only dotfile — so the 51-line
`.gitignore` in this tree is entirely fork-authored and there is no upstream
digest for it and no deviation to record. Sibling SDKs in this workspace carry
an *edited* upstream `.gitignore` and therefore exclude it with a stated reason;
here the exclusion is simpler and the record's section 5 says so explicitly
rather than repeating the sibling wording.

`tools/provenance_gate.sh` now runs that record before any other check: it
requires the file, strips comments, requires every remaining line to be a digest
record, requires the record count to equal the count its own header declares and
to be at least the pinned tree's 2156, then runs `sha256sum -c`. It also requires
the record to keep naming the archive digest, the URL it came from and the
UNVERIFIED signature, requires upstream's `README` to be a record while the
fork's `README.upstream.md` is not, and refuses a record that names a
fork-authored path. The pre-existing licence, README, `UPSTREAM.md`, notice and
packaging checks are unchanged and still run; their numbering moved from 1-6 to
2-7.

**How the digests were obtained.** The archive was fetched again from
<https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz> into a scratch directory
outside this repository, its digest was checked against the pin *before*
extraction (2094196 bytes,
`a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898`), and every
per-file digest was measured from the extracted upstream tree with GNU coreutils
sha256sum 9.6, never from this working tree. Each digest was computed twice,
with `/usr/bin/sha256sum` and with the hashing tool the session resolves by bare
name; the two manifests were byte identical.

**Result.** 2156 records, 2156 OK, 0 FAILED. Comparing the archive's own path
list against the record gives 0 upstream paths unrecorded and 0 recorded paths
missing from the tree, so **the carried tree already matches the pinned upstream
bytes exactly and there is no divergence to report.** No native byte was edited
to achieve that; the tree was already clean.

**Bound.** The record is not tamper evidence against a change that edits a
native file *and* rewrites that file's line in `UPSTREAM.sha256`; a manifest
cannot contain the digest of what it polices. What it makes loud is the
ordinary case. Negative tests run on a scratch copy of this tree: a byte appended
to `mpz/add.c`, `gmp-impl.h`, `mpn/generic/add_n.c`,
`mpn/x86_64/alderlake/addmul_1.asm`, `gen-fib.c`, `tests/mpz/t-addsub.c`,
`tests/cxx/t-ops.cc`, `mini-gmp/mini-gmp.c`, `mpn/generic/gmp-mparam.h`,
`config.in`, `gmp-h.in`, `configure.ac` or `doc/gmp.texi`, a deleted
`COPYINGv3`, a deleted record, a record line replaced by a bare path, a fork path
added as a record, a deleted `UPSTREAM.sha256`, and a dropped `UNVERIFIED`
marker each failed the gate with a message naming the file or the problem; the
restored copy passed. The gate needs no compiler, no network and no Zig build.

## 18. One authorised native-C check exception, and the records that state it — 2026-10-04

**Scope.** The flag itself belongs to the build role; this entry records it, and
this documentation role changed `README.md`, `README.zig.md` and this file and
nothing else. No upstream file was added, removed, renamed or edited.

**The exception, and its exact width.** `build.zig:635-638` makes
`c_source_flags` carry `-fno-sanitize=function` in every mode but `Debug`, and
that one flag list is passed to all three native C source groups:
`sources.all`, the two generated tables and the generated `mpn` template
wrappers. `Module.sanitize_c` stays null, so Zig emits no `-fsanitize-c` flag at
all and the compiler's own default otherwise stands; the flag lands after the
module's own options on the C command line.

The reason is upstream's own code, left byte-for-byte. clang's `function` member
of undefined-behaviour detection writes an eight-byte `0xc105cafe` signature
plus a hash of the function type in front of every function entry and verifies
it at every indirect call; a `Debug` build carries no such signature, which is
why only the other three modes could reach it. GMP's `printf` dispatch cannot
satisfy that check: each of the four slots of `struct doprnt_funs_t` is declared
with a `void *` first parameter (`gmp-impl.h:4540-4543`) and is filled by
casting a function whose first parameter is a concrete struct pointer. All five
initializers do that: `printf/snprntffuns.c:152-158`,
`printf/sprintffuns.c:89-94`, `printf/vasprintf.c:103-108`,
`printf/printffuns.c:75-79` and `printf/obprntffuns.c:65-69`, and
`printf/printffuns.c:76` casts libc's own `vfprintf`. Converting between those
function pointer types is undefined behaviour in C, and it is the only thing
this check can see here, so the first indirect call through the table —
`DOPRNT_FORMAT (last_fmt, last_ap)` at `printf/doprnt.c:612` — traps on it
before a character is formatted. **This is a function-type check exception and
nothing else: it is not a varargs ABI repair, not a `va_list` forwarding
change, and not a switch for C instrumentation as a whole.**

**Authorisation, and what stayed on.** The repository owner authorised this one
flag, for GMP's own native C only. No `.sanitize_c = .off` was used, nothing was
suppressed in source, no C check other than `function` was disabled, no Zig
safety check was touched, and no optimize mode was changed.

**Observed.** Eight native runs on the Linux x86-64 host — `zig build smoke
test` once per optimize mode per linkage — each exit 0 and each ending in
`Build Summary: 37/37 steps succeeded; 47/47 tests passed`, with the example's
own last line `all example results verified` and an install step that installed
the library, `lib/pkgconfig/gmp.pc`, the four upstream licence texts,
`AUTHORS`/`NEWS`/`README` and `gmp-example`:

| cell | receipt |
| --- | --- |
| `Debug` / `static` | `local://foundation-resumed-gmp-native-static-Debug.json` |
| `ReleaseSafe` / `static` | `local://foundation-resumed-gmp-native-static-ReleaseSafe.json` |
| `ReleaseFast` / `static` | `local://foundation-resumed-gmp-native-static-ReleaseFast.json` |
| `ReleaseSmall` / `static` | `local://foundation-resumed-gmp-native-static-ReleaseSmall.json` |
| `Debug` / `dynamic` | `local://foundation-resumed-gmp-native-dynamic-Debug.json` |
| `ReleaseSafe` / `dynamic` | `local://foundation-resumed-gmp-native-dynamic-ReleaseSafe.json` |
| `ReleaseFast` / `dynamic` | `local://foundation-resumed-gmp-native-dynamic-ReleaseFast.json` |
| `ReleaseSmall` / `dynamic` | `local://foundation-resumed-gmp-native-dynamic-ReleaseSmall.json` |

The width of the exception was measured on an isolated probe rather than on this
tree, because that is what the question needed: a C program that casts a
function whose first parameter is `struct probe *` to `int (*)(void *)`, keeps
it in a `volatile` pointer and calls through it, built `-OReleaseSafe` at Zig's
default C instrumentation, exits `SIGILL` (exit -4,
`local://foundation-resumed-native-callback-checked-run.json`); the same source
with `-fno-sanitize=function` added to the C flags prints `callback=42` and
exits 0 (`local://foundation-resumed-native-callback-narrow-exception-run.json`);
and that same narrowed binary still exits `SIGILL` (-4) on its signed-overflow
path (`local://foundation-resumed-native-callback-narrow-exception-other-check-run.json`).
So the flag removes the one check and leaves the others standing.

`sha256sum --check --strict UPSTREAM.sha256` over this tree exits 0 with every
pinned upstream file `OK`
(`local://foundation-resumed-gmp-pinned-byte-integrity.json`), which is the
evidence that the exception cost no upstream byte.

**Bound.** No receipt in this entry covers a Nix build, a devenv invocation, an
installed C consumer, a fetched consumer, the cross-platform matrix, or a
`-Druntime=true` run. Those remain `PENDING-VERIFICATION`, and `README.md`'s
support matrix now separates the eight verified native cells from them instead
of listing the native cells as unverified. The flake's three package entry
points were evaluated and produced real drvPaths
(`local://foundation-resumed-gmp-nix-entrypoint-evaluation.json`), which is
evaluation and not a build, and is recorded as such.

**Installer ownership, re-read against the current sources.** Entry 16 states
that the derivation writes only the four records the build graph does not. That
still matches what the sources say, and `README.md` now says the same thing in
one place instead of leaving the two to be inferred: `build.zig`'s
`addInstalledRecords` installs the four upstream texts under
`share/licenses/gmp/` and `AUTHORS`, `NEWS`, `README` under `share/doc/gmp/`;
`package.nix:78-81` installs `NOTICE.md`, `FORK-LICENSE.md`, `UPSTREAM.md` and
`README.upstream.md` into that same `share/licenses/gmp/` directory; and
`tools/provenance_gate.sh:193-202` checks both halves, so no path has two
writers and neither half can be dropped quietly.

**Superseded by entry 24**, which moved those four records out of
`package.nix:78-81` and into `build.zig`'s `addInstalledRecords`, so the split
this paragraph re-read no longer exists and `tools/provenance_gate.sh` names
all eight licence-directory records against `build.zig`. It is kept as what the
sources said before that entry.

**Runtime loading, as the two READMEs now describe it.** Both files previously
stated that the loader core and this package's runtime wiring were owned outside
this repository and that no runtime API existed to call. That is no longer true
of the tree: `runtime/loader.zig`, `runtime/library.zig`, `runtime/graph.zig`
and `runtime/generate.zig` are in it, `-Druntime=true` builds the dispatch, and
the module publishes `load`, `loadedSource`, `providerRequest`,
`providerFromCEnvironment`, `providerVersion`, `providerErrno` and
`providerBitsPerLimb`. `README.zig.md` now documents that surface and
`README.md` what GMP requires of a provider. The route itself still has no
receipt, so both files say that plainly instead of claiming it works.

## 19. The exception's width, re-measured against source; and the vendored copy MPFR still builds — 2026-10-04

**Scope.** Records and the build graph's own comment. `build.zig`'s `c_source_flags`
is unchanged — the flag was already present and already at the right width — and
this entry changed the comment above it, `README.md`, this file and
`FORK-NOTES.md` note 36, and nothing else. No upstream file was added, removed,
renamed or edited, no native byte changed, no build, test, smoke, formatter,
Nix evaluation or devenv invocation was run.

**What was already there, confirmed at `build.zig:635-638`.** `c_source_flags`
carries `-fno-sanitize=function` in every mode but `Debug`, and that one list is
passed to all three `addCSourceFiles` calls on `library.root_module`: the
library units (`sources.all`), the two generated tables and the generated `mpn`
template wrappers. `Module.sanitize_c` is left null and is never assigned
anywhere in this tree, and no other flag is suppressed. There was nothing to
apply, and the open item was stale.

**The comment's citation of the trap was wrong in one place and incomplete in
another.** `build.zig` cited `printf/sprintffuns.c:88-92`; the initializer is at
`:89-94`. `README.md` and this file named four initializers where the tree has
five: `printf/vasprintf.c:103-108` (`__gmp_asprintf_funs`) was missing, and
`printf/printffuns.c:76` casts libc's own `vfprintf` rather than a GMP function.
All three documents now name the same five. This is a citation correction, not a
behaviour change: `printf/vasprintf.c` was already inside `sources.all`
(`zig/sources.zig:352`), so it was already carrying the flag.

**Three C sites deliberately keep the check.** `generatorProgram`
(`build.zig:935-953`) compiles the seven host `gen-*` programs at a fixed
`ReleaseSafe` with no flags at all, and `runtime/graph.zig:371-375` compiles the
fork's `runtime/sync.c`, and `addTests` (`build.zig:1034-1055`) compiles the
fork's `zig/test/alloc_probe.c`. Reading those sources: none of the seven generators
nor the `bootstrap.c` they include converts a function pointer — the only casts
in them are object-pointer casts, which this check does not instrument — and
`sync.c` declares no function pointer at all, being weak wrappers over one
`SRWLOCK`/`pthread_mutex_t` and one condition variable per prefix. So no flag was
added to any of them, and the comment now says so instead of leaving the
distinction implicit.

**Bound on this SDK.** Nothing here changes what a consumer sees. The generated
`gmp.h` and `gmp-mparam.h` are rendered from `gmp-h.in` and the target's
parameters with no reference to `c_source_flags`; `gmp.pc` is rendered from
`gmp.pc.in` with `prefix=${pcfiledir}/../..` (`zig/config_gen.zig:562-565`), so
its `Cflags`/`Libs` are unchanged and still relocatable; `__GMP_LIBGMP_DLL` and
the libtool version numbers are untouched; and no exported symbol or ABI changes.
MPFR, or any other C consumer of an installed prefix, needs no matching flag and
no migration.

**The closure that does need a decision: `mpfr/vendor/gmp`.** `mpfr/build.zig.zon:16-20`
declares `.gmp = .{ .path = "vendor/gmp" }` — MPFR does **not** consume this
SDK, it vendors a separate GMP 6.3.0 snapshot. That snapshot's
`vendor/gmp/build.zig:305-323` compiles the same three native C groups with
`flags = &.{"-D__GMP_WITHIN_GMP"}` and carries no `-fno-sanitize=function`
anywhere, while carrying the identical trap: its `gmp-impl.h:4540-4543` has the
same four `void *`-first typedefs and its `printf/` has the same five cast
initializers at the same line numbers. `mpfr/package.nix:11` defaults to
`optimize ? "ReleaseSafe"`, so MPFR's shipped Nix output builds that libgmp with
clang's default C instrumentation and the `printf` trap is reachable. This is
`SOURCE-CONFIRMED` from those files and not observed from a run: no MPFR build
was made here and the sibling was not edited. The two questions belong to the
MPFR role: whether that snapshot is refreshed from this SDK's graph, and whether
MPFR keeps vendoring GMP at all when this one is a declared path dependency.

**Status.** `PENDING-VERIFICATION`. The corrections in this entry are
source-confirmed; no gate observed them, and none was run.

## 20. The runtime route was requiring twenty C library names from the provider — 2026-10-04

**Scope.** `runtime/graph.zig`, `zig/test/known_answers.zig`,
`zig/test/parsing.zig`, this file and `FORK-NOTES.md` note 37. No upstream file
was added, removed, renamed or edited, no native byte changed, no generated
header, table, algorithm or test expectation changed, no build, test, smoke,
formatter, Nix evaluation or devenv invocation was run, and the authorised
`-fno-sanitize=function` exception (entry 18) is unchanged.

**Symptom.** Both `-Druntime=true -Doptimize=ReleaseSafe` gates failed with
`1 pass, 39 fail, 7 crash` (47 total). The example exited 1 with
`error: MissingSymbol`; thirty-nine tests failed with that error propagated
out of `bootstrap.ensureLoaded`; the remaining seven died on
`panic: gmp: mpz_init was called before this module was loaded`. The other six
loaded gates and all eight native gates passed with the same provider
(`gmp-shared/lib/libgmp.so`).

**Cause, first half: the required table held glibc's `_FORTIFY_SOURCE`
helpers.** `include/gmp_all.h` pulls in `<stdio.h>` and, through `<obstack.h>`,
`<string.h>`. When the translator is given `_FORTIFY_SOURCE`, those two headers
declare twenty helper functions that are the C library's own
(`__printf_chk` and its `fprintf`/`vprintf`/`vfprintf`/`dprintf`/`vdprintf`
siblings, `__fgets_chk`, `__fread_chk`, `__fread_unlocked_chk`,
`__explicit_bzero_chk`, `__strlcpy_chk`, `__strlcat_chk`, and the five
`__*_alias` and three `__*_chk_warn` wrappers glibc declares through
`__REDIRECT`).
`runtime/graph.zig`'s `libc_noise` did not name them, so `runtime/generate.zig`
classified each as GMP's and put all twenty in the load-time required table.
Twelve of the twenty are `libc.so.6` exports and were resolved only because
`dlsym` on the provider's handle also searches its dependencies. The other
eight are exported by neither `libgmp.so`, `libc.so.6` nor `ld-linux`, so no
provider can supply them.
The first
unsatisfiable lookup in table order is `__fgets_alias`, so the load returned
`MissingSymbol`, published nothing, and every routed call then hit the
pre-load panic.

**Why only ReleaseSafe.** The generated dispatch is a function of the
translation, and the translation is a function of the optimize mode. Measured
from the four dispatches this build wrote on 2026-10-04: `Debug`, `ReleaseFast`
and `ReleaseSmall` translate with no `_FORTIFY_SOURCE` declaration at all
(355 required symbols each), while `ReleaseSafe`, which `translateC` passes on
as `-O2`, translates 20 more. So the defect was present in exactly one mode,
and the three passing modes were passing because a provider that happens to
link libc satisfies the twelve of the twenty libc does export.

**Fix.** The twenty names are added to `libc_noise`, which is what that list is
for: `runtime/library.zig` already states that the C library is not routed,
and the linked configuration already keeps these declarations direct out of
the same translation. No symbol was added to `provider_optional` (its absence
would become a nullable field and a by-name stop rather than a refusal at load
time), none was added to `provider_excluded`, and no required GMP symbol was
dropped: the table goes from 375 entries to exactly the 355 `__gmp*` exports
the other three modes already required, all of which
`gmp-shared/lib/libgmp.so` exports.

**Cause, second half: seven tests reached GMP without loading it.**
`zig/test/bootstrap.zig` states that every test touching GMP calls
`ensureLoaded` first. Six tests in `known_answers.zig` ("catalan numbers",
"modular exponentiation matches an independent u64 modpow", "probabilistic
primality on known primes and composites", "gcd and lcm of known integers",
"squares at the signed 32-bit boundary", "a negative value's size helpers have
the hand checked answers") and one in `parsing.zig` ("formatting round trips
through every base") did not. They were passing only because an earlier test
in the same binary had already published the table, so the suite's result
depended on declaration order and a filtered run of any one of them would have
panicked. Each now calls `try bootstrap.ensureLoaded();` first, which is what
the other thirty-nine do. No expectation was weakened: a test that cannot load
its provider now fails with that error instead of aborting the process.

**Also corrected here.** The count in `runtime/graph.zig`'s own header comment
said `libc_noise` held 566 names. It held 555 before this entry and holds 575
after it; the number in the comment is now 575.

**Not touched, and still open.** `runtime/graph.zig` line 52 and
`runtime/library.zig` both say the expanded header gives "294 distinct
symbols" on a glibc target, while the generated dispatch required 355. That
sentence was not re-derived here, because re-deriving it needs a translation
sweep this entry did not run; it is reported, not changed.

**Status.** `PENDING-VERIFICATION`. Every claim here is `SOURCE-CONFIRMED`
from the generated dispatches, the translated sources and the provider's own
dynamic symbol table. No gate observed the repair and none was run.

## 21. System-library mode was missing the loader core, and dropped `-Druntime` — 2026-10-04

**Scope.** `build.zig` and this file. No upstream file, no native byte, no
generated header, table, algorithm, test expectation or upstream test was
touched, no CI workflow and no `build.zig.zon` entry was changed, no build,
test, smoke, formatter, Nix evaluation or devenv invocation was run, and entry
18's authorised `-fno-sanitize=function` exception is unchanged.

**Finding one: `-fsys=gmp` could not compile.** `root.zig:122` declares
`const rt = @import("rt")` at container scope, which is where a linked
configuration's `LoadSource` and `LoadError` come from. Only two places ever
supplied that import: the bundled linked branch at `build.zig:709-710`, and
`addInstallFacade`, which returns null for `.system` and so is not reached in
that mode either. `makeSystemLibrary` added `c` and nothing else. A module with
a container-scope import that has no matching module import does not analyze
until something references it, so the mode could appear to build and then fail
the moment a consumer named `gmp.LoadSource` or `gmp.LoadError` — the two types
`README.md:319-325` and `README.zig.md:405-416` tell a consumer it can name.
`makeSystemLibrary` now calls `runtime.createCoreModule(b, target, optimize)`
and adds it as `rt`, which is the same one-line wiring the bundled linked branch
does and keeps the promise in `runtime/graph.zig`'s doc that a linked build
costs two declarations and no code.

**Finding two: `-fsys=gmp -Druntime=true` exited 0 having built the wrong
route.** `makeLibrary` forwarded `runtime_loaded` only to
`makeBundledLibrary`; the `-fsys=gmp` branch returned `makeSystemLibrary`
without it. The option was accepted, dropped, and the build linked the
installed library and reported success — a caller (and `consumer/build.zig`,
which forwards both options) would record a green exit as proof of the loaded
route it did not build. `makeLibrary` now refuses the pair at configure time
with a panic naming both options and the reason.

**Why a refusal and not a new capability.** Turning system-library mode into a
third runtime-loading configuration would mean generating a dispatch from the
installed `gmp.h` and deciding where that library is loaded from, which is a
feature with its own ABI statement and its own gates. This fork's rule is that
a configuration is asked for explicitly and never substituted: there is no
fallback between configurations and no automatic load, so a request that
cannot be honoured is refused by name. Both loaded linkage routes are
untouched: `-Druntime=true -Dlinkage=static` and `-Druntime=true
-Dlinkage=dynamic` both still reach `makeBundledLibrary` with `runtime_loaded`
forwarded, and nothing in this entry changes what either one builds.

**Status.** `PENDING-VERIFICATION`. Both repairs are `SOURCE-CONFIRMED` from
`build.zig`, `root.zig` and `runtime/graph.zig` read as written. No gate
observed them and none was run.

## 22. The dependent could not build the system-library configuration — 2026-10-04

**Scope.** `consumer/build.zig`, `build.zig`, `README.zig.md` and this file.
No upstream file, no native byte, no generated header, table or algorithm, no
test expectation, no CI workflow and no `build.zig.zon` entry was touched. No
build, test, smoke, formatter, Nix evaluation or devenv invocation was run,
and entry 21's two repairs are unchanged.

**Finding: `-fsys=gmp` aborted in the dependent.** Observed from the parent as
`cd gmp/consumer && zig build run -fsys=gmp -Dlinkage=dynamic -j8`, exiting 1
on `unable to find artifact 'gmp'`, listing `gmp-example` as the one available
artifact. `consumer/build.zig` linked `gmp_dep.artifact("gmp")` whenever
`-Druntime` was not set, and that name resolves only against the dependency's
install steps (`std/Build.zig:1943-1959`). A system build compiles no library
and installs none, so the name is absent there by design and the call was a
panic rather than a link. Nothing was wrong with the dependency: the same run
proves it took the system branch, because `gmp-example` is the only artifact
that graph installs. The call is now guarded by the configuration, and
skipping it loses nothing — `gmp_dep.module("gmp")` already carries the
installed library, because the dependency puts `gmp` on the translated `c`
module it imports and `Step.Compile` puts every module in a compilation's
graph on that compilation's link line (`std/Build/Step/Compile.zig:1080-1088`).

**Finding: the dependent pinned a default the user never asked for.** It
declared `linkage` as `orelse std.builtin.LinkMode.static` and forwarded that,
and `runtime` as `orelse false`. A forwarded option arrives at the dependency
as an explicit request it cannot distinguish from the user's own, because
`std.Build.dependency` records a null forwarded option as no entry at all
(`userInputOptionsFromArgs`, `std/Build.zig:421-428`, with `b.option` returning
null for an absent one at `:1167`). So under `-fsys=gmp`, where the option
names the kind of *installed* library and the dependency's own default is
dynamic — `Module.linkSystemLibrary`'s (`std/Build/Module.zig:359`) — the
dependent forced a static request and would then fail to link against a host
shipping only `libgmp.so`, which is the common case and reads as a broken
system library rather than as a wrong default here. Both options are now
nullable and forwarded exactly as given, so each side applies its own default
and nothing is overridden silently.

**The selection is read, not forwarded, and nothing was invented for it.**
`-fsys=gmp`, `-fno-sys=gmp` and `--system` are the toolchain's own system
library integration. The build runner records them in
`b.graph.system_library_options` before any package's `build` runs
(`lib/compiler/build_runner.zig:169-175,319-322`), and every `std.Build` in one
process shares that one `Graph`: `createChildOnly` sets `.graph =
parent.graph` (`std/Build.zig:352`). The dependent therefore calls
`b.systemIntegrationOption("gmp", .{})`, the same function and the same entry
the dependency reads, and gets the identical answer. No `-Dfsys` option was
added: a second spelling of a setting the toolchain already resolves would be
a second thing to disagree with the dependency about. This is not a nested
process — `b.dependency` runs the dependency's `build` in the same process
against the same graph, so there is nothing to forward and nothing that
forwarding could carry.

**Also corrected here.** `Library` carried a `system` payload holding the
linkage choice, and a `Library.link` arm for it. Both were unreachable:
`addInstallFacade` returns null for `.system` before any link call, and it is
reached only when `needsBothLoaders` is true, which needs an artifact that
system mode does not produce. The union now says what it is — system mode
compiles nothing and links through the translated module — and `link` is a
method of `Bundled`, where it is reachable. Left in place it read as a second
system link path, and is the kind of statement that produced the confusion
above.

**What a dependent must still do.** In system-library mode it must not link
`dep.artifact("gmp")`, because there is none. Everything else it does is
unchanged: the module, the facade and the complete translated C API are the
same in both configurations.

**Status.** `PENDING-VERIFICATION`. Every claim here is `SOURCE-CONFIRMED`
from `consumer/build.zig`, `build.zig` and the toolchain sources named above,
read as written. No gate observed the repair and none was run.

## 23. The bundled BSD families could not translate the aggregate header — 2026-10-04

**Scope.** `build.zig`, `FORK-NOTES.md` and this file. No upstream file, no
native byte, no generated header, table or algorithm, no test expectation, no
CI workflow, no `build.zig.zon` entry and no `include/gmp_all.h` line was
touched: the aggregate translation unit is still that file, read whole. No
build, test, smoke, formatter, Nix evaluation or devenv invocation was run, and
entries 21 and 22 are unchanged.

**Finding: fourteen targets failed in the translation step, not in the C
build.** The libgmp sources compile for every one of them, because that
compilation is clang's. The failures were in the `addTranslateC` step, which
hands `include/gmp_all.h` to Aro, and the aggregate reaches the target's own
`<stdio.h>` and `<stdarg.h>` — the two includes `gmp_all.h` exists to make the
stdio and `va_list` declarations visible to a translation at all. Nine NetBSD
targets failed on `_Pragma`, three OpenBSD targets on a conflicting `size_t`
and two OpenBSD mips64 targets on missing endian predefined macros.

**Cause, per family, read from the headers.** NetBSD's
`generic-netbsd/sys/cdefs.h:408-424` builds `__BEGIN_PUBLIC_DECLS` out of
`_Pragma("GCC visibility push(default)")` and `__END_PUBLIC_DECLS` out of
`_Pragma("GCC visibility pop")`, and `:431-432` makes `__BEGIN_DECLS` and
`__END_DECLS` those; `stdio.h` opens a declaration block with `__BEGIN_DECLS`
on sixteen lines, and Aro's `#pragma GCC` handler implements only `error`,
`warning`, `diagnostic` and `poison`
(`compiler/aro/aro/pragmas/gcc.zig:26-31`, with everything else taking the
`unknown_gcc_pragma` path at `:108-109`). On 32-bit OpenBSD the only textual
difference from the 64-bit targets, which translate today, is the width of
`long`: the per-arch `_types.h:123` of `x86-openbsd-none/machine`,
`arm-openbsd-eabi/arm` and `powerpc-openbsd-eabihf/powerpc` each make
`__size_t` an `unsigned long`, where Aro's own `size` is an `unsigned int` for
every 32-bit target and an `unsigned long` for every 64-bit one
(`compiler/aro/aro/TypeStore.zig:2148-2157`); `stdio.h:49-52`,
`sys/types.h:171-174` and `stddef.h:47-50` each open their own
`typedef __size_t size_t;` behind `_SIZE_T_DEFINED_`. On OpenBSD mips64,
`machine/endian.h` is `<mips64/endian.h>`, which hard-`#error`s unless
`__MIPSEL__` or `__MIPSEB__` is predefined
(`generic-openbsd/mips64/endian.h:32-41`), and Aro's MIPS branch defines only
`__mips__` and `_mips` (`compiler/aro/aro/Compilation.zig:635-642`). All three
are Aro disagreeing with the target's own preprocessor about the target's own
headers, which is one problem with three faces.

**Repair: the target's own preprocessor runs first, on the same target, the
same include path and the same aggregate.** `aggregateRoute` (`build.zig`) keys
on the OS tag — `.netbsd` and `.openbsd` — and not on a list of triples, because
each family shares the one header and the one cause and a list would quietly
stop covering the next architecture in it. On those two families
`preprocessedAggregate` runs `b.graph.zig_exe cc -E -dD`: the compiler running
the build script is the same pinned one the C core is compiled by, so the
target, the include path and the widths are the ones the library is built with.
`-dD` is what keeps GMP's own macros: `gmp.h` publishes `GMP_LIMB_BITS`,
`GMP_NUMB_BITS`, `GMP_NAIL_BITS` and the `GMP_VERSION_*` triple as macros, and
`gmp_all.h` gates the whole stdio and `va_list` family on `FILE` being defined
and on `va_start` being a macro, so a dump of used macros only would take the
constant set with it. `-MD` with `-MF` is what makes the discovered headers this
step's own inputs, because a `-I` directory argument contributes only its
resolved path and its step dependency to a run step
(`std/Build/Step/Run.zig:465-471`); the generated `gmp.h` is named as a
dependency in its own right as well, so the edge is in the graph and not only
in the manifest. What the translator then reads is that preprocessed file
instead of the header, and nothing else about the step changes.

**Nothing is filtered, renamed or substituted, on either route.** The
preprocessor line carries no `-std=` and no `-D` at all: a macro put there
would decide a conditional in a file whose job is not to decide it, and the
translation has to describe the same `gmp.h` a consumer reads, so
`__GMP_WITHIN_GMP` stays where it belongs, on the library's own sources. Every
`#include` in `gmp_all.h` is still resolved, every conditional settled and every
declaration still reaches `gmp.c`, including the obstack pair that
`gmp_all.h:28-37` exists to keep visible. The same include root is added to
both the preprocessor and the translation step, so `<gmp.h>` resolves to the
same header on either route.

**Targets bound.** Every other OS family keeps Aro: `aggregateRoute`'s `else`
arm is the old behaviour verbatim, and FreeBSD in particular keeps
`__BEGIN_DECLS` as plain tokens (`generic-freebsd/sys/cdefs.h:64-70`) so it is
given nothing it did not have before. `-fsys=gmp` is unchanged in what it
reads — no `-I` is added there, so `<gmp.h>` still resolves through the target's
own search path and still describes the installed library — and both linkage
modes, the linked configuration and the runtime-loaded dispatch are untouched:
`aggregateRoute` selects a front end for the same `Step.TranslateC` every route
already used. No ABI, exported symbol or `gmp.pc` content changes in any
configuration.

**Boundary left standing, recorded rather than papered over.** Hexagon is in
neither branch and cannot be: `zig/config_gen.zig:121-170` has no pointer width
for it and panics with `gmp: unsupported architecture; add its pointer width to
zig/config_gen.zig` while the configuration is derived, which is before this
step is reached. A Hexagon target therefore still fails, for that reason and
not this one, and nothing here changes it.

**Status.** `PENDING-VERIFICATION`. Every claim here is `SOURCE-CONFIRMED` from
`build.zig`, the Zig 0.16.0 libc headers and the Aro sources named above, read
as written. No gate observed the repair and none was run.

## 24. A native install left this fork's own licence records behind — 2026-10-04

**Scope.** Packaging and records only. `build.zig` gained one constant,
`fork_record_files` (`build.zig:128-141`), and one changed line in
`addInstalledRecords` (`build.zig:1000-1007`); `package.nix` lost its copy loop
and the comment that described it; `tools/provenance_gate.sh:193-203` had its
licence-record check retargeted to the single owner; and `NOTICE.md`,
`README.md`, `README.zig.md`, this file and `FORK-NOTES.md` 41 were corrected.
No upstream file was added, removed, renamed or edited, no native byte changed,
no ABI, exported symbol or `gmp.pc` content changed in any configuration, and
no build, test, smoke, formatter, gate, Nix evaluation or devenv invocation was
run for this entry.

**Condition, read from the sources.** `addInstalledRecords` installed
`licence_files` — the four upstream grants — into `share/licenses/gmp`, and
`metadata_files` — `AUTHORS`, `NEWS`, `README` — into `share/doc/gmp`, and
nothing else. The four records this fork authors (`NOTICE.md`,
`FORK-LICENSE.md`, `UPSTREAM.md`, `README.upstream.md`) were written by
`package.nix:78-81` alone. The two installed trees were therefore not the same
tree: a Nix package carried this fork's grant, its authorization and its
provenance, and a plain `zig build install --prefix DIR` carried upstream's
only. That is the case in which a recipient of the native prefix gets a
`libgmp` with no statement of the terms this fork applies to the files it
added, and it is why the split was recorded as a decision in three documents
instead of closed.

**Fix.** The build graph is the single owner. `fork_record_files` is a third
list beside the other two, and `addInstalledRecords` installs it through the
same loop and the same destination expression as `licence_files`, so the fork's
records cannot be routed to a different directory than the grants they belong
with, nor take a mode that differs from it. `package.nix` keeps its single
`zig build install` and now writes no path of its own, so a native prefix and a
Nix package are the same tree. `tools/provenance_gate.sh` names all eight
licence-directory records against `build.zig` instead of splitting the check
between two files, so the set that has to reach a recipient cannot lose a
member quietly.

**What did not change.** The four upstream grant texts still install from the
same `b.installFile` call to the same paths, so their contents, mode and
installation are untouched. `-Dlinkage` keeps static as its default, `-Dcpu` and
`-Doptimize` are read the same way, and the library, the three public headers,
`lib/pkgconfig/gmp.pc`, `gmp-example` and the `share/doc/gmp` records are
untouched; `addInstalledRecords` is still called under the same `if (install)`.

**Status.** `SOURCE-CONFIRMED` from `build.zig`, `package.nix` and
`tools/provenance_gate.sh` read as written: which records the install step now
names, and which paths the derivation no longer writes. Nothing here is observed
from a run. That a fresh install actually carries all eight records, and that
they are byte-identical to the tree the derivation used to write, are
`PENDING-VERIFICATION` for the next install to compare.

## 25. Every `devenv` task now locates this SDK's own directory, names `-j8`, `--summary all` and an external cache — 2026-10-04

**Scope.** `devenv.nix` only, plus this entry. No build file, no Zig surface, no
native byte, no digest record, no linkage default and no `package.nix` line was
touched, and **no task was renamed**: the seven names are the ones this SDK has
always published (`README.zig.md` §table, entry 16).

**What changed.** Five `let` bindings — `sdkRoot` (`builtins.toString ./.`),
`sdkRootArg`, `consumerRootArg`, and the two `cd` helpers `inSdk` /
`inConsumer` — and one shared preamble, `requireExternalCache`. Every `exec`
body now opens with its own `cd` followed by that preamble, and every
`zig build` route now reads
`zig build [step] [--prefix …] --cache-dir … -j8 --summary all`: `sdk:build`
(`devenv.nix:117`), `sdk:test` (`:126`), `sdk:test-release-safe` (`:134`),
`sdk:smoke` (`:145`), `sdk:check` (`:155`) and `sdk:consumer` (`:175`).
`sdk:provenance` (`:164`) keeps only its `cd`: it runs sha256sum, grep, sed, wc
and cmp and reaches no compiler. Before this entry no body named a directory, a
cache or a job count, so a task inherited the caller's working directory and
left Zig to write `.zig-cache/` and `zig-out/` into this checkout.

**Why `--prefix` is on three routes and not on three others.** It follows the
step graph rather than the step name. `sdk:build` names the install step itself;
`sdk:smoke` reaches it because `build.zig:238` makes the smoke run depend on
`b.getInstallStep()`; `sdk:consumer` reaches its own package's because
`consumer/build.zig:142` makes that run depend on the same call. `sdk:test`,
`sdk:test-release-safe` and `sdk:check` hang on compile and run steps alone
(`build.zig:246-251`, `build.zig:333-336`) and install nothing, so they name
none.

**Where the cache goes, and when it is decided.** A caller's exported
`ZIG_LOCAL_CACHE_DIR` and `ZIG_GLOBAL_CACHE_DIR` are its own and are never
overwritten; an unset one is completed from `$XDG_CACHE_HOME`, then from
`$TMPDIR`, reusing this SDK's own existing fallback names (`package.nix:66-67`),
and with neither naming a location the body prints on stderr and exits
non-zero rather than falling back to `.zig-cache`, `/tmp` or `/var/tmp`. **The
fill is in the body, not only in a shell hook**: `devenv tasks run --mode single`
starts a generated program that never sources one, so a fill that lived in
`enterShell` alone would leave that program building into this checkout. The
consumer is given its own cache directory and its own prefix, because it builds
in `consumer/` and a default `.zig-cache` there would be a second one inside
this checkout. `AGENTS.md`:157-158 asks for `-j8`, `--cache-dir` and
`--summary all` on each library and consumer build, and `devenv tasks run` takes
no trailing argument, so no flag can arrive from outside once this file has been
evaluated.

**Status.** `SOURCE-CONFIRMED` from the file as written: which routes reach
`zig build`, which of those install, and which flags and locations each names.
**No `devenv`, `nix`, `zig` or `git` command was run against the tree after this
change, and no receipt is claimed for it.** That every task now runs from this
directory, keeps both caches outside it and builds with eight jobs is
`PENDING-VERIFICATION` for the next acceptance gate.

## 26. Three published statements contradicted the code beside them, and CI installed into the checkout — 2026-10-04

**Scope.** `consumer/build.zig`, `runtime/library.zig`, `README.zig.md`,
`.github/workflows/ci.yml`, `FORK-NOTES.md` notes 42 and 43, and this entry. No
upstream file, no native byte, no generated header, table or algorithm, no test
expectation, no `build.zig` or `devenv.nix` line, no linkage default and no
digest record was touched. No build, test, smoke, formatter, CI run, Nix
evaluation or devenv invocation was made.

**What changed.**

* The quick start in `README.zig.md` declares the `runtime` option, forwards it
  to the dependency unchanged and guards the artifact link on it as well as on
  `-fsys=gmp`. It guarded only the system-library case, so a dependent that
  copied it and built `-Druntime=true` linked `libgmp` into a graph whose calls
  go through the dispatch `load` is meant to fill — the link
  `consumer/build.zig:135-137` and `build.zig:360-365` both refuse, for the
  reason each states beside it.
* `consumer/build.zig` forwards `b.args` to the run step. Its program documents
  `--provider <path>` as a command-line input (`consumer/src/main.zig:7-8`);
  without the forwarding, `cd consumer && zig build run -Druntime=true --
  --provider <path>` dropped the flag, fell through to `GMP_TEST_PROVIDER` and
  reported that it had been told nothing.
* `runtime/library.zig` states both arms of the limb typedef. It claimed
  `mp_limb_t` is `unsigned long` on every target including LLP64 and called a
  `_LONG_LONG_LIMB` provider not interchangeable; this build sets that macro on
  LLP64 (`gmp-h.in:137-145`, `zig/config_gen.zig:224-230`), so the file denied
  the typedef its own `x86_64-windows-gnu` configuration uses and contradicted
  entry 2, `README.md` and `README.zig.md`.
* Every prefix in `.github/workflows/ci.yml` is now under `$RUNNER_TEMP`,
  outside `$GITHUB_WORKSPACE`: `$RUNNER_TEMP/gmp-install` on the three
  installing steps — `verify`'s build, `shared`'s shared install and `runtime`'s
  `-Druntime=true` install — and `$RUNNER_TEMP/gmp-provider` for the provider
  build and the `GMP_TEST_PROVIDER` path read back from it. Zig's default prefix
  is `<package root>/zig-out`, and the `$PWD/zig-out-provider` this file already
  used sat inside the checkout exactly as the default did. Steps that install
  nothing — `test`, `smoke`, `check`, `cross` — are unchanged, as is the
  consumer package's own artifact, and no step was added, removed or reordered.

**What did not change.** The library, the three installed headers,
`lib/pkgconfig/gmp.pc`, `gmp-example` and the eight licence and provenance
records install exactly as before, from the same owner and the same
expressions; `tools/provenance_gate.sh` and its eight-record check are
untouched. `-Dlinkage` keeps static as its default, `-fsys=gmp` still
compiles and installs no artifact, and no public declaration, signature or
error name changes. GMP's own guards were already ordinary panics
(`runtime/loader.zig:272-276`, `runtime/generate.zig:979-983`), and this fork
uses no `std.debug.assert` and no `unreachable` in `root.zig`, `zig/` or
`runtime/`, so nothing there was waiting on a decision.

**Status.** `SOURCE-CONFIRMED` from the files as written: which condition each
published statement now states, which steps forward their arguments, which
prefixes each workflow step names. **No gate was run and none is claimed.** The
edited workflow has never executed — this repository is local and unpublished —
so it is `PENDING-VERIFICATION` for the next acceptance gate.

## 27. The public `mpn_*` spellings did not resolve to the symbols GMP exports — 2026-10-05

**Scope.** This entry and `FORK-NOTES.md` note 44, plus one sentence of note
40. The repair itself is `include/gmp_all.h`, owned by the runtime/translation
change and recorded here rather than authored here. No upstream file, no
native byte, no generated `gmp.h`, `config.h` or table, no `config_gen.zig`
line, no ABI typedef, no linkage default and no test expectation changed.

**Condition.** The low-level layer is the one part of `gmp.h` whose public
spelling is a macro. `gmp-h.in:249-251` defines `__MPN(x)` as `__gmpn_##x`,
and `gmp-h.in:1470-1700` writes every routine in that family as an object-like
`#define mpn_<name> __MPN(<name>)` above its declaration — `mpn_add` at
`:1470`, `mpn_add_1` at `:1475`, `mpn_cmp` at `:1486`, `mpn_sub_1` at `:1615`
among them. So each `mpn_*` name and the `__gmpn_*` symbol it renames are one
function, and the raw route has to offer both spellings of it.

**Observed, by the parent and not by this change.** From `gmp/`,
`zig build test -Dtarget=x86_64-linux -Druntime=false -j8 --summary all`
(with its cache, global-cache and `--prefix` arguments, all recorded in the
receipt) exited 1 after 7.87s with 20 of 23 steps done — receipt
`artifact://19872`, parent background id 1164. The native `libgmp` archive
step and the translate-c step both succeeded, in 2s and 50ms respectively, so
neither the C build nor translation as a step is what failed. The failures were
two regression tests in the translated module: `gmp.c.mpn_add_1` reached an
undefined `add_1` and `gmp.c.mpn_cmp` an undefined `cmp`, the first reported at
`zig/test/known_answers.zig:366`.

**Why that is a contract failure and not a test detail.** The raw surface
publishes itself as complete in `README.zig.md:243-248` and `root.zig:8-10`,
and the example drives `mpn_*` by name. The `__gmpn_*` half of the promise
held; the `mpn_*` half — the spelling GMP's own header gives a C caller — did
not resolve to the exported symbol.

**Repair, as landed in source.** In the private aggregate `include/gmp_all.h`
only: 77 object-like `mpn_*` aliases, each individually guarded and each mapped
straight to its own `__gmpn_*` symbol, so a routine the target's headers do not
declare is not given one. The three function-like macros — `mpn_divexact_by3`,
`mpn_divmod_1` and `mpn_divmod` — are untouched, as are the upstream inputs:
`gmp-h.in`, the C sources of `libgmp` and the generated `gmp.h` are not edited,
so no symbol, signature or ABI moves. Nothing in GMP's raw surface is dropped,
renamed or narrowed. The 77 is confirmed on both sides: `gmp-h.in:1470-1700`
holds 77 object-like `#define mpn_<name> __MPN(<name>)` lines — 76 written with
one space, `mpn_cnd_swap` at `:1668` with two — and `include/gmp_all.h` holds 77
individually guarded `#undef` / `#define mpn_<name> __gmpn_<name>` pairs whose
names track that list in the same order.
The header's own layout is final and recorded here rather than left to drift:
lines 1-64 are the original aggregate ending in `#include <gmp.h>`, 66-73 the
rationale, 74-381 the 77 guarded entries, 383-385 the NetBSD rationale, and
386-388 the `#if defined(__NetBSD__)` / `#undef __ALIGNBYTES` / `#endif` pair.

**Status.** Failure and fix both `OBSERVED` by the parent, on named receipts.
The BEFORE failure is `artifact://19872` (background 1164); the AFTER run of
this SDK's own suite is background 1174 — 23 of 23 steps, 49 of 49 tests, exit 0
in 5.61s. Whether the normalised aliases resolve, and whether both spellings then
reach one symbol, is no longer pending for the linked and loaded static cases:
background 1181 (linked) and background 1182 (loaded, against a real
`GMP_TEST_PROVIDER` and the runtime-generated dispatch) each passed 3 of 3
known-answer checks over 23 of 23 steps. Entry 28 carries that evidence in full
and states what it does not cover.

## 28. The alias repair is observed green across the eight-mode matrix and the 53-cell cross matrix — 2026-10-05

**Scope.** This entry and `FORK-NOTES.md` note 45. It records observed runs and
adds no source change: `include/gmp_all.h`, `build.zig`, `zig/config_gen.zig`,
`gmp-h.in`, the generated headers, every native file and every digest record are
exactly as entry 27 left them.

**Observed by the parent, in this SDK's own graph.**

* Background 1174 — the linked test run on `x86_64-linux`: 23 of 23 steps, 49 of
  49 tests, exit 0, 5.61s.
* Background 1178 — all eight configurations, static and dynamic crossed with
  Debug, ReleaseSafe, ReleaseFast and ReleaseSmall. `test`, `smoke` and
  `install` pass in every one, 49 of 49 each.
* Background 1185 — the 53-cell cross matrix, receipt
  `20261004T224549506489Z-25324/gmp-53-target-8.json`: 8 of 8 jobs completed,
  `source_stamp_before == source_stamp_after` (`8046351d…`), 53 cells. Raw
  `pass=19 fail=1 build_only=27 partial=6`; corrected `pass 19 / build_only 33 /
  build_fail 1`. Nineteen cells ran on a real target and passed 49 of 49 each.
  Thirty-three are build-only where no runtime was available — six of them
  reported `reason: partial_execution`, and a partial run counted as a pass in an
  earlier attempt is what the correction withdraws. The one build failure is
  `hexagon-linux`, which GMP 6.3.0 has no port for and which
  `vendor/gmp/zig/config_gen.zig:169` refuses. Both NetBSD targets compiled;
  **neither was executed** (`aarch64-netbsd` `run=unavailable`,
  `aarch64_be-netbsd` `run=partial`), so neither is a runtime result. No native
  header changed.

**Observed by the parent, through a dependent.** The scratch package
`gmp-alias-proof` is the proof that the raw surface is usable from outside this
tree: it is a dependent with its own `build.zig.zon`, and it reaches GMP only
through what this package publishes. Its first run failed on its own packaging
rather than on GMP — an absolute path in that scratch `build.zig.zon`, which the
parent corrected to a relative path confined to scratch. The corrected runs are
the ones recorded here, and the failure is kept so that neither is read as a
clean first attempt.

* Background 1181 — linked static: 3 of 3 known-answer checks, 23 of 23 steps.
* Background 1182 — loaded static: 3 of 3, against a real `GMP_TEST_PROVIDER`
  naming `gmp-shared/lib/libgmp.so.10.5.0` and the runtime-generated dispatch,
  not a linked one.

**Compiled inputs did not change during verification.** The source digests taken
before and after the eight-mode run are identical at `764eb8e0b9d7b83b` across
all 6070 compiled files, so what the compiler consumed did not move while the
verification ran. It is not a statement about the import baseline: every upstream
byte rests on the protected `UPSTREAM.sha256` record and
`tools/provenance_gate.sh`, which is a source assertion until the full SHA-256
and licence gate runs. Nothing about a consumer's ELF layout or its data ABI is
inferred from it either.

**Receipts.**
`/home/tmp2/gertullj/scratch/foundation-libs/native-final-evidence/gmp-alias-native-final-after-20261004/run.json`,
with `prefix-map.json` beside it.

**What this covers, and what it does not.** The public aliases *are* exercised
across the whole SDK matrix: all four optimize modes crossed with static and
dynamic, 49 of 49 tests in each, over the same private aggregate. What is
narrower is the independent dependent, which ran in Debug, static, on two
routes only — linked and loaded — with three known-answer checks each, the
carry, borrow and compare the alias surface turns on. Dynamic linkage and the
other three optimize modes *for the dependent* were not run for it and are not
claimed. The system-library configuration is observed separately, in this SDK's
own case: background 1239 built against an own installed GMP — GNU, Debug,
dynamic consumer — compiled and executed it with the checkout unchanged, receipt
`nested-delivery-proof/evidence/20261004T235856750722Z-fed3d94ed7d6/index.json`.
That is this package's own installed-GMP case and not an independent external
provider result; the two are never merged into a single claim.

The NetBSD family is not open as a build: both NetBSD targets compile in the
ordinary SDK matrix and in the 53-cell run. Neither has been *executed* in the
53-cell run, and no row in this entry should be read as a NetBSD runtime pass.
The strict preservation check has since run: background 1238 verified both NetBSD
namespaces, 77 of 77 aliases and native functions, and full translated and preprocessed
C payload preservation — receipt `comparison-20261004T235215309787Z-38840`. One
bound travels with it: the data aliases `mp_bits_per_limb` and `gmp_version` fail
container-const initialization before and after on both targets, observed, with
control evidence `20261005T001849274984Z-70688` retaining the before state at four
mixed ALIGN and initializer errors and the after state at four clean initializer
controls. No data-alias usability or isolation PASS is claimed.
