# Fork notes

Issues actually encountered while importing and designing the build of GMP 6.3.0
as a Zig package. Each entry records what the evidence was, what the cause is or
is thought to be, what was done, and what rule is worth reusing. Verification
status says what was **not** run: this fork's gates were never executed while it
was written, so nothing here claims a green build.

---

## 1. The public header does not ship in the release archive

* **Evidence.** `tar -tJf gmp-6.3.0.tar.xz` lists `gmp-h.in` and `config.in`,
  no `gmp.h` and no `config.h`. `gmp-h.in` contains exactly eight `@VAR@`
  placeholders: `GMP_LIMB_BITS`, `GMP_NAIL_BITS`, `DEFN_LONG_LONG_LIMB`,
  `LIBGMP_DLL`, `HAVE_HOST_CPU_FAMILY_power`, `HAVE_HOST_CPU_FAMILY_powerpc`,
  `CC`, `CFLAGS`. `config.in` contains 316 `#undef` entries.
* **Cause.** Not a defect: `configure` generates both, and `configure.ac`
  registers `AC_CONFIG_FILES(gmp.h:gmp-h.in)` and
  `AC_CONFIG_HEADERS(config.h:config.in)`.
* **Fix.** `zig/config_gen.zig` performs the same two derivations from the
  resolved target: autoconf's rule for `config.h` (`#undef X` becomes
  `#define X value` or `/* #undef X */`) and a single pass substitution for
  `gmp-h.in`.
* **Affects.** every target; ABI critical, because `gmp.h` encodes the limb
  type. GMP 6.3.0.
* **Rule.** A release archive of a configure based C library is not the buildable
  subset; the configuration step is part of the product. Reconstruct it from the
  target, never from the build host.
* **Verification.** not run.

---

## 2. Generated headers are included by bare name, so installing them is not enough

* **Evidence.** `gmp-impl.h` includes `config.h`, `gmp.h`, `gmp-mparam.h`,
  `fib_table.h`, `fac_table.h`, `sieve_table.h`, `mp_bases.h`.
  `mpn/generic/jacobi.c` includes `"jacobitab.h"`, `mpn/generic/perfsqr.c`
  includes `"perfsqr.h"`, `mpn/generic/trialdiv.c` includes `"trialdivtab.h"`.
* **Cause.** GMP keeps the generated headers next to the sources that include
  them and relies on the build system's include path, not on a dedicated
  directory.
* **Fix.** All generated files go into **one** directory in the Zig cache; that
  directory is both the include path of the library and the root of the two
  generated translation units (`fib_table.c`, `mp_bases.c`). Separately,
  `installHeader(generated gmp.h, "gmp.h")` puts it in the artifact's include
  tree so dependents get it when they link the artifact.
* **Affects.** every target. GMP 6.3.0.
* **Rule.** If a C library includes its generated headers by bare name, the
  generated directory must be on the compile line. Installing headers is a
  separate concern for dependents, not a substitute.
* **Verification.** not run.

---

## 3. The limb type is an ABI decision, not a detail

* **Evidence.** `gmp-h.in` selects `mp_limb_t` from `_LONG_LONG_LIMB` and
  `__GMP_SHORT_LIMB`; `gmp-impl.h` derives `GMP_LIMB_BITS` from
  `SIZEOF_MP_LIMB_T` and `BITS_PER_ULONG` from `SIZEOF_UNSIGNED_LONG`.
  `mp_bitcnt_t` is `unsigned long` on every platform, including Windows.
* **Cause.** GMP follows the C data model of the target: LP64 gets 64-bit
  `unsigned long` limbs, LLP64 (Windows) gets `unsigned long long` limbs,
  32-bit pointer targets get native 32-bit limbs.
* **Fix.** `unsignedLongBits` in `zig/config_gen.zig` maps the ABI to the width
  of `unsigned long` (32 on msvc and any Windows target, 64 on the x32 ABIs,
  otherwise the pointer width) and derives the limb type and size from it. The
  table generators take the same limb size as arguments, so tables and header
  cannot disagree.
* **Affects.** `x86_64-windows-gnu` (LLP64) and `wasm32-wasi` (32-bit limbs)
  differ from the LP64 targets. GMP 6.3.0.
* **Rule.** Generate the public header per target, or a cross built library will
  disagree with its own header.
* **Verification.** not run.

---

## 4. Only macros that are true may be defined: GMP uses `#ifdef` on some

* **Evidence.** `mpn/generic/sec_powm.c` and `sec_sqr.c` test
  `#ifdef WANT_FAT_BINARY`, and a dozen `toom_*` files test
  `#ifdef HAVE_NATIVE_mpn_rsh1add_n`. `gmp-impl.h` tests
  `defined(HAVE_HOST_CPU_FAMILY_x86_64)`.
* **Cause.** Autoconf emits `/* #undef X */` for absent macros, and GMP's C code
  relies on that distinction in places.
* **Fix.** The macro table defines only macros that are true for the target;
  everything else is emitted as `/* #undef NAME */`. `WANT_TMP_*` are
  deliberately left undefined because `gmp-impl.h` tests them with
  `defined(...)`.
* **Affects.** every target. GMP 6.3.0.
* **Rule.** When reconstructing a `config.h`, define only what is true. Defining
  a false macro to 0 is only safe for `#if` tests, and upstream mixes both.
* **Verification.** not run.

---

## 5. clang predefines `__amd64__`, which re-enables inline assembly

* **Evidence.** `mpn/generic/div_qr_1n_pi2.c`, `div_qr_1u_pi2.c`, `mod_1_1.c`,
  `div_qr_2.c` and `redc_2.c` contain `#if defined (__GNUC__) && ! defined
  (NO_ASM)` blocks whose inner conditions match `__amd64__` and
  `HAVE_HOST_CPU_FAMILY_x86_64`. `longlong.h` has the same structure. clang
  defines `__amd64__` on x86-64 and does not support GNU style inline assembly
  at all on `wasm32`.
