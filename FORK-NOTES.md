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

## 32. One licence label for an LGPL tree that also contains GPLv3, GFDL, Libtool and an X11 notice

**Evidence.** A sweep of the imported tree for `either version 2 of the License`
matches 1823 files, almost all of which carry the same dual header. The
exceptions are only visible if you look for them:

* `tests/` and `tests/cxx/` say `either version 3 of the License, or (at your
  option) any later version` (228 files; `tests/misc/t-printf.c:8-10`,
  `tests/devel/README:8-10`, `tests/devel/primes.c:8-10`);
* `demos/calc/`, `demos/factorize.c`, `demos/isprime.c` and `demos/primes.c`
  say the same (`demos/calc/calc.y:8-10`, `demos/calc/README:5-8`), while
  `demos/expr/` and `demos/perl/` are dual (`demos/expr/expr.c:7-20`);
* `doc/gmp.texi:13-23` is `GFDL-1.3-or-later` with no Invariant Sections, and
  the prebuilt `doc/gmp.info` shipped in the archive carries the same terms;
* `install-sh:7-25` is the X Consortium permission notice from
  X11R5/X11R6 `install.sh`, and `ltmain.sh:8-26` is GNU Libtool 2.4.6 under
  `GPL-2.0-or-later` with the Libtool linking exception;
* `gmp.pc.in`, `gmpxx.pc.in`, `doc/version.texi`, `doc/stamp-vti` and
  `demos/primes.h` carry no notice at all.

**Cause.** GMP is dual licensed as a library, but the tree is a release
directory, not a library: tests, demos, the manual, autotools output and libtool
each carry their own terms, and some generated files carry three notices at once.

**Decision.** `NOTICE.md` is an inventory with file and line anchors, one row per
term, and it names the one previous statement that was wrong (`tests/` and
`demos/` are `GPL-3.0-or-later`, not GPLv2 or later) rather than editing it
silently. A missing header is recorded as a missing header, with the file that
includes it, because a file without a notice is not thereby free of one.

**Rule.** Do not reduce a release tree to the licence of its most prominent file,
and do not write a per-file term from memory of the project. Read the header of
the file, anchor the claim to it, and keep the automake/libtool scaffolding in
the inventory even though no build in this package compiles it. Bound: any
vendored release directory, which is most of them.

**Verification.** not run; source-confirmed by reading the cited headers.

## 33. The upstream README keeps its upstream name

**Evidence.** The GMP archive ships its README as `README`, a file with no
extension (`tar -tJf gmp-6.3.0.tar.xz`). The fork needed a README of its own, so
the upstream bytes were preserved as `README.upstream.md`; both files have
SHA-256 `5e9f9325fd702bc4bcda27d7a78fea88a2a09fa39b4b15ac7b9b205e0863dc7e`.

**Cause.** The relocation contract for this wave requires a fork README in the
canonical order and a separately preserved upstream README. Renaming `README`
would have destroyed the upstream name in a repository whose whole provenance
claim is that it is an unmodified archive import.

**Decision.** Keep `README` as upstream left it and add `README.upstream.md` as
the byte-identical copy. The gate checks that the two agree and that
`README.md` is neither of them.

**Rule.** When upstream's readme has no extension, do not rename it. Keep the
upstream path as the archive placed it, put the preserved copy at
`<name>.upstream.md`, and make the digests a gate condition rather than a note.
Bound: any archive import whose primary readme is not `README.md`.

**Verification.** not run; digests computed from the two files.

## 34. A derivation that only works from the flake is not a package

**Condition.** A `package.nix` is written for one caller: the flake that sits
next to it, with an input set only that flake provides.

**Fix.** The derivation is one uncurried function taking injected
`{ lib, stdenv, zig, linkage ? "static" }`, imports no sibling directory, names no
account, store path, scratch path or Node path, reads no host state and downloads
nothing at build time. Both entry points call it through
`pkgs.callPackage ./package.nix { zig = pkgs.zig_0_16; ... }`; the variants are
their names, not a second convention in `package.nix`. The devenv shell declares
them as lazy outputs, so entering the shell builds nothing.

**Rule.** A `package.nix` takes its dependencies by injection and returns one
derivation, evaluable with `callPackage` from either entry point and from a
checkout with no flake and no sibling. It refuses a cross build platform instead
of silently building for the wrong target. Host paths and store paths in a
derivation are a portability bug that only shows up on another machine.

**Verification.** not run; no Nix evaluation was performed by this role, so the
derivations are `PENDING-VERIFICATION` until the driver builds them.

