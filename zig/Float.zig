//! Owned floating point numbers backed by GMP's `mpf_t`.
//!
//! An `mpf` value is a fixed precision binary float: `init` chooses the
//! precision, GMP rounds up to a whole limb and keeps that precision for later
//! operations. Rounding is IEEE 754 round to nearest, even, because GMP does
//! the rounding itself.
//!
//! Every signature used here was checked against the `gmp-h.in` shipped in this
//! tree. Two consequences are worth knowing:
//!
//!   * `mpf_set_str` takes three arguments in GMP 6.3, there is no digit count.
//!   * GMP 6.3 has neither `mpf_const_pi` nor `mpf_set_inf`, so the facade has
//!     no constant for pi; MPFR is the package that provides one. Use
//!     `setStr` with a literal or compute the value.

const std = @import("std");
const c = @import("c");
const bases = @import("base.zig");

pub const ParseError = error{
    /// `mpf_set_str` rejected the text.
    InvalidFormat,
    /// The base is outside GMP's documented range 0 and 2..62.
    InvalidBase,
};

pub const FormatError = error{
    /// The base is outside 2..62, the range GMP's rendering functions accept.
    /// Base 0 is a parsing convention; see `base.zig`.
    InvalidBase,
    /// `digits` is 0. GMP then renders as many digits as the precision allows
    /// and exports no way to ask for that count, so the caller must state it.
    InvalidDigitCount,
    /// `buffer` is shorter than `digits + 2`, so nothing was written.
    BufferTooSmall,
};

/// Result of `writeTo`: the significant digits plus the exponent GMP factored
/// the radix point out into, which is `mpf_get_str`'s own convention.
pub const Rendered = struct {
    /// The significant digits, borrowed from the caller's buffer and sentinel
    /// typed, so they can be parsed straight back. There is no radix point in
    /// them, and `mpf_get_str` never returns trailing zeros, so ten requested
    /// digits of the value 2 come back as the single digit "2". An empty string
    /// means the value is zero.
    text: [:0]const u8,
    /// Base point position: the value is `0.text * base^exponent`, so 3.1416
    /// in base 10 is the text "31416" with exponent 1.
    exponent: i64,
};

fn cmpToOrder(value: c_int) std.math.Order {
    return if (value == 0) .eq else if (value > 0) .gt else .lt;
}