* **Cause.** Those blocks exist to use inline assembly when no tuned assembly is
  configured. Defining `HAVE_HOST_CPU_*` to 0 is not enough, because the compiler
  predefines are not under GMP's control.
* **Fix.** Define `NO_ASM 1`, which is exactly what upstream's
  `--disable-assembly` sets, on every target. The backend is then genuinely
  assembly free and identical everywhere.
* **Affects.** every target; performance, not correctness, on x86-64. GMP 6.3.0.
* **Rule.** For a portable C backend, set the switch upstream uses for it rather
  than relying on configuration macros that the compiler predefines.
* **Verification.** not run.

---

## 6. GMP 6.3's public API differs from older references

* **Evidence.** Grepping `gmp-h.in`: `mpf_set_str (mpf_ptr, const char *, int)`
  has three parameters, not four. There is no `mpf_const_pi` and no
  `mpf_set_inf` anywhere in the file. There is no `mpf_sgn`. The random
  interface is `gmp_urandomb_ui` and `gmp_urandomm_ui`; there is no
  `gmp_rand_ui32`. `mpf_get_prec` returns `mp_bitcnt_t` and `mpf_set_prec` takes
  one.
* **Cause.** API drift across GMP releases, plus documentation that outlives the
  header.
* **Fix.** Every facade signature was written against the shipped `gmp-h.in`,
  not against memory of the manual. The float facade has no pi constant and
  takes the sign from the documented `_mp_size` field. `Rand` exposes
  `nextBits` and `nextBelow`, which are GMP's own `gmp_urandomb_ui` and
  `gmp_urandomm_ui`: no second algorithm is layered on top of them. See
  notes 22 and 23.
* **Affects.** `Float` and `Rand` on every target. GMP 6.3.0.
* **Rule.** Check the shipped header, not the manual and not recollection, before
  writing a binding.
* **Verification.** not run; source-confirmed.

---

## 7. `mpz_sizeinbase` is not an exact digit count

* **Evidence.** The GMP manual states the result is exact only when the base is a
  power of two and may otherwise be one too large.
* **Cause.** It estimates by dividing the bit length.
* **Fix.** `writeTo` is used whenever an exact decimal length matters, and the
  digit count tests measure the rendered string. `sizeinbase` is documented as
  an estimate and is only asserted for base 16, where it is exact. It also
  validates its base now and returns `error.InvalidBase` for 0, 1 and anything
  above 62, which GMP's own `MPN_SIZEINBASE` asserts; see note 13.
* **Affects.** tests and any user code counting digits. GMP 6.3.0.
* **Rule.** Never assert an exact digit count with `sizeinbase` on a base that
  is not a power of two, and never call it with a base it does not document.
* **Verification.** not run.

---

## 8. GMP's allocator hooks are per process and the realloc signature is unusual

* **Evidence.** `mp_set_fns.c`: `realloc_func` is
  `void *(*)(void *, size_t, size_t)`, it receives the **old** size, and passing
  null for any of the three functions restores GMP's default. The manual adds
  that `free_function` is called with a pointer that "is always a previously
  allocated block of SIZE bytes", and `gmp-impl.h:717` defines
  `__GMP_FREE_FUNC_TYPE` as `(*__gmp_free_func) (p, (n) * sizeof (type))`.
* **Cause.** GMP allows an application to supply memory functions, so the facade
  must not assume `free`. The default functions ignore the size, so a wrong one
  is invisible until somebody installs a real allocator.
* **Fix.** The library and the facade never call `mp_set_memory_functions`. Text
  GMP allocated is released through `mp_get_memory_functions`, obtained at the
  point of release, and with the size of the block rather than a placeholder;
  see note 18. The test only probe (`zig/test/alloc_probe.c`) installs
  counting functions for the duration of one test and restores the defaults on
  the way out, with thread local counters so a parallel test cannot be confused.
* **Affects.** every target. GMP 6.3.0.
* **Rule.** Free upstream allocated memory with upstream's free function, and
  pass it the size upstream allocated. Do not install allocator hooks to make
  an upstream allocator look like yours.
* **Verification.** not run.

---

## 9. The `mpn` source set is neither the assembly list nor the directory

* **Evidence.** `configure:25281` selects each mpn function by taking
  `mpn/<dir>/<fn>.c` if it exists, else `mpn/<dir>/<mulfunc>.c`, from
  `$gmp_mpn_functions` plus the optional list (`configure.ac:3047`) and the
  `GMP_MULFUNC_CHOICES` table (`configure.ac:3106-3278`). That walk selects 180
  of the 188 files in `mpn/generic`: five are multi-function templates compiled
  once per operation, and three are never selected.
* **Cause.** `define_mpn` in `asm-defs.m4` lists functions an assembly backend
  may provide, so deriving a source list from it loses the C-only helpers that
  `gcdext`, `jacobi` and the Toom routines need. The opposite mistake is to
  compile the directory: templates then fail for want of `OPERATION_<name>`, and
  `udiv_w_sdiv.c` fails for want of an architecture's `sdiv_qrnnd`.
* **Fix.** `zig/sources.zig` holds the 180 files, plus an `operations` table of
  the 16 operations over the 5 templates. `build.zig` writes one wrapper per
  operation into the generated directory, defining `OPERATION_<name>` to 1 and
  including the template, which is what upstream gets from the symlink
  `configure:25553` creates with the `-DOPERATION_<name>` from `mpn/Makefile.am:33`.
  A comptime assert keeps a template out of the plain list.
