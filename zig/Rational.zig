//! GMP rational wrapper; arithmetic expects canonical operands.
//! Parsing and assignment can preserve noncanonical forms.

const std = @import("std");
const c = @import("c");
const bases = @import("base.zig");

const bigint = @import("BigInt.zig");
const BigInt = bigint.BigInt;

pub const ParseError = bigint.ParseError;
pub const FormatError = bigint.FormatError;
pub const OwnedString = BigInt.OwnedString;

fn cmpToOrder(value: c_int) std.math.Order {
    return if (value == 0) .eq else if (value > 0) .gt else .lt;
}

pub const Rational = struct {
    /// The underlying GMP value, exposed for raw C access.
    raw: c.mpq_t,

    /// Mutable GMP pointer borrowed from this value; it expires on release or move.
    pub fn rawPtr(self: *Rational) c.mpq_ptr {
        return &self.raw[0];
    }

    /// Read-only GMP pointer borrowed from this value; it expires on release or move.
    pub fn rawSrcPtr(self: *const Rational) c.mpq_srcptr {
        return &self.raw[0];
    }

    /// Allocate an initialised value equal to 0/1, in canonical form.
    pub fn init() Rational {
        var self: Rational = .{ .raw = undefined };
        c.mpq_init(self.rawPtr());
        return self;
    }

    /// Release the GMP allocation; call once and do not use the value afterwards.
    pub fn deinit(self: *Rational) void {
        c.mpq_clear(self.rawPtr());
    }

    /// Parse `n/d`, `n`, or `d`; base 0 enables prefix detection per component.
    /// Returns an owned value; parsing does not canonicalize and errors release it.
    pub fn parse(text: [:0]const u8, base: u8) ParseError!Rational {
        var self = Rational.init();
        errdefer self.deinit();
        try self.setStr(text, base);
        return self;
    }

    /// Parse into `self`; base 0 enables prefix detection, but does not canonicalize.
    /// `error.InvalidDigit` may leave `self` partly assigned; use `parse` for all-or-error.
    pub fn setStr(self: *Rational, text: [:0]const u8, base: u8) ParseError!void {
        if (!bases.validInputBase(base)) return error.InvalidBase;
        if (c.mpq_set_str(self.rawPtr(), text.ptr, base) < 0) return error.InvalidDigit;
    }

    /// Set and canonicalize `top / bottom`; `bottom` must be nonzero.
    /// GMP aborts on a zero denominator; this method cannot return an error.
    pub fn setFraction(self: *Rational, top: *const BigInt, bottom: *const BigInt) void {
        c.mpq_set_z(self.rawPtr(), top.rawSrcPtr());
        c.mpq_set_den(self.rawPtr(), bottom.rawSrcPtr());
        c.mpq_canonicalize(self.rawPtr());
    }

    /// Set the value to the integer `value`.
    pub fn setInteger(self: *Rational, value: *const BigInt) void {
        c.mpq_set_z(self.rawPtr(), value.rawSrcPtr());
    }

    /// Set `top / bottom`; GMP canonicalizes zero numerators but does not reject zero denominators.
    /// A nonzero numerator with zero `bottom` leaves invalid state; validate the denominator first.
    pub fn setUi(self: *Rational, top: c_ulong, bottom: c_ulong) void {
        c.mpq_set_ui(self.rawPtr(), top, bottom);
    }

    /// Copy without canonicalizing.
    pub fn set(self: *Rational, other: *const Rational) void {
        c.mpq_set(self.rawPtr(), other.rawSrcPtr());
    }

    /// Return an independent owned copy, preserving `self`'s canonicality.
    pub fn clone(self: *const Rational) Rational {
        var copy = Rational.init();
        copy.set(self);
        return copy;
    }

    /// Reduce to canonical form: positive denominator and coprime parts.
    pub fn canonicalize(self: *Rational) void {
        c.mpq_canonicalize(self.rawPtr());
    }

    /// Exchange the values of `self` and `other`.
    pub fn swap(self: *Rational, other: *Rational) void {
        c.mpq_swap(self.rawPtr(), other.rawPtr());
    }

    /// `self = a + b`.
    pub fn add(self: *Rational, a: *const Rational, b: *const Rational) void {
        c.mpq_add(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self = a - b`.
    pub fn sub(self: *Rational, a: *const Rational, b: *const Rational) void {
        c.mpq_sub(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self = a * b`.
    pub fn mul(self: *Rational, a: *const Rational, b: *const Rational) void {
        c.mpq_mul(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self = a / b`. `b` must not be zero.
    pub fn div(self: *Rational, a: *const Rational, b: *const Rational) void {
        c.mpq_div(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self += other`.
    pub fn addAssign(self: *Rational, other: *const Rational) void {
        c.mpq_add(self.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr());
    }

    /// `self = -self`.
    pub fn negAssign(self: *Rational) void {
        c.mpq_neg(self.rawPtr(), self.rawSrcPtr());
    }

    /// `self = |self|`.
    pub fn absAssign(self: *Rational) void {
        c.mpq_abs(self.rawPtr(), self.rawSrcPtr());
    }

    /// `self = 1 / self`. `self` must not be zero.
    pub fn inv(self: *Rational) void {
        c.mpq_inv(self.rawPtr(), self.rawSrcPtr());
    }

    /// Compare by value.
    pub fn cmp(self: *const Rational, other: *const Rational) std.math.Order {
        return cmpToOrder(c.mpq_cmp(self.rawSrcPtr(), other.rawSrcPtr()));
    }

    /// Compare with zero through GMP's declared `_mpq_cmp_si` function.
    pub fn cmpZero(self: *const Rational) std.math.Order {
        return cmpToOrder(c._mpq_cmp_si(self.rawSrcPtr(), 0, 1));
    }

    /// Compare with a fraction of target-width words through `_mpq_cmp_ui`.
    pub fn cmpUi(self: *const Rational, top: c_ulong, bottom: c_ulong) std.math.Order {
        return cmpToOrder(c._mpq_cmp_ui(self.rawSrcPtr(), top, bottom));
    }

    /// Test whether the numerator is zero; the rational must be canonical.
    /// Noncanonical values can trigger GMP assertions.
    pub fn isZero(self: *const Rational) bool {
        return self.cmpZero() == .eq;
    }

    /// Test whether the value is negative; the rational must be canonical.
    pub fn isNegative(self: *const Rational) bool {
        return self.cmpZero() == .lt;
    }

    /// Return an independent `BigInt` copy of the numerator.
    pub fn numerator(self: *const Rational) BigInt {
        var result = BigInt.init();
        c.mpq_get_num(result.rawPtr(), self.rawSrcPtr());
        return result;
    }

    /// Return an independent `BigInt` copy of the denominator.
    pub fn denominator(self: *const Rational) BigInt {
        var result = BigInt.init();
        c.mpq_get_den(result.rawPtr(), self.rawSrcPtr());
        return result;
    }

    /// Truncating conversion to `f64`.
    pub fn getDouble(self: *const Rational) f64 {
        return c.mpq_get_d(self.rawSrcPtr());
    }

    /// Render into caller storage; the sentinel result borrows `buffer`.
    /// Requires both part digit counts plus three bytes, an upper bound that may overestimate.
    pub fn writeTo(self: *const Rational, buffer: []u8, base: u8) FormatError![:0]const u8 {
        if (!bases.validOutputBase(base)) return error.InvalidBase;

        // Read GMP's numerator and denominator fields directly because their accessors are macros.
        const num_digits = c.mpz_sizeinbase(&self.raw[0]._mp_num, base);
        const den_digits = c.mpz_sizeinbase(&self.raw[0]._mp_den, base);
        const needed = num_digits +| den_digits +| 3;
        if (buffer.len < needed) return error.BufferTooSmall;

        // A valid base makes this in-place GMP result non-null.
        _ = c.mpq_get_str(buffer.ptr, base, self.rawSrcPtr());
        const terminated: [*:0]const u8 = @ptrCast(buffer.ptr);
        return buffer[0..std.mem.len(terminated) :0];
    }

    /// Allocate text through GMP; release it with `OwnedString.deinit`.
    /// Only an invalid base is returned; GMP allocation failures do not return.
    pub fn toOwnedString(self: *const Rational, base: u8) FormatError!OwnedString {
        if (!bases.validOutputBase(base)) return error.InvalidBase;
        // Valid bases return a pointer; GMP allocation failure does not return.
        const raw: [*c]u8 = c.mpq_get_str(null, base, self.rawSrcPtr());
        // GMP shrinks the block to text plus NUL, the size `deinit` must free.
        const terminated: [*:0]const u8 = @ptrCast(raw);
        return .{ .ptr = raw, .len = std.mem.len(terminated) };
    }
};