## 35. A declared build option can be one the build file never spells out

**Condition.** A packaging question: may `-Dcpu=baseline` be passed? The
evidence used was a search of this repository's `build.zig` for `b.option(`, which
showed three own declarations (`linkage`) plus `b.standardTargetOptions` and
`b.systemIntegrationOption`, and from that the answer "no CPU option exists" was
concluded.

**Evidence.** A peer reading the pinned compiler's own `lib/std`
(`std/Build.zig`): `standardTargetOptions` (`std/Build.zig:1414-1417`) is a thin
wrapper over `standardTargetOptionsQueryOnly`, which declares `target`
(`:1474-1477`), `cpu` (`:1478-1483`), `ofmt` (`:1484-1488`) and `dynamic-linker`
(`:1489-1494`) on the caller's behalf. `b.option` marks an option consumed
(`:1167-1168`) and an unconsumed option fails the build with `invalid option:
-D{s}` (`:1647-1651`). Peer finding, `SOURCE-CONFIRMED`; a gate confirms or
refutes it.

**Cause.** The declared option set is not what a build file spells out. The
declaration spans five lines, so even a search for the literal option name right
after `option(` cannot match it.

**Fix.** `-Dcpu=baseline` is passed, with a comment recording that it constrains
Zig's own codegen and cannot select GMP's mpn path, which is fixed to `generic`
with `NO_ASM` and derived from `target.result` rather than `cpu_features`.

**Rule.** When a question turns on one build option's existence or spelling, read
the pinned `std` range for the standard wrappers the build calls, and enumerate
what they declare. Do not conclude an option does not exist from a search of the
build file. Bound: any Zig build using `standardTargetOptions`,
`standardOptimizeOption`, `systemIntegrationOption` or the other standard
wrappers; the declarations themselves are the pinned 0.16.0 std's.

## 36. A C undefined-behaviour check can be reached by a function table the code never calls by name