* **Consequence.** 29 internal functions in `$gmp_mpn_functions` have no generic
  C source and are omitted, exactly as `configure:25581-25588` omits them for a
  generic path: `umul`, `udiv`, `invert_limb`, `mul_2..6`, `addmul_2..8`, the
  `addlsh`/`sublsh`/`rsblsh` families, `rsh1add_n`, `rsh1sub_n`, `sqr_diagonal`,
  `sqr_diag_addlsh1` and `addaddmul_1msb0`. `gmp-impl.h` only references them under
  `HAVE_NATIVE_*`, which stays undefined. No `gmp.h` API is lost: every `mpz`,
  `mpq`, `mpf`, `mpn`, `rand`, `printf` and `scanf` entry point upstream builds
  for a generic path is compiled here.
* **Affects.** build completeness. GMP 6.3.0.
* **Rule.** Replay the build system's own selection loop. Do not derive a source
  list from the assembly metadata, and do not treat a directory of C files as a
  list of translation units.
* **Verification.** observed: `libgmp.a` compiles natively.

---

## 10. Fixture arithmetic is part of the work

* **Evidence.** Two constants written from memory were wrong and were corrected
  by computing them. `2^160 mod 1000000007` is 213932660, not the value first
  written; `2^64 mod 1000000007` is 582344008. The fixture that carried the
  other wrong constant, a nibble swap of `0x0f0f0f0f0f0f0f0f`, was a facade
  method that is no longer part of the package at all: it was not a GMP
  operation, so it and its fixture were deleted rather than corrected (see
  note 20).
