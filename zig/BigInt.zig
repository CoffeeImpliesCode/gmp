//! Owned GMP integer with explicit initialization and cleanup.

const std = @import("std");
const c = @import("c");
const memory = @import("memory.zig");
const bases = @import("base.zig");

/// How `div` rounds, mirroring GMP's three division rules.
pub const DivisionMode = enum {
    /// Quotient toward zero; remainder follows the dividend.
    truncated,
    /// Quotient toward minus infinity; remainder follows the divisor.
    floor,
    /// Quotient toward plus infinity; remainder follows the divisor.
    ceiling,
};

/// Errors from parsing text into a value.
pub const ParseError = error{
    /// Invalid digit or syntax; GMP accepts whitespace but rejects `+` and `_`.
    InvalidDigit,
    /// The base is not 0 or in the range 2..62.
    InvalidBase,
};

/// Errors from formatting; GMP allocation failures are not recoverable.
pub const FormatError = error{
    /// Base is outside the output range 2..62.
    InvalidBase,
    /// The buffer is too short; no bytes were written.
    BufferTooSmall,
};

/// Owned quotient and remainder returned by `div`.
pub const Division = struct {
    quotient: BigInt,
    remainder: BigInt,

    /// Release both owned values.
    pub fn deinit(self: *Division) void {
        self.quotient.deinit();
        self.remainder.deinit();
    }
};

fn cmpToOrder(value: c_int) std.math.Order {
    return if (value == 0) .eq else if (value > 0) .gt else .lt;
}

