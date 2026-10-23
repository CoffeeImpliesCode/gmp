# Zig facade API

## Exports

| Name | Description |
| --- | --- |
| `BigInt` | Owned GMP `mpz_t` integer. |
| `Rational` | Owned GMP `mpq_t` rational. |
| `Float` | Owned GMP `mpf_t` binary float. |
| `Rand` | Owned GMP random state. |
| `c` | Translated GMP C declarations. |
| `DivisionMode`, `Division` | Integer division rounding and owned quotient/remainder. |
| `OwnedString`, `ParseError`, `FormatError` | Integer and rational text results and errors. |
| `runtime_loaded`, `LoadSource`, `LoadError` | Runtime-loading state and types. |
| `version`, `versionString`, `upstream_version`, `limb_bits` | Build version and target limb width. |
| `providerVersion`, `providerErrno`, `providerBitsPerLimb` | Values read from the linked or loaded library. |

`DivisionMode` is `.truncated`, `.floor`, or `.ceiling`. `Division.deinit` releases both owned results.

## Values and operations

| Type | Common API |
| --- | --- |
| `BigInt` | `init`, `parse`, `parseOrNull`, `setStr`, `clone`, `add`, `sub`, `mul`, `div`, `divexact`, `mod`, `gcd`, `lcm`, `powm`, shifts, bit operations, comparisons, and conversions. |
| `Rational` | `init`, `parse`, `setStr`, `setFraction`, `canonicalize`, arithmetic, comparisons, `numerator`, and `denominator`. |
| `Float` | `init(precision_bits)`, `parse`, `setStr`, arithmetic, `sqrt`, `pow`, precision access, comparisons, and conversions. |
| `Rand` | `initMt` or `initDefault`, `seed`, `nextBits`, and `nextBelow`. |

Each initializer or successful parse returns one owned value. Call its `deinit` once. Struct assignment copies the handle, not the GMP allocation. Use `clone` for an independent value.

```zig
const gmp = @import("gmp");

var value = try gmp.BigInt.parse("12345678901234567890", 10);
defer value.deinit();
var buffer: [64]u8 = undefined;
const text = try value.writeTo(&buffer, 10);
```

Machine-word methods use target C types such as `c_ulong`, `c_long`, and `c.mp_bitcnt_t`. Their width depends on the target. Use `fitsUnsignedWord` or `fitsSignedWord` before conversion when the range matters.

## Text and formatting

`BigInt` and `Rational` parsing accept base 0 or 2..62. `Float.parse` uses base 0, while `Float.setStr` accepts 0 or 2..62. Base 0 enables prefix detection for integers and rationals. `Float` treats base 0 as decimal. All output bases are 2..62.

`parse` and `setStr` accept NUL-terminated `[:0]const u8` and pass the pointer to GMP without a copy.

| Method | Buffer capacity |
| --- | --- |
| `BigInt.writeTo` | `sizeinbase(value, base) + 2` bytes. |
| `Rational.writeTo` | `sizeinbase(numerator, base) + sizeinbase(denominator, base) + 3` bytes. |
| `Float.writeTo` | `digits + 2` bytes. `digits` must be positive. |

`BigInt.writeTo` and `Rational.writeTo` allocate nothing and return NUL-terminated slices borrowed from the caller's buffer. `Float.writeTo` returns `text` and `exponent` fields. A short buffer is unchanged and returns `error.BufferTooSmall`.

`BigInt.sizeinbase` may overestimate by one digit for bases that are not powers of two. Its bound is sufficient but may reject a smaller buffer that happens to fit. `Float` output has no radix point or trailing zeros. Its value is `0.text * base^exponent`. GMP `mpf` operations truncate to destination precision rather than round to nearest.

`toOwnedString` allocates through GMP and returns `OwnedString`. Its `slice` borrows the string. Call `deinit` once to free it through GMP's current allocator.

`Rational.setStr` and `set` do not canonicalize. Call `canonicalize` when required. `setFraction` canonicalizes its result. Division methods follow GMP's preconditions, including nonzero divisors. They do not return a Zig error for these conditions.

`BigInt.parse` and `Rational.parse` can return `error.InvalidBase` or `error.InvalidDigit`. `BigInt.parseOrNull` returns `null` for either. Float parsing can return `error.InvalidBase` or `error.InvalidFormat`. Formatting can return `error.InvalidBase` or `error.BufferTooSmall`. `Float.writeTo` also returns `error.InvalidDigitCount` when `digits` is zero.

`Rand.nextBits` returns `error.TooManyBits` if its request exceeds the target `c_ulong` width. `Rand.nextBelow(0)` returns `error.EmptyRange`. A fresh random state uses GMP's fixed default sequence until `seed` changes it.

## Raw C API and memory

`gmp.c` exposes the translated C API. `rawPtr` and `rawSrcPtr` return mutable and read-only pointers borrowed from a facade value. Do not retain them after the value is released.

GMP's allocator hooks are process-global. Set them before creating values because they control allocation for every GMP value. `freeNativeBlock(ptr, size)` frees a GMP block through the current library and requires its exact size.

## Runtime loading

`runtime_loaded` is a compile-time flag. In that configuration, call `load` before any GMP operation. `LoadSource.path` names an absolute file path. `LoadSource.system` names a library for the platform loader. The loader does not fall back between sources and does not unload or reset.

`providerRequest(init)` reads `--provider <path>` or `GMP_TEST_PROVIDER`. `providerFromCEnvironment` reads only `GMP_TEST_PROVIDER`. Both report `NoProviderConfigured` when no provider is named. A linked build has `runtime_loaded == false`. Calling `load` in it panics.

The loader checks that the provider's limb width matches `limb_bits`. A runtime provider must also match the generated header's limb type, endianness, nail bits, and C calling convention. `providerVersion()` borrows the provider's NUL-terminated version string. `providerErrno()` and `providerBitsPerLimb()` return pointers to provider data.