* **Cause.** large decimal constants do not survive being recalled.
* **Fix.** Constants that can be computed are computed, in the test or before the
  constant is written. Where an independent reference cannot be written (a
  Fibonacci recurrence over `u64` versus GMP's `mpz_fib_ui`), the test computes
  the reference itself.
* **Affects.** tests and the example. Fork only.
* **Rule.** A "known answer" nobody can re-derive is not a fixture. Derive it a
  second, independent way, in the test.
* **Verification.** not run.

---

## 11. Caller storage formatting must not go through an allocating conversion

* **Evidence.** `gmp-h.in` declares `char *mpz_get_str (char *, int, const
  mpz_t)`, `char *mpq_get_str (char *, int, const mpq_t)` and
  `char *mpf_get_str (char *, mp_exp_t *, int, size_t, const mpf_t)`: a non
  null buffer argument means "format into this buffer". The manual states the
  size such a buffer needs: `mpz_sizeinbase (op, base) + 2` for `mpz_get_str`,
  `mpz_sizeinbase (mpq_numref (op), base) + mpz_sizeinbase (mpq_denref (op),
  base) + 3` for `mpq_get_str`, and `n_digits + 2` for `mpf_get_str`.
* **Cause.** The first version of this facade called the same functions with
  `null`, got a GMP allocated string, and copied it into the caller's buffer.
  That is a transient allocation plus a copy on a path whose whole purpose is
  rendering into caller storage.
* **Fix.** `writeTo` validates the base, then checks exactly the published
  capacity bound, then hands the caller's pointer to GMP and returns
  `std.mem.span(buffer.ptr)`. A buffer that is too small is not written to.
  `toOwnedString` remains as the explicit allocating API.
* **Correction, wave 1.** The published bounds had drifted to
  `mpz_sizeinbase + 3` and `2 * mpq_sizeinbase + 8`, and the note claimed they
  "never reject text that fits". That claim is false. `mpz_sizeinbase` may
  report one digit too many for a base that is not a power of two, so the
  bound is an upper bound, and a buffer that exactly holds the text of a
  particular value can be shorter than it. The extra digit and the doubled
  rational term were padding with nothing behind them. The bounds are now the
  manual's, the claim is gone, and a test pins the consequence: a four byte
  buffer that holds `-1/2` and its NUL exactly is still rejected.
* **Affects.** `BigInt.writeTo`, `Rational.writeTo`, `Float.writeTo`. Fork only.
* **Rule.** When a C library offers a caller buffer form, use it, and size it
  with the bound the library documents. An owning result is a separate API, not
  the way to implement a borrow-into-caller-buffer function. Report upstream's
  own internal scratch separately from anything the wrapper allocates.
* **Verification.** not run.

---

## 12. There is no `mpq_sizeinbase`, and `*_get_str` never checks a buffer

* **Evidence.** `gmp-h.in` exports `mpz_sizeinbase`, `mpq_numref`,
  `mpq_denref` and `mpq_get_str`; `mpq_sizeinbase` appears nowhere in the tree.
  `mpq/get_str.c:69` asserts exactly what the manual says:
  `len + 1 <= 3 + mpz_sizeinbase (mpq_numref (q), 10) + mpz_sizeinbase
  (mpq_denref (q), 10)`. All three renderers treat a non null buffer as a
  promise rather than a request: `mpq/get_str.c` computes `str_alloc` only when
  `str == NULL`, `mpz/get_str.c` allocates only for a null buffer, and
  `mpf/get_str.c` writes `n_digits` digits plus a sign and a NUL without ever
  looking at the buffer. Their only null return is a base out of range.
* **Cause.** `Rational.writeTo` called `c.mpq_sizeinbase`, which never existed,
  so the facade could not have compiled. The null return of `mpq_get_str` was
  also read as "the buffer was too small", which is the one thing those
  functions never report.
* **Fix.** The bound is computed from `mpz_sizeinbase` of the two parts, read
  through the documented `_mp_num` and `_mp_den` fields, which is what
  `mpq_numref` and `mpq_denref` expand to (`gmp-h.in:471`). No null return is
  treated as a capacity signal any more: the caller's own bound check is the
  only thing keeping the write in bounds, and it runs before GMP is called.
* **Affects.** `Rational.writeTo`, `BigInt.writeTo`, `Float.writeTo`. Fork only.
* **Rule.** A null return means what the callee's source says it means. Read the
  callee, not the shape of its return type.
* **Verification.** not run; source-confirmed.

---

## 13. Base 0 is a parsing convention, not a rendering one

* **Evidence.** The manual documents `mpz_sizeinbase` for base 2 to 62, and
  `MPN_SIZEINBASE` in `gmp-impl.h:3014` asserts `base >= 2`. With the assertion
  compiled out, base 0 takes the `POW2_P` branch and divides by
  `mp_bases[0].big_base`, which `gen-bases.c:185` emits as 0. The parsing side is
  the opposite: base 0 is prefix detection for `mpz_set_str` and `mpq_set_str`,
  and `mpf/set_str.c:154` turns it into base 10 explicitly.
* **Cause.** A single `validBase` helper, accepting 0 or 2..62, served both
  directions, and `BigInt.sizeinbase` checked nothing at all. A caller passing 0
  to `sizeinbase` or `writeTo` reached a division by zero in a release build
  and an assertion failure in a debug one, which this fork enables through
  `WANT_ASSERT`.
* **Fix.** `zig/base.zig` holds the two ranges apart. Parsing keeps 0;
  rendering and the digit count take 2..62 and report `error.InvalidBase`.
  `BigInt.sizeinbase` gained the check it never had and now returns
  `FormatError!u64`, with its two callers migrated.
* **Affects.** `BigInt.sizeinbase`, `writeTo` and `toOwnedString` on every
  target. Fork only, GMP 6.3.0 behaviour.
* **Rule.** Do not fold an input convention into an output contract, and do not
  let an unchecked numeric argument reach a C function that asserts on it.
* **Verification.** not run; source-confirmed.

---

## 14. `mpf_get_str` with `n_digits == 0` cannot be given a capacity

* **Evidence.** The manual: "If STR is not NULL, it should point to a block of
  N_DIGITS + 2 bytes... When N_DIGITS is 0 to get all significant digits, an
  application won't be able to know the space required, and STR should be NULL
  in that case." GMP 6.3 exports no `mpf_get_str_prec`; the count comes from
  `MPF_SIGNIFICANT_DIGITS` in `gmp-impl.h:4476`, an internal macro.
* **Cause.** `Float.writeTo` checked `buffer.len >= digits + 3` and passed
  `digits` through unchanged, so `writeTo(buffer, base, 0)` passed a three byte
  check and then let GMP write up to `MPF_SIGNIFICANT_DIGITS` digits into it. The
  same path read a null return from `mpf_get_str` as a short buffer, which that
  function never reports.
* **Fix.** `digits` must be positive and `error.InvalidDigitCount` is returned
  otherwise, the bound is the manual's `digits + 2`, and the null return is no
  longer mapped to `error.BufferTooSmall`.
* **Affects.** `Float.writeTo`. Fork only.
* **Rule.** If a library says the required size is unknowable for one of its
  inputs, refuse that input instead of guessing a bound for it.
* **Verification.** not run; source-confirmed.

---

## 15. `mpf_get_str` returns no radix point and no trailing zeros

* **Evidence.** `mpf/get_str.c:290` strips trailing zeros and line 297 writes
  the digits with no point between them. The manual: "The generated string is a
  fraction, with an implicit radix point immediately to the left of the first
  digit... the number 3.1416 would be returned as string "31416" and exponent
  1."
* **Cause.** Three expectations in the example, the test suite and the facade
  exercise asked for `1.4142135623730950488016887242096980785696718753769` and
  for `0.3000000000`. Neither is something `mpf_get_str` can produce: the first
  has a radix point, the second ends in zeros that are stripped. Nothing had run
  them, because the build never compiled.
* **Fix.** The expectations are the digits GMP returns, with the exponent
  checked next to them: 50 digits of sqrt(2) at exponent 1, and `3` at exponent
  0 for `0.1 + 0.2`, whose first ten significant digits are `3000000000`.
* **Affects.** the example, `zig/test/rational_float_random.zig` and
  `zig/api_exercise.zig`. Fork only.
* **Rule.** A fixture nobody has executed is a claim, not a fact. Derive it from
  the callee's source and state the convention that source implements.
* **Verification.** not run; source-confirmed.

---

## 16. Zig 0.16 build API drift, three call sites

* **Evidence.** `std.Target.Query` has no `arch_os_abi` field, so a triple has
  to be parsed by `std.Build.parseTargetQuery`, which is what
  `standardTargetOptions` itself uses for `-Dtarget` (`std/Build.zig:1500`).
  `Module.CSourceFiles.files` is `[]const []const u8`
  (`std/Build/Module.zig:110`), so a bare array has to be addressed with `&`.
  `++` concatenates comptime known operands only, which rules out
  `rendered ++ prologue` when both sides are runtime slices.
* **Cause.** The build script was written against an earlier Zig, so `zig build`
  failed before any C was compiled. `generate` also took a `target` it never
  read, because `Params` already carries every derived value.
* **Fix.** `check` parses each checked triple with `parseTargetQuery`, the
  generated translation units are passed as `&sources.generated`, and each
  generated header is produced in a single buffer: `renderGmpH` and
  `renderConfigH` now write their own prologue, so no runtime `++` remains.
  `generate` lost its unused `target` parameter. `readPackageFile` reads through
  `b.build_root.handle` instead of the deprecated `LazyPath.getPath2`, and the
  provenance step passes its two paths with `Run.addFileArg`.
* **Affects.** every target. Zig 0.16.
* **Rule.** A build script that has never run has never checked its API
  surface. Read the pinned compiler's std sources instead of recalling them.
* **Verification.** not run.

---

## 17. `std.Target.Cpu.Arch` has no `sparcel`, and ARC is 32-bit

* **Evidence.** `std/Target.zig:1326` lists the current enum. It has no
  `sparcel`, which LLVM dropped, and it gives `arceb`, `riscv32be`, `riscv64be`
  and `xtensaeb` members of their own.
* **Cause.** `pointerBits` was written against an older enum, which is a hard
  compile error for `sparcel`, and it also listed `arc` among the 64-bit
  architectures although ARC is a 32-bit family.
* **Fix.** `pointerBits` lists the architectures whose pointer width is known,
  with each big endian variant next to its little endian sibling, and `arc` and
  `arceb` in the 32-bit group. An architecture that is not listed still panics
  rather than being guessed at.
* **Affects.** any target outside the six checked ones. Zig 0.16.
* **Rule.** A table of architecture facts is a maintained table, not a one time
  transcription.
* **Verification.** not run.

---

## 18. GMP's free function is told the size of the block, and 0 is not it

* **Evidence.** The manual, on `free_function`: "PTR is never NULL, it's always
  a previously allocated block of SIZE bytes." GMP honours that itself:
  `gmp-impl.h:717` is `__GMP_FREE_FUNC_TYPE(p,n,type)` = `(*__gmp_free_func)
  (p, (n) * sizeof (type))`, and the helper it keeps for exactly this purpose,
  `gmp_allocated_string` at `gmp-impl.h:5322`, stores the `strlen` of the string
  it was handed and releases it as `(*__gmp_free_func) (str, len+1)`.
  `mpz_get_str` and `mpq_get_str` both realloc their block down to the exact
  text length plus the NUL before returning it, so `len + 1` is the size of the
  block a caller receives.
* **Cause.** `freeGmpMemory` called the free callback as `free_it(ptr, 0)`. The
  default `free` ignores its second argument, so nothing failed; an
  application that installs a real allocator, which the hook exists for, would
  have been told the block is empty.
* **Fix.** `freeGmpMemory` takes the size and passes it through. `OwnedString`
  records the text length when it is created, and `deinit` reports `len + 1`,
  which is what GMP's own destructor reports. `zig/test/alloc_probe.c` now
  remembers the size every live block was allocated with and counts releases
  that disagree, so the contract is tested rather than assumed.
* **Affects.** `BigInt.OwnedString`, `Rational.OwnedString`. Fork only.
* **Rule.** When a callee documents a parameter it may ignore, pass the real
  value anyway; the default implementation ignoring it is not evidence that the
  value does not matter. See note 8.
* **Verification.** not run; source-confirmed.

---

## 19. A binding should not copy a C string to make one

* **Evidence.** `mpz_set_str`, `mpq_set_str` and `mpf_set_str` all take a
  `const char *` and read it as a C string. Zig's own type for a string that is
  already NUL terminated is `[:0]const u8`, and a string literal has that type,
  so the pointer can be forwarded as it is.
* **Cause.** `memory.cString` took a `[]const u8`, copied it into a 128 byte
  stack scratch buffer, and fell back to a `c_allocator` allocation for longer
  text. On the stack path it returned `scratch[0 .. text.len + 1 :0]`, which
  counted the written NUL as a data byte and pointed the sentinel one byte
  further, at an uninitialised byte; the heap path formatted `"{s}\x00"`, which
  gave `allocPrintSentinel` two terminators and the same extra byte. Both were
  wrong, and both existed only to re-create something the caller already had.
* **Fix.** `parse` and `setStr` take `[:0]const u8` and pass `text.ptr`
  straight to GMP. The scratch buffer, the fallback allocation and the
  `CString` type are gone, not kept as a convenience, and `error.OutOfMemory`
  left `ParseError` with them because parsing can no longer fail that way.
  Rendering returns `[:0]const u8` too, so rendered text can be parsed again
  with no copy in between. GMP's parsing semantics are untouched; the caller
  supplies the termination GMP needs.
* **Affects.** `BigInt`, `Rational` and `Float` parsing and rendering on every
  target. Fork only.
* **Rule.** When a C API takes a NUL terminated string, the binding takes a
  sentinel typed slice and forwards the pointer. Copying a string into a scratch
  buffer to hand back the caller's own bytes is a bug waiting to happen, and the
  type system already prevents it if the signature says what it means.
* **Verification.** not run; source-confirmed.

---

## 20. Facade review: bindings that named functions GMP does not have

* **Evidence.** `mpz_compl` appears nowhere in GMP 6.3.0: `gmp-h.in` declares
  only `mpz_com` (line 714), `mpz/` has only `com.c` and `combit.c`, and
  `doc/gmp.texi` has no hit. `mpz_probab_prime_p` takes a C `int` (line 993).
  `mpz_t`, `mpq_t` and `mpf_t` are `typedef ... [1]` (lines 165, 187, 203), so
  `translate-c` types them as one element arrays. `mpq_set_str` calls
  `mpz_set_str` once per part and never canonicalises.
* **Cause.** Several facade signatures and fixtures were written from memory of
  the API rather than from the shipped header, and nothing had compiled.
* **Fix.** One operation gets one name. The complement is `mpz_com` through
  `comAssign`, and the second spelling of it is deleted rather than kept as an
  alias, because GMP 6.3.0 has no `mpz_compl` and a name that suggests one
  describes a function that does not exist. `probabPrime` passes the round
  count as the C `int` GMP declares. The `_mp_size`, `_mp_num` and `_mp_den`
  reads index the one element array. `Rational.parse` documents that GMP does
  not canonicalise and the test proves it, canonicalising explicitly.
  `bitLength` returns `usize` rather than truncating GMP's `size_t`. The
  nibble-swap method, which was not a GMP operation at all, is deleted with its
  fixture; `gmp.c` is the escape hatch for anything the facade does not cover.
* **Affects.** `BigInt`, `Rational`, `Float`. Fork only.
* **Rule.** Every binding signature is checked against the shipped header, and
  every fixture against the callee's source. An alias that only respells the
  same operation is a second place to be wrong; delete it. See notes 6, 15, 19
  and 22.
* **Verification.** not run; source-confirmed.

---

## 21. `unsigned long` is 32 bits on two of the six checked targets

* **Evidence.** `zig/config_gen.zig` derives `unsigned long` as 32 bits for
  every Windows target and for 32-bit pointer targets, and the checked list
  includes `x86_64-windows-gnu` and `wasm32-wasi`. `mpz_set_ui`,
  `mpz_add_ui`, `mpz_bin_uiui`, `mpz_fac_ui`, `mpz_setbit`, `gmp_randseed_ui`
  and `mpf_set_ui` all take an `unsigned long`, which `translate-c` renders as
  `c_ulong`.
* **Cause.** The facade passed fixed width `u64`/`i64` values into those
  parameters, which is an implicit narrowing on a 32-bit `c_ulong`, so the value
  was silently truncated on LLP64 and on any 32-bit `unsigned long`.
* **Status.** CLOSED by the native-word cutover (see `CHANGELOG.md` entry 14).
  The facade now speaks the target's C words throughout: `c_ulong` for every
  `unsigned long` parameter, `c_long` for `signed long`, `c.mp_bitcnt_t` for
  GMP's bit-count type, `c_int` for the primality round count and `usize` for
  bit lengths. A value wider than one word is parsed or assembled through GMP's
  own entry points, never truncated into a word.
* **Affects.** `BigInt`, `Rational`, `Float` and `Rand` on every target, most
  visibly on `x86_64-windows-gnu` and `wasm32-wasi`.
* **Rule.** A binding for a C library with a machine-word parameter must be
  written against the narrowest `unsigned long` it will meet, or the library's
  own word-splitting entry points. The limb width is handled this way in
  `config_gen.zig`; the facade parameters are handled the same way now.
* **Verification.** not run; source-confirmed.

---

## 22. The public header is const correct, and its own pointer typedefs are the contract

* **Evidence.** `gmp-h.in:225-232` declares
  `typedef const __mpz_struct *mpz_srcptr;` and the same source-pointer form
  for `mpf`, `mpq` and `gmp_randstate`, next to the mutable `mpz_ptr` and
  friends, and its prototypes use them: `gmp-h.in:633` is
  `__GMP_DECLSPEC void mpz_add (mpz_ptr, mpz_srcptr, mpz_srcptr);`. GMP 6.3.0
  also has no occurrence of `__gmp_const` anywhere in the public header.
* **Cause.** An earlier draft of this fork's documentation and comments held
  that GMP's prototypes were not const correct, so the facade needed casts to
  reach the raw API. The claim was never checked against the header.
* **Fix.** The claim is refuted and WITHDRAWN: a `*const` receiver yields GMP's
  own const operand typedef directly, with no cast. Every facade type publishes
  the two types GMP declares for it (`rawPtr`/`rawSrcPtr`), formed as `&raw[0]`
  because `mpz_t`, `mpq_t`, `mpf_t` and `gmp_randstate_t` are one element
  arrays, and no call site writes `&self.raw` any more. A reviewer claim that
  every translated pointer needs an optional-pointer coercion is unproven:
  `translate-c` renders a complete-record pointer as `[*c]`, which is what
  these accessors return.
* **Affects.** `BigInt`, `Rational`, `Float`, `Rand` on every target.
* **Rule.** Read the shipped header before writing a cast, and never describe a
  C library's constness from memory. A `const` claim is a claim about
  declarations, and declarations are evidence.
* **Verification.** not run; source-confirmed.

---

## 23. A header that gates declarations on other headers loses them silently

* **Evidence.** `gmp.h` includes only `<stddef.h>` and `<limits.h>`
  (`gmp-h.in:56-57`). It gates the stdio functions on `FILE` or a platform
  stdio guard (`gmp-h.in:255-272`, `_GMP_H_HAVE_FILE`) and the varargs family
  on `va_start` being a macro (`gmp-h.in:292-294`, `_GMP_H_HAVE_VA_LIST`).
  Under those gates sit `gmp_fprintf`/`gmp_vfprintf`
  (`gmp-h.in:543-545,572-574`), `gmp_fscanf`/`gmp_vfscanf`
  (`gmp-h.in:595-597,606-608`), `mpz_inp_raw`, `mpz_inp_str`, `mpz_out_raw`,
  `mpz_out_str` (`gmp-h.in:881,886,959,964`), `mpq_inp_str`, `mpq_out_str`
  (`gmp-h.in:1200,1219`), `mpf_inp_str`, `mpf_out_str`
  (`gmp-h.in:1373,1393`) and the `v`-suffixed string/in-memory family
  (`gmp-h.in:567-569,577-579,582-584,587-589,611-613,616-618`).
* **Cause.** Translating `gmp.h` on its own therefore drops every one of those
  declarations without a diagnostic: no error, just a short translated module.
* **Fix.** `include/gmp_all.h` includes `<stdarg.h>` and `<stdio.h>` before
  `<gmp.h>`, in both bundled and system modes, so the translated `c` module
  carries the complete public surface, stdio and `va_list` functions included.
  The consumer proves it by calling `gmp.c.mpz_out_str` on a `FILE *` from
  `gmp.c.tmpfile`, which only compiles if those declarations survived.
* **Affects.** every target and both modes. GMP 6.3.0.
* **Rule.** For a C library whose header gates declarations on types from other
  headers, the aggregate translation unit must include those headers first;
  otherwise the gap is silent and only shows up as a missing symbol at the
  call site.
* **Verification.** not run; source-confirmed.

---

## 24. Rational assignment does not canonicalise, and the capacity bound comes from the parts

* **Evidence.** `mpq_set_str` parses each part with `mpz_set_str`
  (`mpq/set_str.c`) and never reduces; GMP's rational arithmetic functions
  document and implement the canonicality they require
  (`doc/gmp.texi`). `gmp.h` exports `mpz_sizeinbase`, `mpq_numref` and
  `mpq_denref` but no `mpq_sizeinbase`; `mpq/get_str.c` asserts the caller's
  buffer against
  `len + 1 <= 3 + mpz_sizeinbase(mpq_numref(q), 10) + mpz_sizeinbase(mpq_denref(q), 10)`.
* **Cause.** A facade that canonicalised on parse would disagree with the
  library it wraps, and one that sized buffers from a single digit count would
  size them from a function GMP does not have.
* **Fix.** `Rational.parse` and `setStr` do not canonicalise, and
  `canonicalize` is the explicit call for a value that was assigned. The
  capacity check in `Rational.writeTo` sums `mpz_sizeinbase` of the two fields
  the `mpq_numref`/`mpq_denref` macros expand to, so it is the same inequality
  as the C code's own assertion, computed before GMP is called.
* **Affects.** `Rational` on every target. Fork only.
* **Rule.** Match the assignment/arithmetic canonicality split of the wrapped
  library instead of imposing one, and read a capacity bound out of the
  printing function's own source. See notes 11 and 12.
* **Verification.** not run; source-confirmed.

---

## 25. The random range mapping is GMP's, and the bit count has a bound

* **Evidence.** `rand/randmui.c:66-84` is the rejection loop for
  `gmp_urandomm_ui`: it draws the bits that reach `n`, retries while
  `ret >= n` (at most 80 times), and returns 0 when `n == 1` because `bits`
  is 0. `n == 0` divides by zero by design (`rand/randmui.c:52-53`).
  `rand/randbui.c:34,49` states that `bits >= BITS_PER_ULONG` is quietly
  truncated through `MIN (bits, BITS_PER_ULONG)`.
* **Cause.** A facade that implemented its own rejection mapping for a
  non-power-of-two bound would be a second algorithm over the same state, and
  one that passed an oversized bit count through would silently return fewer
  bits than asked for, because GMP truncates rather than reporting.
* **Fix.** `Rand.nextBits` calls `gmp_urandomb_ui` directly and states and
  checks the manual's condition, `nbits <= @bitSizeOf(c_ulong)`; it is the
  caller's bit count, not a wrapped algorithm. `Rand.nextBelow` calls
  `gmp_urandomm_ui` directly, so any positive `n` — power of two or not — goes
  through GMP's own uniform mapping; `n == 1` returns 0 and `n == 0` is not a
  valid argument. Nothing in the facade re-rolls or rescales.
* **Affects.** `Rand` on every target. Fork only.
* **Rule.** Prefer the wrapped library's own uniform mapping to a local
  reimplementation, and state and check a documented precondition the library
  enforces by silent truncation. See note 6.
* **Verification.** not run; source-confirmed.

---

## 26. `b.systemIntegrationOption` is spelled `-fsys=<name>` on the command line

* **Evidence.** The build runner parses `-fsys=<name>` and `-fno-sys=<name>`
  into the system library table (`lib/compiler/build_runner.zig:169-174` of the
  pinned compiler) and `--system` into package-wide system mode
  (lines 318-322); `-Dsystem=gmp` is not an option of the build runner at all,
  so it would be diagnosed as an unknown user option.
* **Cause.** Documentation and the aggregate header comment both showed
  `zig build -Dsystem=gmp`, a guessed spelling. The build script itself called
  `b.systemIntegrationOption("gmp", .{})`, which is correct; only the way the
  user is told to enable it was wrong.
* **Fix.** The documented command is `zig build -fsys=gmp`; `-fno-sys=gmp`
  forces the bundled build, and `--system` lets the package default to system
  libraries. The README, the CI notes and note 3's contract now use that
  spelling.
* **Affects.** every target; only the system library mode.
* **Rule.** Read the build runner's own argument parser for a build option's
  spelling; do not generalise from `-D` user options.
* **Verification.** not run; source-confirmed.

---

## 27. GMP renames the memory function hook, and the object file has only the new name

* **Condition.** A binding declares `mp_get_memory_functions` itself instead of
  taking it from the translated header.
* **Symptom.** Undefined symbol at link time, not a compile error, so the whole
  facade fails at the last step and every symbol in it looks innocent.
* **Evidence.** `gmp-h.in:480,485` rename both hooks with
  `#define mp_set_memory_functions __gmp_set_memory_functions` and
  `#define mp_get_memory_functions __gmp_get_memory_functions`; the macro is
  expanded before the C is parsed, so the definition in `memory.c` lands in the
  object file as `__gmp_get_memory_functions`. `translate-c` emits that function
  under the expanded name (`Translator.zig:760`, `transFnDecl`, which adds the
  top level declaration under `fn_name` alone) and separately emits
  `pub const mp_get_memory_functions = __gmp_get_memory_functions;` for the
  macro (`MacroTranslator.zig:131`, `transMacro`).
* **Fix.** `zig/memory.zig` declares `__gmp_get_memory_functions`, the name the
  library exports, and says why in its own doc comment.
* **Affects.** every target, every link that releases a GMP allocated string.
* **Rule.** When a header renames a symbol with `#define`, a hand written
  binding must declare the expanded name. Bound: the per function `__gmp*`
  renames in `gmp-h.in`.
* **Verification.** not run; source-confirmed.

---

## 28. The temporary memory mode is a required macro, not an optional one

* **Condition.** A hand derived `config.h` defines the macros it recognises and
  leaves the rest undefined, on the reasoning that an undefined optional
  feature macro is harmless.
* **Symptom.** 124 of the compiled sources fail on `TMP_DECL`, `TMP_MARK`,
  `TMP_ALLOC` and `TMP_FREE` being undeclared, and the link would fail even if
  they compiled, because the target abstraction layer object was missing.
* **Evidence.** Those four macros are defined only inside the four `WANT_TMP_*`
  blocks (`gmp-impl.h:373-422`). `configure.ac:114` defaults `--enable-alloca`
  to `reentrant`, `configure:24083-24087` maps that to `WANT_TMP_ALLOCA`
  whenever `alloca` works, and `configure:24107` pairs it with
  `TAL_OBJECT=tal-reent.lo`; `gmp-impl.h:196-198` makes `alloca` the clang
  builtin, so it works on every target here. `tal-reent.c:54,71` define
  `__gmp_tmp_reentrant_alloc` and `__gmp_tmp_reentrant_free`, which both the
  `alloca` and the `reentrant` branches need. Separately `configure:3619` writes
  `VERSION` from `AC_INIT` and `version.c:33` is
  `const char * const gmp_version = VERSION;`.
* **Fix.** `zig/config_gen.zig` defines `WANT_TMP_ALLOCA 1` and
  `VERSION "6.3.0"`; `zig/sources.zig` adds `tal-reent.c` to the library.
* **Affects.** every target.
* **Rule.** In a configure based C library, the macros that select an
  implementation are as required as the size macros. Bound: GMP 6.3.0.
* **Verification.** not run; source-confirmed.

---

## 29. A name the header only defines as a macro is not in the translation

* **Condition.** A binding calls `c.name` because the header and every C example
  spell it that way.
* **Symptom.** `no member named 'name' in container '@import("c")'` at the first
  use, with every other symbol in the file fine.
* **Evidence.** `gmp-h.in:2252` defines `mpz_sgn` only as the macro
  `((Z)->_mp_size < 0 ? -1 : (Z)->_mp_size > 0)`, and there is no `mpz/sgn.c`;
  `gmp-h.in:2270` and `2278` define `mpq_cmp_si` only as a macro over
  `__builtin_constant_p`, in both the GCC and the non GCC branch. The function
  behind the latter is `_mpq_cmp_si` (`gmp-h.in:1163`). A sweep of every `c.`
  name used in the facade against `gmp-h.in` is what found both; the only other
  hits were typedefs.
* **Fix.** `BigInt.sign` and the three predicates read `_mp_size`, which is what
  the macro reads, the way `Float.sign` already did; `Rational.cmpZero` calls
  `_mpq_cmp_si`.
* **Affects.** every target.
* **Rule.** Before binding a name, confirm `gmp-h.in` declares it as a function;
  GMP hides several behind `__builtin_constant_p` for exactly the functions a
  binding wants. Bound: GMP 6.3.0.
* **Verification.** not run; source-confirmed.

---

## 30. An independent oracle has to be computed, not reasoned about

* **Condition.** A fixture states a digit string for a value too wide for a
  machine word.
* **Symptom.** The test fails with no compiler output pointing at the fixture,
  or passes for the wrong reason.
* **Evidence.** Three were wrong. `mpf_get_str` returns significant digits with
  the radix point implicit, rounds half up at the last requested digit
  (`mpf/get_str.c:254-285`) and then strips trailing zeros (lines 290-293), so
  21 digits of sqrt(2) are `414213562373095048802` and 50 digits are
  `41421356237309504880168872420969807856967187537695`; the strings that were
  written carried the leading `1` of `1.41421...` and were one digit short.
  `bitLength` of `-123456789012345678901234567890` is 97, not 100, because
  `2^96 <= |value| < 2^97`. `mpz_set_str` is declared
  `int mpz_set_str (mpz_ptr, const char *, int)` (`gmp-h.in:1040`), so a call
  written `(dest, base, text)` passes the base where the text belongs.
* **Fix.** All three corrected, each with the GMP behaviour it rests on named
  above it.
* **Affects.** the fixtures and the one call site only.
* **Rule.** Derive an oracle from the specification, check its digit count with
  a separate computation, and never adjust a fixture until it passes.
* **Verification.** not run; source-confirmed.

---

## 31. An owned handle released by both a `defer` and an explicit call

* **Condition.** A value is re-rendered after being changed, and the first owned
  string is released before the second is created.
* **Symptom.** A double free through GMP's own allocator, or a silent leak under
  the default `free`.
* **Evidence.** `zig/test/rational_float_random.zig` held
  `defer half_text.deinit()` on a binding it also called `deinit` on explicitly
  before reassigning it.
* **Fix.** Release the first binding explicitly, then create the second and defer
  that one, so the `defer` covers every value the binding ever held.
* **Affects.** the ownership tests.
* **Rule.** `defer x.deinit()` owns every value `x` ever held; to release one
  early, move the `defer` to after the last reassignment. Bound: any owned handle
  that is reassigned.
* **Verification.** not run; source-confirmed.

## 29. `invalid.c` and a libc without signals

**Evidence.** `__gmp_invalid_operation` is `raise (SIGFPE); abort ()`
(`invalid.c:79-82`), `Makefile.am:285` lists `invalid.c` among the library
sources, and the toolchain's `wasm-wasi-musl/signal.h:2` is a bare `#error`
unless `_WASI_EMULATED_SIGNAL` is defined. Observed with Zig 0.16.0:
`zig build check` fails on `wasm32-wasi` with four diagnostics, two of which
name `invalid.c:80`, and succeeds on the other five targets.

**Cause.** A property of the vendored source meeting a libc that has no
signals. `configure.ac` has no wasm branch either, so upstream does not claim
the target either.

**Decision.** Keep `wasm32-wasi` in the matrix and keep the failed attempt
visible. `zig build check -Dtarget=` now checks a single target so CI can mark
exactly that one `continue-on-error`. No `-D` was invented to make
`_WASI_EMULATED_SIGNAL` appear, no `invalid.c` was patched, and no substitute
for `raise` was written.

**Rule.** A target that cannot compile is a documented boundary, not a
reason to fake the missing facility. The proof is the failing compile and the
two source lines, and both are recorded here.

**Verification.** observed: 5 of 6 targets compile; `wasm32-wasi` fails as
described.