pub const BigInt = struct {
    /// GMP-allocated NUL-terminated text; `len` excludes NUL and `deinit` releases it.
    pub const OwnedString = struct {
        ptr: [*c]u8,
        len: usize,

        /// Borrowed sentinel slice; it must not outlive this value.
        pub fn slice(self: OwnedString) [:0]const u8 {
            return self.ptr[0..self.len :0];
        }

        /// Release through GMP's current free hook with `len + 1` bytes; call once.
        pub fn deinit(self: OwnedString) void {
            memory.freeGmpMemory(self.ptr, self.len + 1);
        }
    };

    /// The underlying GMP value, exposed for raw C access.
    raw: c.mpz_t,

    /// Mutable GMP pointer borrowed from this value; it does not survive release or move.
    pub fn rawPtr(self: *BigInt) c.mpz_ptr {
        return &self.raw[0];
    }

    /// Read-only GMP pointer borrowed from this value; it does not survive release or move.
    pub fn rawSrcPtr(self: *const BigInt) c.mpz_srcptr {
        return &self.raw[0];
    }

    /// Allocate an initialised value equal to zero.
    pub fn init() BigInt {
        var self: BigInt = .{ .raw = undefined };
        c.mpz_init(self.rawPtr());
        return self;
    }

    /// Release the GMP allocation; call once and do not use the value afterwards.
    pub fn deinit(self: *BigInt) void {
        c.mpz_clear(self.rawPtr());
    }

    /// Parse NUL-terminated text; base 0 enables GMP's prefix detection.
    /// Returns an owned value; parse errors release any partial value.
    pub fn parse(text: [:0]const u8, base: u8) ParseError!BigInt {
        var self = BigInt.init();
        errdefer self.deinit();
        try self.setStr(text, base);
        return self;
    }

    /// Parse text, returning null on an invalid base or digit; a value is caller-owned.
    pub fn parseOrNull(text: [:0]const u8, base: u8) ?BigInt {
        return parse(text, base) catch null;
    }

    /// Parse NUL-terminated text into `self`; parse errors leave it unchanged.
    pub fn setStr(self: *BigInt, text: [:0]const u8, base: u8) ParseError!void {
        if (!bases.validInputBase(base)) return error.InvalidBase;
        if (c.mpz_set_str(self.rawPtr(), text.ptr, base) < 0) return error.InvalidDigit;
    }

    /// Copy `other` into `self`, which is safe when they are the same value.
    pub fn set(self: *BigInt, other: *const BigInt) void {
        c.mpz_set(self.rawPtr(), other.rawSrcPtr());
    }

    /// Set from a target-width `unsigned long`.
    pub fn setUnsignedWord(self: *BigInt, value: c_ulong) void {
        c.mpz_set_ui(self.rawPtr(), value);
    }

    /// Set the value from a signed machine word, GMP's `mpz_set_si`.
    pub fn setSignedWord(self: *BigInt, value: c_long) void {
        c.mpz_set_si(self.rawPtr(), value);
    }

    /// Set the value from a `double`, truncating toward zero.
    pub fn setDouble(self: *BigInt, value: f64) void {
        c.mpz_set_d(self.rawPtr(), value);
    }

    /// Return an independent GMP allocation that the caller releases with `deinit`.
    pub fn clone(self: *const BigInt) BigInt {
        var copy = BigInt.init();
        copy.set(self);
        return copy;
    }

    /// Exchange the values of `self` and `other`.
    pub fn swap(self: *BigInt, other: *BigInt) void {
        c.mpz_swap(self.rawPtr(), other.rawPtr());
    }

    /// `self = a + b`.
    pub fn add(self: *BigInt, a: *const BigInt, b: *const BigInt) void {
        c.mpz_add(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self = a - b`.
    pub fn sub(self: *BigInt, a: *const BigInt, b: *const BigInt) void {
        c.mpz_sub(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self = a * b`.
    pub fn mul(self: *BigInt, a: *const BigInt, b: *const BigInt) void {
        c.mpz_mul(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self += other`.
    pub fn addAssign(self: *BigInt, other: *const BigInt) void {
        c.mpz_add(self.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr());
    }

    /// `self -= other`.
    pub fn subAssign(self: *BigInt, other: *const BigInt) void {
        c.mpz_sub(self.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr());
    }

    /// `self *= other`.
    pub fn mulAssign(self: *BigInt, other: *const BigInt) void {
        c.mpz_mul(self.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr());
    }

    /// Divide toward zero; `other` must not be zero.
    pub fn divAssign(self: *BigInt, other: *const BigInt) void {
        c.mpz_tdiv_q(self.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr());
    }

    /// Return an owned exact quotient; `other` must be nonzero and divide `self`.
    pub fn divexact(self: *const BigInt, other: *const BigInt) BigInt {
        var quotient = BigInt.init();
        c.mpz_divexact(quotient.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr());
        return quotient;
    }

    /// Divide with the selected rounding rule; `other` must be nonzero.
    /// The returned quotient and remainder are owned by the caller.
    pub fn div(self: *const BigInt, other: *const BigInt, mode: DivisionMode) Division {
        var quotient = BigInt.init();
        var remainder = BigInt.init();
        switch (mode) {
            .truncated => c.mpz_tdiv_qr(quotient.rawPtr(), remainder.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr()),
            .floor => c.mpz_fdiv_qr(quotient.rawPtr(), remainder.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr()),
            .ceiling => c.mpz_cdiv_qr(quotient.rawPtr(), remainder.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr()),
        }
        return .{ .quotient = quotient, .remainder = remainder };
    }

    /// Return GMP's nonnegative remainder; `other` must not be zero.
    pub fn mod(self: *const BigInt, other: *const BigInt) BigInt {
        var remainder = BigInt.init();
        c.mpz_mod(remainder.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr());
        return remainder;
    }

    /// `self = gcd(a, b)`, always non negative.
    pub fn gcd(self: *BigInt, a: *const BigInt, b: *const BigInt) void {
        c.mpz_gcd(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self = gcd(self, other)`.
    pub fn gcdAssign(self: *BigInt, other: *const BigInt) void {
        c.mpz_gcd(self.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr());
    }

    /// `self = lcm(a, b)`, always non negative.
    pub fn lcm(self: *BigInt, a: *const BigInt, b: *const BigInt) void {
        c.mpz_lcm(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// Extended gcd: `self = gcd(a, b)` with `a * s + b * t = self`.
    pub fn gcdext(self: *BigInt, a: *const BigInt, b: *const BigInt, s: *BigInt, t: *BigInt) void {
        c.mpz_gcdext(self.rawPtr(), s.rawPtr(), t.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// `self = base^exponent mod modulus`. `modulus` must not be zero.
    pub fn powm(self: *BigInt, base: *const BigInt, exponent: *const BigInt, modulus: *const BigInt) void {
        c.mpz_powm(self.rawPtr(), base.rawSrcPtr(), exponent.rawSrcPtr(), modulus.rawSrcPtr());
    }

    /// `self = self^exponent`.
    pub fn powAssign(self: *BigInt, exponent: c_ulong) void {
        c.mpz_pow_ui(self.rawPtr(), self.rawSrcPtr(), exponent);
    }

    /// `self = binom(n, k)`.
    pub fn binUiUi(self: *BigInt, n: c_ulong, k: c_ulong) void {
        c.mpz_bin_uiui(self.rawPtr(), n, k);
    }

    /// `self = n!`.
    pub fn facUi(self: *BigInt, n: c_ulong) void {
        c.mpz_fac_ui(self.rawPtr(), n);
    }

    /// `self = fib(n)`, the `n`th Fibonacci number with `fib(0) = 0`.
    pub fn fibUi(self: *BigInt, n: c_ulong) void {
        c.mpz_fib_ui(self.rawPtr(), n);
    }

    /// 0 means composite, 1 probable prime, and 2 definite prime.
    pub fn probabPrime(self: *const BigInt, reps: c_int) u32 {
        const result = c.mpz_probab_prime_p(self.rawSrcPtr(), reps);
        return if (result < 0) 0 else @intCast(result);
    }

    /// `self *= 2^n`.
    pub fn shlAssign(self: *BigInt, n: c.mp_bitcnt_t) void {
        c.mpz_mul_2exp(self.rawPtr(), self.rawSrcPtr(), n);
    }

    /// Divide by `2^n` toward minus infinity, including for negative values.
    pub fn shrAssign(self: *BigInt, n: c.mp_bitcnt_t) void {
        c.mpz_fdiv_q_2exp(self.rawPtr(), self.rawSrcPtr(), n);
    }

    /// `self = -self`.
    pub fn negAssign(self: *BigInt) void {
        c.mpz_neg(self.rawPtr(), self.rawSrcPtr());
    }

    /// `self = |self|`.
    pub fn absAssign(self: *BigInt) void {
        c.mpz_abs(self.rawPtr(), self.rawSrcPtr());
    }

    /// `self = -self - 1`, GMP's `mpz_com`.
    pub fn comAssign(self: *BigInt) void {
        c.mpz_com(self.rawPtr(), self.rawSrcPtr());
    }
    /// Set the modular inverse; return false without changing `self` if none exists.
    pub fn invert(self: *BigInt, value: *const BigInt, modulus: *const BigInt) bool {
        var inverse = BigInt.init();
        defer inverse.deinit();
        if (c.mpz_invert(inverse.rawPtr(), value.rawSrcPtr(), modulus.rawSrcPtr()) == 0) return false;
        self.swap(&inverse);
        return true;
    }

    /// `self += operand`.
    pub fn addUi(self: *BigInt, operand: c_ulong) void {
        c.mpz_add_ui(self.rawPtr(), self.rawSrcPtr(), operand);
    }

    /// `self -= operand`.
    pub fn subUi(self: *BigInt, operand: c_ulong) void {
        c.mpz_sub_ui(self.rawPtr(), self.rawSrcPtr(), operand);
    }

    /// `self = operand - self`.
    pub fn subUiRev(self: *BigInt, operand: c_ulong) void {
        c.mpz_ui_sub(self.rawPtr(), operand, self.rawSrcPtr());
    }

    /// `self *= operand`.
    pub fn mulUi(self: *BigInt, operand: c_ulong) void {
        c.mpz_mul_ui(self.rawPtr(), self.rawSrcPtr(), operand);
    }

    /// Divide toward zero by a nonzero word; discard GMP's returned remainder.
    pub fn divUi(self: *BigInt, operand: c_ulong) void {
        _ = c.mpz_tdiv_q_ui(self.rawPtr(), self.rawSrcPtr(), operand);
    }

    /// Set `self` to `base^exponent` using target-width unsigned words.
    pub fn powUi(self: *BigInt, base: c_ulong, exponent: c_ulong) void {
        c.mpz_ui_pow_ui(self.rawPtr(), base, exponent);
    }

    /// `self *= 2^n`.
    pub fn mul2Exp(self: *BigInt, n: c.mp_bitcnt_t) void {
        c.mpz_mul_2exp(self.rawPtr(), self.rawSrcPtr(), n);
    }

    /// Set bit `n`.
    pub fn setBit(self: *BigInt, n: c.mp_bitcnt_t) void {
        c.mpz_setbit(self.rawPtr(), n);
    }

    /// Clear bit `n`.
    pub fn clearBit(self: *BigInt, n: c.mp_bitcnt_t) void {
        c.mpz_clrbit(self.rawPtr(), n);
    }

    /// Read bit `n`.
    pub fn testBit(self: *const BigInt, n: c.mp_bitcnt_t) bool {
        return c.mpz_tstbit(self.rawSrcPtr(), n) != 0;
    }

    /// Bitwise and.
    pub fn bitAnd(self: *BigInt, a: *const BigInt, b: *const BigInt) void {
        c.mpz_and(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// Bitwise or.
    pub fn bitOr(self: *BigInt, a: *const BigInt, b: *const BigInt) void {
        c.mpz_ior(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// Bitwise exclusive or.
    pub fn bitXor(self: *BigInt, a: *const BigInt, b: *const BigInt) void {
        c.mpz_xor(self.rawPtr(), a.rawSrcPtr(), b.rawSrcPtr());
    }

    /// Compare by value.
    pub fn cmp(self: *const BigInt, other: *const BigInt) std.math.Order {
        return cmpToOrder(c.mpz_cmp(self.rawSrcPtr(), other.rawSrcPtr()));
    }

    /// Compare by absolute value.
    pub fn cmpAbs(self: *const BigInt, other: *const BigInt) std.math.Order {
        return cmpToOrder(c.mpz_cmpabs(self.rawSrcPtr(), other.rawSrcPtr()));
    }

    /// Compare to a word through GMP's declared `_mpz_cmp_ui` function.
    pub fn cmpUi(self: *const BigInt, operand: c_ulong) std.math.Order {
        return cmpToOrder(c._mpz_cmp_ui(self.rawSrcPtr(), operand));
    }

    /// Return -1, 0, or 1 from GMP's `_mp_size` sign field.
    pub fn sign(self: *const BigInt) i32 {
        if (self.raw[0]._mp_size == 0) return 0;
        return if (self.raw[0]._mp_size < 0) -1 else 1;
    }

    /// Test zero through GMP's `_mp_size` field.
    pub fn isZero(self: *const BigInt) bool {
        return self.raw[0]._mp_size == 0;
    }

    /// Test whether GMP's `_mp_size` field is negative.
    pub fn isNegative(self: *const BigInt) bool {
        return self.raw[0]._mp_size < 0;
    }

    /// Test whether GMP's `_mp_size` field is positive.
    pub fn isPositive(self: *const BigInt) bool {
        return self.raw[0]._mp_size > 0;
    }

    /// Test parity through GMP's `mpz_tstbit`, including for negative values.
    pub fn isOdd(self: *const BigInt) bool {
        return c.mpz_tstbit(self.rawSrcPtr(), 0) != 0;
    }

    /// Test parity through GMP's `mpz_tstbit`; zero is even.
    pub fn isEven(self: *const BigInt) bool {
        return c.mpz_tstbit(self.rawSrcPtr(), 0) == 0;
    }

    /// Return the exact bit length; zero has length one.
    pub fn bitLength(self: *const BigInt) usize {
        return c.mpz_sizeinbase(self.rawSrcPtr(), 2);
    }

    /// Return the population count; GMP returns the maximum count for negatives.
    pub fn popCount(self: *const BigInt) u64 {
        return @intCast(c.mpz_popcount(self.rawSrcPtr()));
    }

    /// Return trailing zero bits; GMP returns the maximum count for zero.
    pub fn countTrailingZeroBits(self: *const BigInt) u64 {
        return @intCast(c.mpz_scan1(self.rawSrcPtr(), 0));
    }

    /// Return the digit count; non-power-of-two bases may be one too large.
    /// Reject bases outside 2..62 with `error.InvalidBase`.
    pub fn sizeinbase(self: *const BigInt, base: u8) FormatError!u64 {
        if (!bases.validOutputBase(base)) return error.InvalidBase;
        return @intCast(c.mpz_sizeinbase(self.rawSrcPtr(), base));
    }

    /// Test fit in target-width `unsigned long`.
    pub fn fitsUnsignedWord(self: *const BigInt) bool {
        return self.sign() >= 0 and c.mpz_fits_ulong_p(self.rawSrcPtr()) != 0;
    }

    /// Test fit in target-width `long`.
    pub fn fitsSignedWord(self: *const BigInt) bool {
        return c.mpz_fits_slong_p(self.rawSrcPtr()) != 0;
    }

    /// Return GMP's unsigned-word conversion; negative values yield their magnitude.
    pub fn toUnsignedWord(self: *const BigInt) c_ulong {
        return c.mpz_get_ui(self.rawSrcPtr());
    }

    /// The value as a signed machine word, as GMP's `mpz_get_si` does.
    pub fn toSignedWord(self: *const BigInt) c_long {
        return c.mpz_get_si(self.rawSrcPtr());
    }

    /// Truncating conversion to `f64`, which loses precision above 2^53.
    pub fn getDouble(self: *const BigInt) f64 {
        return c.mpz_get_d(self.rawSrcPtr());
    }

    /// Format into caller storage without allocation; the sentinel slice borrows `buffer`.
    /// Requires `sizeinbase + 2` bytes (an upper bound); short buffers stay untouched.
    pub fn writeTo(self: *const BigInt, buffer: []u8, base: u8) FormatError![:0]const u8 {
        if (!bases.validOutputBase(base)) return error.InvalidBase;

        // Saturate when the digit count cannot fit in a `usize`-sized buffer.
        const digits = try self.sizeinbase(base);
        const needed = (std.math.cast(usize, digits) orelse std.math.maxInt(usize)) +| 2;
        if (buffer.len < needed) return error.BufferTooSmall;

        // A non-null buffer and valid base make this in-place GMP result non-null.
        _ = c.mpz_get_str(buffer.ptr, base, self.rawSrcPtr());
        const terminated: [*:0]const u8 = @ptrCast(buffer.ptr);
        return buffer[0..std.mem.len(terminated) :0];
    }

    /// Allocate text through GMP; the caller releases it with `deinit`.
    /// Invalid bases are rejected; GMP allocation failures do not return.
    pub fn toOwnedString(self: *const BigInt, base: u8) FormatError!OwnedString {
        if (!bases.validOutputBase(base)) return error.InvalidBase;
        // GMP's allocator contract makes this allocated C pointer non-null.
        const raw: [*c]u8 = c.mpz_get_str(null, base, self.rawSrcPtr());
        // GMP shrinks the block to the text length plus its NUL.
        const terminated: [*:0]const u8 = @ptrCast(raw);
        return .{ .ptr = raw, .len = std.mem.len(terminated) };
    }
};
