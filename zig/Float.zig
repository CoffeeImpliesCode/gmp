//! GMP `mpf_t` wrapper. Precision rounds up to limbs and results truncate.
//! `mpf` has no NaN or infinity; base 0 parsing means base 10.

const std = @import("std");
const c = @import("c");
const bases = @import("base.zig");

/// Errors from parsing text into a value.
pub const ParseError = error{
    /// `mpf_set_str` rejected the text.
    InvalidFormat,
    /// Base must be 0 or 2..62; GMP treats 0 as decimal.
    InvalidBase,
};

/// Errors from rendering a value into text.
pub const FormatError = error{
    /// The base is outside GMP's output range 2..62.
    InvalidBase,
    /// `digits` is zero; GMP does not report the resulting digit count.
    InvalidDigitCount,
    /// `buffer` is shorter than `digits + 2`, so nothing was written.
    BufferTooSmall,
};

/// Text and radix-point exponent returned by `mpf_get_str`.
pub const Rendered = struct {
    /// Significant digits borrowed from the buffer; no radix point or trailing zeroes.
    text: [:0]const u8,
    /// Exponent in `0.text * base^exponent`.
    exponent: i64,
};

fn cmpToOrder(value: c_int) std.math.Order {
    return if (value == 0) .eq else if (value > 0) .gt else .lt;
}

pub const Float = struct {
    /// The underlying GMP value, exposed for raw C access.
    raw: c.mpf_t,

    /// Mutable GMP pointer borrowed from this value; it expires on release or move.
    pub fn rawPtr(self: *Float) c.mpf_ptr {
        return &self.raw[0];
    }

    /// Read-only GMP pointer borrowed from this value; it expires on release or move.
    pub fn rawSrcPtr(self: *const Float) c.mpf_srcptr {
        return &self.raw[0];
    }

    /// Initialize zero with at least `precision_bits`; GMP rounds precision up to limbs.
    pub fn init(precision_bits: c.mp_bitcnt_t) Float {
        var self: Float = .{ .raw = undefined };
        c.mpf_init2(self.rawPtr(), precision_bits);
        return self;
    }

    /// Release the GMP allocation; call once and do not use the value afterwards.
    pub fn deinit(self: *Float) void {
        c.mpf_clear(self.rawPtr());
    }

    /// Parse NUL-terminated text into `self`; base 0 means decimal and locale sets the radix point.
    /// Errors leave the value and its precision unchanged.
    pub fn setStr(self: *Float, text: [:0]const u8, base: u8) ParseError!void {
        if (!bases.validInputBase(base)) return error.InvalidBase;
        if (c.mpf_set_str(self.rawPtr(), text.ptr, base) < 0) return error.InvalidFormat;
    }

    /// Parse into a new value; errors release any partially initialized value.
    pub fn parse(text: [:0]const u8, precision_bits: c.mp_bitcnt_t) ParseError!Float {
        var self = Float.init(precision_bits);
        errdefer self.deinit();
        try self.setStr(text, 0);
        return self;
    }

    /// Copy into `self`, truncating to its precision.
    pub fn set(self: *Float, other: *const Float) void {
        c.mpf_set(self.rawPtr(), other.rawSrcPtr());
    }

    /// Set from `f64`, truncating to the destination precision.
    pub fn setDouble(self: *Float, value: f64) void {
        c.mpf_set_d(self.rawPtr(), value);
    }

    /// Set from target-width `unsigned long`.
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

    /// `self = a^exponent`, with a target-width unsigned exponent.
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

    /// Return the limb-rounded precision stored by GMP.
    pub fn getPrecision(self: *const Float) c.mp_bitcnt_t {
        return c.mpf_get_prec(self.rawSrcPtr());
    }

    /// Set at least `precision_bits`, truncating the value toward zero.
    /// GMP rounds to whole limbs and reallocates the value.
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

    /// Return -1, 0, or 1 from GMP's `_mp_size` field.
    pub fn sign(self: *const Float) i32 {
        if (self.raw[0]._mp_size == 0) return 0;
        return if (self.raw[0]._mp_size < 0) -1 else 1;
    }

    /// Test zero through GMP's normalized `_mp_size`; `mpf` has no NaN or infinity.
    pub fn isZero(self: *const Float) bool {
        return self.sign() == 0;
    }

    /// Test whether the value is negative; zero is not negative.
    pub fn isNegative(self: *const Float) bool {
        return self.sign() < 0;
    }

    /// Test whether the value is positive; zero is not positive.
    pub fn isPositive(self: *const Float) bool {
        return self.sign() > 0;
    }

    /// Convert to `f64`, truncating toward zero; out-of-range exponents are unpredictable.
    pub fn getDouble(self: *const Float) f64 {
        return c.mpf_get_d(self.rawSrcPtr());
    }

    /// Render significant digits into caller storage; `Rendered.text` borrows `buffer`.
    /// Requires `digits >= 1` and `digits + 2` bytes; GMP rounds half up, errors write nothing.
    pub fn writeTo(self: *const Float, buffer: []u8, base: u8, digits: usize) FormatError!Rendered {
        if (!bases.validOutputBase(base)) return error.InvalidBase;
        if (digits == 0) return error.InvalidDigitCount;

        // Subtract to avoid overflow when checking large digit counts.
        if (buffer.len -| digits < 2) return error.BufferTooSmall;

        // With the base validated, GMP cannot return null for a short buffer.
        var exponent: c.mp_exp_t = 0;
        _ = c.mpf_get_str(buffer.ptr, &exponent, base, digits, self.rawSrcPtr());

        const terminated: [*:0]const u8 = @ptrCast(buffer.ptr);
        return .{
            .text = buffer[0..std.mem.len(terminated) :0],
            .exponent = @intCast(exponent),
        };
    }
};
