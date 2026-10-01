//! Zig package root for the GMP 6.3.0 fork.
//!
//! Two layers are on offer and they are meant to be used together:
//!
//!   * `gmp.c` is the complete translated GMP API. Every `mpz`, `mpq`, `mpf`,
//!     `mpn`, `gmp_rand` and `gmp_printf` entry point of GMP 6.3.0 is there,
//!     translated from the generated `gmp.h`, with no omissions. It is the
//!     escape hatch for anything the facade does not cover.
//!   * `BigInt`, `Rational`, `Float` and `Rand` are owned Zig types over the
//!     same values, with explicit `deinit` and no global allocator hooks.
//!
//! Memory follows GMP: values are allocated by GMP's own allocator and freed
//! by `mpz_clear`, `mpq_clear` or `mpf_clear`. Strings GMP allocates are
//! returned as `OwnedString` and released through GMP's own free function with
//! the size of the block, which is what GMP's allocator contract asks for.
//! Nothing here replaces `gmp_allocate_func`, and nothing borrows a pointer
//! beyond the lifetime of its owner.
//!
//! Text crosses into GMP the way GMP reads it: `parse` and `setStr` take a
//! sentinel terminated `[:0]const u8` and hand the pointer straight over, and
//! `writeTo` returns the caller's own buffer as one, so rendered text can be
//! parsed again without a copy in between.
//!
//! The library is the real GNU MP library, built from the complete source tree
//! with the portable C backend (`NO_ASM`, mpn path `generic`). See README.zig.md
//! for what that means for performance and ABI.

const std = @import("std");

/// The complete translated GMP C API.
pub const c = @import("c");

/// The facade files, taken whole: each wraps its type and its supporting
/// declarations in one file, and `@import` of a path yields that file's own
/// namespace rather than the type it declares.
const bigint = @import("zig/BigInt.zig");
const rational = @import("zig/Rational.zig");
const float = @import("zig/Float.zig");
const rand = @import("zig/Rand.zig");

/// Owned integer, GMP `mpz_t`.
pub const BigInt = bigint.BigInt;

/// Owned rational number, GMP `mpq_t`.
pub const Rational = rational.Rational;

/// Owned binary floating point number, GMP `mpf_t`.
pub const Float = float.Float;

/// Owned random state, GMP `gmp_randstate_t`.
pub const Rand = rand.Rand;

/// GMP version this package was built from, as encoded in the generated
/// `gmp.h` (`__GNU_MP_VERSION` and friends).
pub const version = .{
    .major = c.__GNU_MP_VERSION,
    .minor = c.__GNU_MP_VERSION_MINOR,
    .patchlevel = c.__GNU_MP_VERSION_PATCHLEVEL,
};

/// Upstream release this fork tracks.
pub const upstream_version = "6.3.0";

/// Bits per limb of the generated `gmp.h`, which is ABI critical: 64 on every
/// 64-bit target including LLP64 Windows, 32 on 32-bit pointer targets.
pub const limb_bits = c.GMP_LIMB_BITS;

/// Render the GMP version of the generated header, for diagnostics.
pub fn versionString(buffer: []u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{ version.major, version.minor, version.patchlevel });
}

/// Division rounding modes, re-exported for convenience.
pub const DivisionMode = bigint.DivisionMode;

/// Result of `BigInt.div`, both parts owned by the caller.
pub const Division = bigint.Division;

/// A NUL terminated string allocated by GMP, released with `deinit`.
pub const OwnedString = BigInt.OwnedString;

/// Errors from parsing.
pub const ParseError = bigint.ParseError;

/// Errors from rendering into caller owned storage.
pub const FormatError = bigint.FormatError;

/// Compile-time and run-time exercise of every public facade method.
///
/// `zig build check` compiles this for every supported target so the whole
/// facade is instantiated; `zig build test` also runs it natively.
pub const api_exercise = @import("zig/api_exercise.zig");

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