**Condition.** GMP's own `printf` dispatch. `gmp-impl.h:4540-4543` declares the
four slots of `struct doprnt_funs_t` as `int (*)(void *, ...)` — a `void *`
first parameter — and each of the five initializers fills a slot by casting a
function whose first parameter is a concrete struct pointer:
`printf/snprntffuns.c:152-158`, `printf/sprintffuns.c:89-94`,
`printf/vasprintf.c:103-108`, `printf/printffuns.c:75-79` (line 76 casts
libc's own `vfprintf`) and `printf/obprntffuns.c:65-69`. Converting between
those function pointer types is undefined behaviour in C, and it is upstream
code this fork carries byte-for-byte.

**Symptom.** Under Zig 0.16 with clang's default C instrumentation, a
`ReleaseSafe`, `ReleaseFast` or `ReleaseSmall` build carries clang's `function`
member of undefined-behaviour detection, which writes an eight-byte
`0xc105cafe` signature plus a hash of the function type in front of every
function entry and verifies it at every indirect call. The first indirect call
through the table — `DOPRNT_FORMAT (last_fmt, last_ap)` at
`printf/doprnt.c:612` — traps with `SIGILL` before a character is formatted. A
`Debug` build writes no such signature and never reaches it, which is why the
failure looks mode-specific rather than caused by the code. Nothing in the C
source points at the fault: the cast is the only thing the check can see, and
the call that trips on it is ordinary upstream formatting.

**Cause.** Not a bug in this fork and not a Zig defect. `Module.sanitize_c` is
null, which emits no `-fsanitize-c` flag
(`std/Build/Module.zig:558-562`), so the compiler's own default stands and
instruments GMP's C. Upstream's function-type pun in the `printf` table cannot
satisfy that instrumentation, and `AGENTS.md` §4 forbids both editing the
upstream source and suppressing a diagnostic other than through an authorised
bounded fix.

**Fix.** The flag and nothing else. `build.zig:635-638` builds
`c_source_flags` with `-fno-sanitize=function` in every mode but `Debug`, and
that one list is passed to all three `addCSourceFiles` calls on
`library.root_module`: `sources.all`, the two generated tables and the
generated `mpn` template wrappers. Every other C check, every Zig safety check
and the optimize mode are untouched.

**Rule.** When a C check fires inside an upstream function-pointer table, scope
the exception to the flag and to the translation units that carry the table,
and enumerate the sites it must not reach. Here that means the host table
generators (`generatorProgram`, `build.zig:935-953`) keep the check: they are
build-time programs for `b.graph.host` that never enter the artifact, none of
the seven converts a function pointer, and neither does the `bootstrap.c` they
include. `runtime/sync.c` (`runtime/graph.zig:371-375`) and
`zig/test/alloc_probe.c` (`addTests`, `build.zig:1034-1055`) are fork-authored
and declare no function pointer either. Giving the flag to those three would be
disabling a check that has nothing to catch, which is the shape this fork's
own rules forbid.

**Targets bound.** Any Zig build of GMP's native C where clang's default C
instrumentation applies, that is every optimize mode but `Debug`, on every
target. The flag is a property of the command line, not of an architecture, so
no cross-target gate changes. Consumers are not affected: the flag touches no
header text, no `gmp.pc` content, no `__GMP_LIBGMP_DLL` value, no exported
symbol and no ABI. What *is* affected is any other graph that compiles the same
GMP `printf` sources without the flag — in this workspace that is
`mpfr/vendor/gmp`, which carries the identical cast sites at the identical line
numbers and compiles them with `flags = &.{"-D__GMP_WITHIN_GMP"}` only
(`mpfr/vendor/gmp/build.zig:305-323`), under an `optimize ? "ReleaseSafe"`
default (`mpfr/package.nix:11`). `SOURCE-CONFIRMED` from those files; not
observed from an MPFR run, and the sibling was not edited here.

## 37. A translation the C compiler also sees can declare names no library exports

**Condition.** The runtime route. `include/gmp_all.h` includes `<stdio.h>` and,
where the target has it, `<obstack.h>` — which pulls `<string.h>` in behind it —
so the same translation that carries GMP's declarations also carries the C
library's. `runtime/generate.zig` sorts every `extern` into routed, optional or
direct, and the only thing that makes a declaration direct is its name being in
`runtime/graph.zig`'s `libc_noise`. A name that is not in that list is assumed
to be GMP's.

**Symptom.** `-Druntime=true -Doptimize=ReleaseSafe` only: `error:
MissingSymbol` from the example, and every test either failing on that error
or panicking with `mpz_init was called before this module was loaded`. Debug,
ReleaseFast, ReleaseSmall and all eight native gates passed with the same
provider.

**Cause.** The pinned translator defines `_FORTIFY_SOURCE` at `-O2`, which is
what `-Doptimize=ReleaseSafe` becomes, and glibc's `<stdio.h>` and `<string.h>`
then declare twenty helpers. Twelve are `libc.so.6` exports. The other eight —
the five `__*_alias` and three `__*_chk_warn` names — are not symbols at all:
glibc declares each through `__REDIRECT`, whose `__asm__` label names the
unfortified function (`bits/stdio2-decl.h:96` gives `__fgets_alias` the label
`fgets`), and the translator keeps the declaration name while dropping the
label.
`dlsym` on the provider's handle searches the provider's dependencies, so
the twelve libc names resolved by accident, through `libc.so.6`; the eight
cannot resolve for any provider, and the first of them in table order is
`__fgets_alias`. Nothing about the provider was wrong and nothing about the
header was wrong: the required table was asking the wrong question.

**Rule.** A C library declaration that reaches a binding's translation is the C
library's, whatever optimization the translator ran at, and it must be direct
in every mode rather than resolved at load time. The evidence for which names
those are is per configuration, not per library: this one appeared only at
`-O2`. So `libc_noise` is re-measured whenever the translation changes, and a
name is added there — never to `provider_optional`, whose absence would stop the
program by name at the call site instead of refusing the provider at load time,
and never to `provider_excluded`, whose absence would be silently accepted.
Making the generator route only names beginning with `__gmp` was rejected: it
would turn a measurable list into a prefix guess and could drop a real GMP
symbol on a target whose header spells one differently.

**Targets bound.** Any glibc target whose translation runs at `-O2`. The
linked configuration is unaffected and always was: it keeps these declarations
direct out of the same translation, which is what makes this a routing defect
and not an ABI one. `SOURCE-CONFIRMED` from the generated dispatches, the
translated sources and the provider's dynamic symbol table; not observed from a
re-run, and none was made.

## 38. A linked configuration owes the facade the loader core, and an unhonourable request is refused

**Condition.** The build graph's own configuration handling. `root.zig` names
the loader core at container scope — `const rt = @import("rt")`, from where a
linked build's `LoadSource` and `LoadError` come — and a container-scope
import is only analyzed when something references it. That hides a missing
module import until a consumer names the type behind it, which is the worst
moment: the mode builds, and the failure lands on a caller that did nothing
wrong.

**Two failures with that shape, both in `-fsys=gmp`.** The mode added `c` and
no `rt`, so it could not answer a consumer naming `gmp.LoadSource` or
`gmp.LoadError`; and it accepted `-Druntime=true`, which `makeLibrary`
forwards only to the bundled branch, dropped it, and exited 0 having linked the
installed library. A green exit from the wrong configuration is worse than a
refusal: it is evidence that cannot be checked later because it looks like
evidence.

**Rule.** Two obligations, both from the same place. A configuration that
links GMP — the bundled one and the system one alike — supplies the loader
core, because the facade's public types come from it in both and there is
exactly one of each in a build. And a request the build cannot honour is
refused at configure time, by name, with both options in the message; it is
never substituted with the nearest configuration that can be built. Refusing
`-fsys=gmp -Druntime=true` is the second rule, not a missing feature: making
system mode a third runtime-loading route would mean generating a dispatch from
the installed header and deciding where that library is loaded from, which is
new behaviour with its own ABI statement and its own gates.

**Targets bound.** Both loaded linkage routes are unaffected:
`-Druntime=true -Dlinkage=static` and `-Druntime=true -Dlinkage=dynamic` still
reach the bundled branch with the option forwarded. No ABI, no exported symbol
and no `gmp.pc` content changes in any configuration.
`SOURCE-CONFIRMED` from `build.zig`, `root.zig` and `runtime/graph.zig` as
written; not observed from a run, and none was made.

## 39. A published surface is per configuration, and a dependent reads the shared answer

**Condition.** The consumer package, which is this tree's own example of a
dependent. It linked `dep.artifact("gmp")` whenever `-Druntime` was not set and
pinned `linkage` to `static` and `runtime` to `false` on the way in. Run as
`cd gmp/consumer && zig build run -fsys=gmp -Dlinkage=dynamic`, it exited 1
with `unable to find artifact 'gmp'`, listing `gmp-example` as the only one
available — which is the signature of the system branch having been taken
correctly and the artifact then being asked for in the one configuration that
does not publish it.

**Three obligations, all about the same seam.** A package publishes what a
configuration produces: system-library mode compiles nothing, so it publishes
the module and no artifact, and a dependent that links the artifact there gets
a panic rather than a link — the honest failure, and one that never was
avoidable by guessing. A dependent reads the configuration rather than
forwarding it, because the toolchain already resolved it once into a build
graph every package in the process shares. And a dependent forwards an option
as it was given or not at all, because a default it invented arrives at the
dependency as a request the user never made, and a wrong one of those is
invisible: `-Dlinkage` means "which installed library to prefer" in system mode,
where the SDK's own default is dynamic, so a pinned `static` turns a normal
host into a link failure that reads as a broken system library.

**Rule.** Never invent a second spelling for a setting the toolchain resolves
(`-Dfsys` would be one, and would be a second thing to disagree about); read
it with the same call the package it names uses. Never forward a default of
your own as though the user had asked for it — leave it null and let the
dependency apply its own. And keep a union's payload and its unreachable arms
honest: `Library` described a `system` link path that no call could reach, and
that dead arm reads as a second mechanism to anyone reasoning about which link
carries the installed library.

**Targets bound.** The bundled configurations are unchanged. `-Dlinkage=static`
and `-Dlinkage=dynamic` still compile the artifact the dependent links, a plain
`zig build run` is still the linked static consumer it was, and
`-Druntime=true` still links no archive. No ABI, exported symbol or `gmp.pc`
content changes in any configuration. `SOURCE-CONFIRMED` from
`consumer/build.zig`, `build.zig` and the toolchain sources named in
`CHANGELOG.md` entry 22, read as written; not observed from a run, and none was
made.

## 40. A translation the preprocessor has to survive is not a header problem

**Condition.** The aggregate translation unit. `include/gmp_all.h` exists so
that translation has one entry point, and the first two includes it makes are
`<stdarg.h>` and `<stdio.h>` — without them `gmp.h` declines to declare the
whole printf and scanf family and the translation silently loses it
(`include/gmp_all.h:18-26`). That is the right trade for a header a C consumer
compiles, where `stdio.h` is already in. It also means the translation can only
ever be as good as the front end's reading of the *target's own* libc.

**Fourteen targets said it was not good enough.** Nine NetBSD targets, three
OpenBSD targets and two OpenBSD mips64 targets failed in `addTranslateC` while
their libgmp compiled, because that compilation is clang's and the translation
is Aro's. Three distinct faces, one cause: Aro is not the target's preprocessor.
NetBSD's `sys/cdefs.h:408-424` makes `__BEGIN_DECLS` a
`_Pragma("GCC visibility push(default)")` and `__END_DECLS` the matching pop,
and Aro's `#pragma GCC` handler knows only `error`, `warning`, `diagnostic` and
`poison`. On 32-bit OpenBSD, Aro's `size` is an `unsigned int` where the
platform's is an `unsigned long`. On OpenBSD mips64, `machine/endian.h`
hard-`#error`s without `__MIPSEL__` or `__MIPSEB__` and Aro's MIPS branch
defines neither. `CHANGELOG.md` entry 23 carries the line references.

**Rule.** When the front end cannot read the target's own headers, the target's
own front end reads them first, and it is the compiler already pinned to the
build — never a second preprocessor, a hand-written substitute or a narrowed
aggregate. The condition is a family (the OS tag), never a list of triples,
because a list stops covering the next architecture silently and the family is
what shares the cause. Everything the front end would have seen is still there:
every `#include` resolved, every conditional settled, every GMP declaration and
macro kept, which is what `-dD` is for on a header that is mostly macros. One
macro is deliberately not kept, and it is named because it is not GMP's:
`__ALIGNBYTES`, a NetBSD-internal macro that arrived with the platform's own
headers and that no GMP source or declaration uses. It is not part of GMP's
surface, and it is removed only after every include has resolved, which is the
point at which it has demonstrably cost nothing. And the step has to know
what it read: a `-I` directory argument contributes one resolved path and a step
dependency and nothing about what is inside the directory, so without the
depfile and the generated header named as a dependency in its own right the run
cache will happily serve a translation that describes a header since changed.

**Not a licence to trim.** Filtering the aggregate to what translates is the
one repair that would have worked everywhere and lost the API with it. The
route is chosen, never the contents.

**Targets bound.** Every other OS family keeps Aro. `-fsys=gmp` still reads the
installed header, both linkage modes and the runtime-loaded dispatch are
untouched, and no ABI, exported symbol or `gmp.pc` content changes in any
configuration. Hexagon still fails where it failed, in `zig/config_gen.zig`'s
pointer-width table and before this step: recorded, not repaired here.
`SOURCE-CONFIRMED` from `build.zig`, the Zig 0.16.0 libc headers and the Aro
sources named in `CHANGELOG.md` entry 23, read as written; not observed from a
run, and none was made.

---

## 41. An installed record is a record of the install, not of the writer

**Condition.** Licence material has to reach whoever receives the library. The
four upstream grants are upstream's own files, and `NOTICE.md`,
`FORK-LICENSE.md`, `UPSTREAM.md` and `README.upstream.md` are this fork's, and
both sets are terms of one redistribution: the grant a recipient must be able
to read about a `libgmp` built from these sources covers the sources, not only
the ones that came out of the archive.

**Two owners was the defect.** `addInstalledRecords` installed `licence_files`
and `metadata_files`, and `package.nix:78-81` wrote the other four with
`install -Dm644` after the build had returned. A Nix package was therefore
complete and a `zig build install` prefix was not: the same library, delivered
two ways, with this fork's grant and provenance present in one and missing from
the other. The native prefix is the one a `dep.artifact("gmp")` consumer, a
distributor and a downstream packager reach first, so it is the one where a
missing `FORK-LICENSE.md` is least likely to be noticed and most expensive.

**Fix.** The build graph owns every installed record. `fork_record_files` sits
beside `licence_files` and `metadata_files` and installs through the same loop
and the same `share/licenses/gmp` destination expression, so the records cannot
be routed away from the grants or given a mode of their own; `package.nix` keeps
one `zig build install` and writes no path; the provenance gate names all eight
against that one owner instead of checking half of the set in each of two files.
Nothing is duplicated into the derivation and nothing is dropped from the
build.

**Rule.** Decide who owns an installed file by what the file is, not by which
tool happens to run last. A record that exists only in the packaging layer is
invisible to every delivery path that does not go through that packaging, and a
redistribution obligation is not discharged on one of several routes.
Documenting a split in three files and checking half of it in two does not make
it safe: it makes it read as a decision, which is what the three documents said
about this one.

**Targets bound.** No ABI, exported symbol, header or `gmp.pc` content changes
in any configuration, both linkage modes are untouched, `-fsys=gmp` builds no
artifact and installs nothing as before, and the four upstream grant texts still
install from the same call to the same paths with the same defaults.
`SOURCE-CONFIRMED` from `build.zig`, `package.nix` and `tools/provenance_gate.sh`
read as written; not observed from a run, and none was made by this change.

## 42. A published recipe is not the package's rule until it says the same condition

**Condition.** A document that shows a configuration-dependent step. Three
published statements here described a condition the working code beside them
already answered differently.

**Symptom.** `README.zig.md`'s quick start guarded `dep.artifact("gmp")` on
`-fsys=gmp` alone, so a dependent that copied it and built `-Druntime=true`
linked `libgmp` into a graph whose calls go through the dispatch `load` is
meant to fill; `consumer/build.zig:135-137` and `build.zig:360-365` both refuse
that link and both say why. `consumer/build.zig` built its run step without
`b.args` while `consumer/src/main.zig:7-8` documents `--provider <path>` as a
command-line input, so the flag a caller passed was dropped and the program
fell through to `GMP_TEST_PROVIDER` and reported that it had been told nothing.
And `runtime/library.zig` — the file `README.zig.md` names as the provider ABI
boundary — said `mp_limb_t` is `unsigned long` on every target including LLP64
and called a `_LONG_LONG_LIMB` provider not interchangeable, while
`gmp-h.in:137-145` puts the typedef behind that macro and
`zig/config_gen.zig:224-230` emits it wherever the target's `long` is under 64
bits, so this build's own `x86_64-windows-gnu` limb is `unsigned long long int`.

**Fix.** The quick start declares `runtime`, forwards it unchanged and guards on
it as well; the consumer forwards `b.args`; `runtime/library.zig` states both
arms and cites the upstream input and this fork's generator for the choice.

**Rule.** A snippet documents the graph; it does not illustrate it. Derive a
documented condition from the code that enforces it and keep the two in step,
because a snippet short by one guard does not fail where the package fails — it
fails later, in the dependent, in exactly the configuration the guard was about.
A provider-ABI document has to state what the *generated* header says for the
target, which on this fork is two arms and not one.

**Targets bound.** No API, no cast, no linkage default, no generated header and
no native byte changes: the quick start is prose, `b.args` reaches only the run
step of this tree's own consumer, and the limb typedef is read from `gmp-h.in`
and `zig/config_gen.zig`, both untouched. `SOURCE-CONFIRMED` from the files as
written; not observed from a run.

## 43. A prefix under `$PWD` is still inside the checkout, and so is the default

**Condition.** A CI step that installs and does not name `--prefix`. Zig's
default prefix is `<package root>/zig-out`, which inside a checkout is the SDK
tree itself.

**Symptom.** `.github/workflows/ci.yml` had three installing steps at that
default — `verify`'s build, `shared`'s shared install and `runtime`'s
`-Druntime=true` install — and one step already naming a prefix of its own,
`runtime`'s provider. That prefix was `$PWD/zig-out-provider`, which is
*inside* the checkout like the default: the convention reached one step of one
job, and where it did reach it the tree was still left dirty.

**Fix.** Every prefix in the workflow is under `$RUNNER_TEMP`, the runner's own
scratch root and outside `$GITHUB_WORKSPACE`: `$RUNNER_TEMP/gmp-install` for
the three installing steps, `$RUNNER_TEMP/gmp-provider` for the provider build
and for the `GMP_TEST_PROVIDER` path read back from it. The two are separate
roots, so nothing a later install step writes can disturb the provider. Steps
that install nothing — `test`, `smoke`, `check`, `cross` — are unchanged, as is
the consumer package's own artifact, which `devenv.nix` already gives a prefix
of its own (CHANGELOG entry 25).

**Rule.** A prefix is only external if it is *outside* the checkout: naming
`$PWD/<name>` moves where the install lands without moving it out of the tree,
and nothing in the file lets a reader tell those two apart. Redirect every step
that reaches `b.getInstallStep()`, not only the one whose name says install — a
plain `zig build` installs — and move the prefixes that were already explicit
in the same change, or the file keeps one convention that does not hold. Follow
the rest of the step graph too: `smoke` and the consumer run both hang off an
install step (`build.zig:238`, `consumer/build.zig:143`), so a moved prefix
moves with them, and an installed program still finds its library relatively
(`$ORIGIN/../lib`, `installedProgramRPath`).

**Targets bound.** CI metadata only. No build graph, option, flag, target or
install destination inside the package changed, and no step, trigger, matrix
cell or job was added, removed or reordered — only the prefix each installing
step names, and the `GMP_TEST_PROVIDER` path derived from the same build.
`SOURCE-CONFIRMED` from the workflow as written.
**No CI run exists**: this repository is local and unpublished, so every line
here is unexecuted.

## 44. A public spelling that is a macro chain is two promises, and one of them was empty

**Condition.** The low-level layer, where GMP's own public spelling is a macro
and not a declaration. `gmp-h.in:249-251` defines `__MPN(x)` as `__gmpn_##x`,
and `gmp-h.in:1470-1700` writes that family as object-like
`#define mpn_<name> __MPN(<name>)` above each declaration — `mpn_add` at
`:1470`, `mpn_add_1` at `:1475`, `mpn_cmp` at `:1486`, `mpn_sub_1` at `:1615`.
Each `mpn_*` name and the `__gmpn_*` symbol it renames are therefore one
function, and the raw route has to offer both spellings of it.

**Symptom, observed by the parent.** From `gmp/`,
`zig build test -Dtarget=x86_64-linux -Druntime=false -j8 --summary all`
(with the cache, global-cache and `--prefix` arguments recorded in the
receipt) exited 1 after 7.87s with 20 of 23 steps done — receipt
`artifact://19872`, parent background id 1164. The native `libgmp` archive step
and the translate-c step both succeeded, in 2s and 50ms, so neither the C build
nor translation-as-a-step was what failed. Two regression tests in the
translated module did: `gmp.c.mpn_add_1` reached an undefined `add_1`
(`zig/test/known_answers.zig:366`) and `gmp.c.mpn_cmp` an undefined `cmp`
(`:423`). `mpn_sub_1` is called the same way at `:389` and `:401` and is the
same family; it is named here as surface read out of source, not as a third
observed failure.

**Why that is a contract failure and not a test detail.** The raw route is
published as complete — `README.zig.md:243-248`, `root.zig:8-10` and
`root.zig:127` — and `zig/example/main.zig:171/174-180` drives `mpn_*` by name.
The `__gmpn_*` spelling reached the exported symbol; the `mpn_*` spelling, the
one GMP's own header hands a C caller, did not.

**Repair, as landed in source.** In the private aggregate only, 77 object-like
`mpn_*` aliases are each individually guarded and each mapped straight to its
own `__gmpn_*` symbol, so a routine the target's headers do not declare is not
given one. The three function-like macros — `mpn_divexact_by3`
(`gmp-h.in:1499`), `mpn_divmod_1` (`:1505`) and `mpn_divmod` (`:2302`, in the
GMP 2 source-compatibility block and outside the alias run) — are untouched, as
are the upstream inputs: `gmp-h.in`, the C sources of `libgmp` and the
generated `gmp.h` are not edited, so no symbol or ABI moves. No GMP
declaration, macro or spelling is dropped. The 77 is confirmed on both sides:
`gmp-h.in:1470-1700` holds 77 object-like `#define mpn_<name> __MPN(<name>)`
lines — 76 written with one space, `mpn_cnd_swap` at `:1668` with two — and
`include/gmp_all.h` holds 77 individually guarded `#undef` / `#define mpn_<name>
__gmpn_<name>` pairs whose names track that list in the same order. The header edit
belongs to the runtime/translation change, and its layout is final: lines 1-64
are the original aggregate ending in `#include <gmp.h>`, 66-73 the rationale,
74-381 the 77 guarded entries, 383-385 the NetBSD rationale, and 386-388 the
`#if defined(__NetBSD__)` / `#undef __ALIGNBYTES` / `#endif` pair.

The NetBSD-only `#undef` of `__ALIGNBYTES` is a separate change with a separate
cause and its own pending result: on AAPCS64, NetBSD defines it as the implicit
compiler typedef `__int128_t`, which is a platform-internal macro that no GMP
source or declaration uses (`include/gmp_all.h:383-385`). It is removed only
under `#if defined(__NetBSD__)` and only after every include has resolved, so it
costs no GMP name. Nothing in this note's condition or observation covers it,
and nothing in it licenses dropping a GMP name.

**Rule.** Where a library publishes a public name as a macro that renames a
function, "the raw API is complete" reads as *every* published spelling
resolves to a symbol that exists, not as the underlying declaration being
present. A translation step reported as succeeding proves the step ran; it does
not prove the name it emitted refers to anything. Reach, in a test, the name a
consumer actually calls — not only the name the library exports.

**Targets bound.** No native C byte, no upstream header, no generated input, no
ABI typedef, no linkage default and no `build.zig` line changes; note 40's
preprocessing record is otherwise unchanged. **The AFTER gate has now run**, by
the parent and not by this change: background 1174 for this SDK's own suite,
1181 for the linked static dependent and 1182 for the loaded static one. Both
spellings reaching one symbol is observed for those two cases; note 45 carries
the receipts and states the boundary.

## 45. An alias fix is proved by the matrix that runs it, and bounded by the routes that were not run

**Condition.** A private-aggregate change whose whole point is that a name
reaches a symbol. Nothing inside this tree can establish that, because every
consumer here is built by the same graph that made the change.

**What was observed, by the parent.** Five runs, none of them mine.

* Background 1174 — this SDK's own test run on `x86_64-linux`: 23 of 23 steps,
  49 of 49 tests, exit 0, 5.61s.
* Background 1178 — all eight configurations, static and dynamic crossed with
  Debug, ReleaseSafe, ReleaseFast and ReleaseSmall; `test`, `smoke` and
  `install` pass in every one, 49 of 49 each.
* Background 1185 — the 53-cell cross matrix, receipt
  `20261004T224549506489Z-25324/gmp-53-target-8.json`: 8 of 8 jobs completed,
  `source_stamp_before == source_stamp_after` (`8046351d…`). Raw
  `pass=19 fail=1 build_only=27 partial=6`; corrected `pass 19 / build_only 33 /
  build_fail 1`. Nineteen cells ran on a real target and passed 49 of 49 each;
  thirty-three are build-only, six of them `reason: partial_execution`, which is
  what the correction from the earlier pass-scored attempt withdraws. The one
  build failure is `hexagon-linux`. Both NetBSD targets compiled and **neither was
  executed** (`run=unavailable` and `run=partial`), and no native header changed.
* Background 1181 — the scratch dependent `gmp-alias-proof`, linked static: 3 of
  3 known-answer checks, 23 of 23 steps.
* Background 1182 — the same dependent, loaded static: 3 of 3, against a real
  `GMP_TEST_PROVIDER` naming `gmp-shared/lib/libgmp.so.10.5.0` and the
  runtime-generated dispatch rather than a linked library.

**The dependent's own first failure is part of the record.** It failed before
it reached GMP, on an absolute path in its scratch `build.zig.zon`, which the
parent corrected to a relative path confined to scratch. Keeping it here is the
point: a green run whose predecessor failed on packaging is not a clean first
attempt, and a record that showed only the green one would overstate it.

**Compiled inputs did not change during verification.** The source digests taken
before and after the eight-mode run are identical at `764eb8e0b9d7b83b` across
all 6070 compiled files, so what the compiler consumed did not move while the
verification ran. It is not a statement about the import baseline — every upstream
byte rests on the protected `UPSTREAM.sha256` record and
`tools/provenance_gate.sh`, a source assertion until the full SHA-256 and licence
gate — and nothing about a consumer's ELF layout or its data ABI is inferred from
it. Receipts are `run.json` and `prefix-map.json` under
`/home/tmp2/gertullj/scratch/foundation-libs/native-final-evidence/gmp-alias-native-final-after-20261004/`.

**Rule.** Prove a translation or linkage repair from the matrix that actually
runs it, and add a dependent for the route the matrix cannot cover — here the
private aggregate, which no in-tree consumer reaches the way an outside package
does. Then bound the claim in both directions: do not narrow what the matrix has
already earned, and do not widen what the dependent has not. Name the two states
a digest compares before quoting it: "unchanged during verification" and
"unchanged since the import" are different claims, and only the second one is
about byte preservation.

**Targets bound, and what the evidence does not reach.** The private aggregate and
the carry/borrow/compare behind it are exercised across the whole SDK matrix: all
four optimize modes crossed with static and dynamic, 49 of 49 each. The
independent dependent is narrower and is stated at its real width — Debug,
static, two routes, three known-answer checks. Nothing here claims dynamic
linkage for the dependent or the other three optimize modes for it. The
system-library configuration is observed separately, in this SDK's own case:
background 1239 built against an own installed GMP — GNU, Debug, dynamic consumer
— compiled and executed it with the checkout unchanged, receipt
`nested-delivery-proof/evidence/20261004T235856750722Z-fed3d94ed7d6/index.json`.
That is this package's own installed-GMP case and not an independent external
provider result; the two are never merged into a single claim. NetBSD is not
open as a build: both NetBSD targets compile in the ordinary SDK matrix and in the
53-cell run, and neither has been executed there.
The strict preservation comparator over the saved header has since run:
background 1238 verified both NetBSD namespaces, 77 of 77 aliases
and native functions, and full translated and preprocessed C payload preservation —
receipt `comparison-20261004T235215309787Z-38840`. One bound travels with it: the data
aliases `mp_bits_per_limb` and `gmp_version` fail container-const initialization
before and after on both targets, observed, with control evidence
`20261005T001849274984Z-70688` retaining the before state at four mixed ALIGN and
initializer errors and the after state at four clean initializer controls. No
data-alias usability or isolation PASS is claimed.
