# Changelog

* Fix Linux header translation with target-derived obstack declarations; exclude WASI from dynamic and runtime cross-target checks.
* Port to Zig 0.17.0.
* Raw `mpn_*` names resolve to their matching exported `__gmpn_*` symbols.
* Runtime dispatch excludes libc symbols from the provider's required symbol set.
* System-library mode (`-fsys=gmp`) uses the translated module and has no linkable `gmp` artifact; it rejects `-Druntime=true`.
* NetBSD and OpenBSD aggregate-header translation uses the target preprocessor.
* Native installs include the upstream licence texts and the fork's licence and provenance records.
* Runtime-loaded consumers select a provider with `--provider` or `GMP_TEST_PROVIDER`; the build does not infer one.
* `Rand.nextBits` and `Rand.nextBelow` return `TooManyBits` and `EmptyRange` for invalid requests instead of relying on assertions.
* Facade word operations use GMP's target C word types; bit counts use `mp_bitcnt_t`, and `bitLength` returns `usize`.
* The raw GMP accessors return GMP pointer types for integer, rational, float, and random-state values.
* `Rational.parse` preserves the representation returned by GMP and does not canonicalize it.
* `parse` and `setStr` take NUL-terminated strings; `writeTo` returns NUL-terminated output, and owned strings release their exact allocation size.
* Rendering accepts bases 2 through 62 and returns `InvalidBase` otherwise; parsing still accepts base 0.
* `writeTo` uses GMP's documented capacity bounds; `Float.writeTo` rejects a digit count of zero with `InvalidDigitCount`.
* Float rendering returns GMP's significant digits and exponent, without a radix point or trailing zeroes.
* `BigInt.sizeinbase` returns `FormatError!u64`.
* Removed the non-GMP nibble-swap helper from the facade.
* GMP configuration headers derive limb width and endianness from the target, not the build host.
* Table generators run on the build host with the target's limb parameters; generated files stay in the Zig cache.
* The library uses GMP's portable generic C backend with `NO_ASM`; it does not select tuned assembly.
* The package builds `libgmp`, not `libgmpxx` or `mini-gmp`, and includes the complete generic-path public C API.