pub const Float = struct {
    /// The GMP value itself, for the raw escape hatch (`gmp.c`).
    raw: c.mpf_t,

    /// The value as GMP's mutable C pointer, `mpf_ptr`. GMP writes through
    /// this, so it is only available on a mutable value.
    pub fn rawPtr(self: *Float) c.mpf_ptr {
        return &self.raw[0];
    }

    /// The value as GMP's read-only C pointer, `mpf_srcptr`, which is what
    /// `gmp.h` declares its operands with.
    pub fn rawSrcPtr(self: *const Float) c.mpf_srcptr {
        return &self.raw[0];
    }

    /// Allocate an initialised value with at least `precision_bits` of
    /// precision. The precision is a C `mp_bitcnt_t`, which is GMP's own
    /// parameter type for it.
    pub fn init(precision_bits: c.mp_bitcnt_t) Float {
        var self: Float = .{ .raw = undefined };
        c.mpf_init2(self.rawPtr(), precision_bits);
        return self;
    }

    /// Release the limbs GMP allocated for this value.
    pub fn deinit(self: *Float) void {
        c.mpf_clear(self.rawPtr());
    }

    /// Parse `text`. Base 0 selects the C locale format, a `.` decimal point
    /// and an optional exponent; otherwise the base must be in 2..62.
    ///
    /// `text` must be NUL terminated: `mpf_set_str` reads it as a C string and
    /// the pointer is passed through unchanged.
    ///
    /// White space is accepted, as it is by `mpz_set_str`: both functions skip
    /// leading white space (`mpf/set_str.c:142-144`, `mpz/set_str.c:67-68`) and
    /// drop white space from the body of the number (`mpf/set_str.c:211-212`,
    /// `mpz/set_str.c:119-120`).
    ///
    /// On failure the value is undefined, as the GMP manual specifies.
    pub fn setStr(self: *Float, text: [:0]const u8, base: u8) ParseError!void {
        if (!bases.validInputBase(base)) return error.InvalidBase;
        if (c.mpf_set_str(self.rawPtr(), text.ptr, base) < 0) return error.InvalidFormat;
    }

    /// Parse `text` into a fresh value of `precision_bits` bits.
    pub fn parse(text: [:0]const u8, precision_bits: c.mp_bitcnt_t) ParseError!Float {
        var self = Float.init(precision_bits);
        errdefer self.deinit();
        try self.setStr(text, 0);
        return self;
    }

    /// Copy `other` into `self`, rounding to this value's precision.
    pub fn set(self: *Float, other: *const Float) void {
        c.mpf_set(self.rawPtr(), other.rawSrcPtr());
    }

    /// Set the value from a `double`, rounded to nearest, even.
    pub fn setDouble(self: *Float, value: f64) void {
        c.mpf_set_d(self.rawPtr(), value);
    }

    /// Set the value from an unsigned machine word, GMP's `mpf_set_ui`.
    ///
    /// The word is the target's `unsigned long`: 64 bits on LP64, 32 bits on
    /// LLP64 and 32-bit targets. For a wider value, parse it or use the raw
    /// translated C.
    pub fn setUnsignedWord(self: *Float, value: c_ulong) void {
        c.mpf_set_ui(self.rawPtr(), value);
    }

    /// `self = a + b`.
    pub fn add(self: *Float, a: *const Float, b: *const Float) void {
        c.mpf_add(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self = a - b`.
    pub fn sub(self: *Float, a: *const Float, b: *const Float) void {
        c.mpf_sub(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self = a * b`.
    pub fn mul(self: *Float, a: *const Float, b: *const Float) void {
        c.mpf_mul(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self = a / b`. `b` must not be zero.
    pub fn div(self: *Float, a: *const Float, b: *const Float) void {
        c.mpf_div(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self = a^exponent`. The exponent is a C `unsigned long`, which is
    /// `mpf_pow_ui`'s own parameter type.
    pub fn pow(self: *Float, a: *const Float, exponent: c_ulong) void {
        c.mpf_pow_ui(self.rawPtr(), a.rawSrcPtr(), exponent);
    }

    /// `self = sqrt(a)`.
    pub fn sqrt(self: *Float, a: *const Float) void {
        c.mpf_sqrt(self.rawPtr(), a.rawSrcPtr());
    }

    /// `self = sqrt(integer)`, GMP's `mpf_sqrt_ui`.
    pub fn sqrtUnsignedWord(self: *Float, value: c_ulong) void {
        c.mpf_sqrt_ui(self.rawPtr(), value);
    }

    /// Current precision in bits, GMP's `mpf_get_prec`.
    pub fn getPrecision(self: *const Float) c.mp_bitcnt_t {
        return c.mpf_get_prec(self.rawSrcPtr());
    }

    /// Change the precision, rounding the value to nearest, even.
    pub fn setPrecision(self: *Float, precision_bits: c.mp_bitcnt_t) void {
        c.mpf_set_prec(self.rawPtr(), precision_bits);
    }

    /// Compare by value.
    pub fn cmp(self: *const Float, other: *const Float) std.math.Order {
        return cmpToOrder(c.mpf_cmp(self.rawSrcPtr(), other.rawSrcPtr()));
    }

    /// Compare with a non negative machine word, GMP's `mpf_cmp_ui`.
    pub fn cmpUnsignedWord(self: *const Float, value: c_ulong) std.math.Order {
        return cmpToOrder(c.mpf_cmp_ui(self.rawSrcPtr(), value));
    }

    /// -1, 0 or 1.
    ///
    /// GMP has no `mpf_sgn`, so this reads the documented `_mp_size` field,
    /// which `gmp.h` defines as negative exactly for negative values.
    pub fn sign(self: *const Float) i32 {
        if (self.raw[0]._mp_size == 0) return 0;
        return if (self.raw[0]._mp_size < 0) -1 else 1;
    }

    pub fn isZero(self: *const Float) bool {
        return self.sign() == 0;
    }

    pub fn isNegative(self: *const Float) bool {
        return self.sign() < 0;
    }

    pub fn isPositive(self: *const Float) bool {
        return self.sign() > 0;
    }

    /// Truncating conversion to `f64`.
    pub fn getDouble(self: *const Float) f64 {
        return c.mpf_get_d(self.rawSrcPtr());
    }

    /// Render `digits` significant digits into caller owned storage.
    ///
    /// The text and exponent follow `mpf_get_str`: see `Rendered`.
    ///
    /// Capacity: `buffer.len` must be at least `digits + 2`, the digits, a
    /// possible minus sign and the terminating NUL, which is the size GMP
    /// itself allocates when it is asked to do the allocating. `digits` must
    /// be at least 1: GMP reads `digits == 0` as "as many as the precision
    /// allows", a count it computes internally from the precision and the base
    /// and does not export, so a caller that passes 0 cannot be given a
    /// capacity check and gets `error.InvalidDigitCount` instead.
    ///
    /// `mpf_get_str` never inspects a non null buffer, so this check is the
    /// only thing keeping the write in bounds. A rejected buffer is left
    /// untouched.
    pub fn writeTo(self: *const Float, buffer: []u8, base: u8, digits: usize) FormatError!Rendered {
        if (!bases.validOutputBase(base)) return error.InvalidBase;
        if (digits == 0) return error.InvalidDigitCount;

        // Saturating, so an absurd digit count cannot wrap round to a small
        // one and let an undersized buffer through.
        if (buffer.len -| digits < 2) return error.BufferTooSmall;

        // The null return of `mpf_get_str` means the base was out of range,
        // which `validOutputBase` has already excluded, and never a short
        // buffer.
        var exponent: c.mp_exp_t = 0;
        _ = c.mpf_get_str(buffer.ptr, &exponent, base, digits, self.rawSrcPtr());

        const terminated: [*:0]const u8 = @ptrCast(buffer.ptr);
        return .{
            .text = buffer[0..std.mem.len(terminated) :0],
            .exponent = @intCast(exponent),
        };
    }
};
