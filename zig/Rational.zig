//! Owned rational numbers backed by GMP's `mpq_t`.
//!
//! An `mpq` value is a pair of `mpz` limbs plus a canonicality rule: the
//! denominator is positive and the two parts are coprime. The GMP manual says
//! who maintains it (`doc/gmp.texi:4341-4348`), and this facade keeps that
//! split exactly:
//!
//!   * every rational arithmetic function **assumes its operands are
//!     canonical** and canonicalises its result, and
//!   * the pure assignment functions do **not** canonicalise, which is
//!     `parse`, `setStr`, `set` and `setInteger` here.
//!
//! So `parse("2/4", 10)` really is 2/4, and `canonicalize` is what the caller
//! runs before an arithmetic call reads a value that assignment assembled.
//! `setFraction` is the one assignment wrapper that reduces before returning:
//! it takes two integers rather than a text, so it has to pick a canonical
//! form itself, and it does exactly that with the C function rather than
//! with a private rule.

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
    /// The GMP value itself, for the raw escape hatch (`gmp.c`).
    raw: c.mpq_t,

    /// The value as GMP's mutable C pointer, `mpq_ptr`. GMP writes through
    /// this, so it is only available on a mutable value.
    pub fn rawPtr(self: *Rational) c.mpq_ptr {
        return &self.raw[0];
    }

    /// The value as GMP's read-only C pointer, `mpq_srcptr`, which is what
    /// `gmp.h` declares its operands with.
    pub fn rawSrcPtr(self: *const Rational) c.mpq_srcptr {
        return &self.raw[0];
    }

    /// Allocate an initialised value equal to 0/1.
    pub fn init() Rational {
        var self: Rational = .{ .raw = undefined };
        c.mpq_init(self.rawPtr());
        return self;
    }

    /// Release the limbs GMP allocated for this value.
    pub fn deinit(self: *Rational) void {
        c.mpq_clear(self.rawPtr());
    }

    /// Parse `n/d`, `n` or `d` in `base`.
    ///
    /// `mpq_set_str` parses the two parts independently and does **not**
    /// canonicalise, so `parse("2/4", 10)` really is 2/4. Call `canonicalize`
    /// when a reduced form is what the caller needs; arithmetic on an `mpq`
    /// always keeps its result canonical.
    ///
    /// `text` is a sentinel terminated string, which is what GMP reads: the
    /// pointer goes straight to `mpq_set_str`, with no copy and no allocation.
    pub fn parse(text: [:0]const u8, base: u8) ParseError!Rational {
        var self = Rational.init();
        errdefer self.deinit();
        try self.setStr(text, base);
        return self;
    }

    /// Replace the value with the parsed `text`.
    ///
    /// `text` must be NUL terminated: `mpq_set_str` reads it as a C string and
    /// the pointer is passed through unchanged.
    ///
    /// On failure the value is undefined, as the GMP manual specifies.
    pub fn setStr(self: *Rational, text: [:0]const u8, base: u8) ParseError!void {
        if (!bases.validInputBase(base)) return error.InvalidBase;
        if (c.mpq_set_str(self.rawPtr(), text.ptr, base) < 0) return error.InvalidDigit;
    }

    /// Set the value to `numerator / denominator`, canonicalised.
    pub fn setFraction(self: *Rational, top: *const BigInt, bottom: *const BigInt) void {
        c.mpq_set_z(self.rawPtr(), top.rawSrcPtr());
        c.mpq_set_den(self.rawPtr(), bottom.rawSrcPtr());
        c.mpq_canonicalize(self.rawPtr());
    }

    /// Set the value to the integer `value`.
    pub fn setInteger(self: *Rational, value: *const BigInt) void {
        c.mpq_set_z(self.rawPtr(), value.rawSrcPtr());
    }

    /// Set the value to `numerator / denominator` with machine words, GMP's
    /// `mpq_set_ui`, which canonicalises. The words are `unsigned long`, so
    /// they are 32 bits wide on LLP64 and 32-bit targets.
    pub fn setUi(self: *Rational, top: c_ulong, bottom: c_ulong) void {
        c.mpq_set_ui(self.rawPtr(), top, bottom);
    }

    /// Copy `other` into `self`.
    pub fn set(self: *Rational, other: *const Rational) void {
        c.mpq_set(self.rawPtr(), other.rawSrcPtr());
    }

    /// An independent copy of the value.
    pub fn clone(self: *const Rational) Rational {
        var copy = Rational.init();
        copy.set(self);
        return copy;
    }

    /// Reduce the value to canonical form: positive denominator, coprime
    /// numerator and denominator.
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

    /// Compare with zero.
    ///
    /// `gmp.h` only has `mpq_cmp_si` as a macro over `__builtin_constant_p`
    /// (`gmp-h.in:2270`), which has no translation; `_mpq_cmp_si`
    /// (`gmp-h.in:1163`) is the function both branches end up calling.
    pub fn cmpZero(self: *const Rational) std.math.Order {
        return cmpToOrder(c._mpq_cmp_si(self.rawSrcPtr(), 0, 1));
    }

    /// Compare with a fraction of machine words, GMP's `_mpq_cmp_ui`.
    ///
    /// `gmp.h` also has an `mpq_cmp_ui` macro, but it is defined in terms of
    /// `__builtin_constant_p`, which has no translation; `_mpq_cmp_ui` is the
    /// function it dispatches to.
    pub fn cmpUi(self: *const Rational, top: c_ulong, bottom: c_ulong) std.math.Order {
        return cmpToOrder(c._mpq_cmp_ui(self.rawSrcPtr(), top, bottom));
    }

    pub fn isZero(self: *const Rational) bool {
        return self.cmpZero() == .eq;
    }

    pub fn isNegative(self: *const Rational) bool {
        return self.cmpZero() == .lt;
    }

    /// An owned copy of the numerator.
    pub fn numerator(self: *const Rational) BigInt {
        var result = BigInt.init();
        c.mpq_get_num(result.rawPtr(), self.rawSrcPtr());
        return result;
    }

    /// An owned copy of the denominator.
    pub fn denominator(self: *const Rational) BigInt {
        var result = BigInt.init();
        c.mpq_get_den(result.rawPtr(), self.rawSrcPtr());
        return result;
    }

    /// Truncating conversion to `f64`.
    pub fn getDouble(self: *const Rational) f64 {
        return c.mpq_get_d(self.rawSrcPtr());
    }

    /// Render into caller owned storage, as `num/den`, or as `num` alone when
    /// the denominator is 1.
    ///
    /// GMP writes the NUL terminated text straight into `buffer`; this wrapper
    /// allocates nothing and copies nothing. The returned slice is sentinel
    /// typed, so it can be fed straight back into `parse` or `setStr`, and it
    /// borrows `buffer`.
    ///
    /// Capacity: `buffer.len` must be at least
    /// `mpz_sizeinbase(mpq_numref(value), base)
    ///  + mpz_sizeinbase(mpq_denref(value), base) + 3`, which is the size the
    /// GMP manual states for `mpq_get_str` with a caller buffer
    /// (`doc/gmp.texi:4470-4476`). The three extra bytes are a possible minus
    /// sign, a possible slash and the terminating NUL. There is no
    /// `mpq_sizeinbase`: the manual derives the bound from the two parts, and
    /// so does `mpq/get_str.c:69-74`, which asserts the same inequality.
    ///
    /// Both `mpz_sizeinbase` calls may be one digit too large for a base that
    /// is not a power of two, so this is an upper bound and not a necessary
    /// condition: a buffer that happens to hold the text of a particular value
    /// can still be shorter and is then rejected with `error.BufferTooSmall`.
    ///
    /// `mpq_get_str` does not inspect a non null buffer, so this check is the
    /// only thing keeping the write in bounds. It happens before GMP is
    /// called, and a rejected buffer is left untouched.
    pub fn writeTo(self: *const Rational, buffer: []u8, base: u8) FormatError![:0]const u8 {
        if (!bases.validOutputBase(base)) return error.InvalidBase;

        // `mpq_numref` and `mpq_denref` are exactly `&Q->_mp_num` and
        // `&Q->_mp_den` (`gmp-h.in`); the fields are read directly, the way
        // `Float.sign` reads `_mp_size`, so no C macro has to survive
        // translation for the bound to be computed. `mpz_sizeinbase` takes a
        // `mpz_srcptr`, so `&self.raw[0]._mp_num` needs no cast from a
        // `*const Rational` either. It returns `size_t`, which `translate-c`
        // makes a `usize`, and the additions saturate, so a value too large
        // for the buffer is always too large rather than wrapping round to a
        // small number.
        const num_digits = c.mpz_sizeinbase(&self.raw[0]._mp_num, base);
        const den_digits = c.mpz_sizeinbase(&self.raw[0]._mp_den, base);
        const needed = num_digits +| den_digits +| 3;
        if (buffer.len < needed) return error.BufferTooSmall;

        // With a non null first argument `mpq_get_str` formats in place and
        // returns that same pointer. It returns null only for a base outside
        // its own range, which `validOutputBase` has already excluded.
        _ = c.mpq_get_str(buffer.ptr, base, self.rawSrcPtr());
        const terminated: [*:0]const u8 = @ptrCast(buffer.ptr);
        return buffer[0..std.mem.len(terminated) :0];
    }

    /// Render into a string allocated by GMP, released with `deinit`.
    ///
    /// The base range check is the only thing that can fail, exactly as on
    /// `BigInt.toOwnedString`; see `FormatError` for why an allocation failure
    /// is not a returnable condition in GMP.
    pub fn toOwnedString(self: *const Rational, base: u8) FormatError!OwnedString {
        if (!bases.validOutputBase(base)) return error.InvalidBase;
        // `gmp.h` declares a plain `char *` return, which `translate-c` spells
        // as the non optional `[*c]u8`. `mpq_get_str` returns null only for a
        // base outside its own range (`mpq/get_str.c:41-42`); its allocation
        // goes through the aborting default allocator, so a zero address is
        // not a value this call can produce, and there is nothing to unwrap.
        const raw: [*c]u8 = c.mpq_get_str(null, base, self.rawSrcPtr());
        // `mpq_get_str` shrinks its block to the exact text length plus the
        // NUL before returning (`mpq/get_str.c:76-77`), so that is the size
        // `deinit` must report.
        const terminated: [*:0]const u8 = @ptrCast(raw);
        return .{ .ptr = raw, .len = std.mem.len(terminated) };
    }
};
