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
