//! Owned integers backed by GMP's `mpz_t`.
//!
//! The type is a thin, safe wrapper: it owns exactly one `mpz_t`, which GMP
//! allocates with its own allocator and releases with `mpz_clear`. Nothing here
//! installs allocator hooks, so memory always goes through GMP's
//! `gmp_allocate_func` / `gmp_free_func` pair, the same pair every other GMP
//! program uses. Those hooks are library-global rather than per value: a
//! program that replaces them through `c.__gmp_set_memory_functions` changes the
//! allocator for every value this facade owns, before and after the change.
//!
//! Conventions:
//!
//!   * `BigInt` is an owned value. `init` and `parse` produce one and `deinit`
//!     releases it, exactly once per value produced. Zig has no move: a copy
//!     made by assignment, by a struct field, or by returning the value into a
//!     second binding is a *second name for one GMP allocation*, so releasing
//!     both names is a double free. `clone` is not a move; it is GMP's own copy
//!     into a second, independently owned value.
//!   * A method that mirrors a three argument GMP function writes the result
//!     into the receiver: `result.mul(&a, &b)` is `mpz_mul(result, a, b)`.
//!   * A method ending in `Assign` updates the receiver in place.
//!   * Operands taken as `*const BigInt` are never modified by GMP. GMP's own
//!     prototypes say so: an operand is declared `mpz_srcptr` and only a
//!     result is declared `mpz_ptr`, which is what `rawSrcPtr` and `rawPtr`
//!     produce.
//!   * No method stores a pointer to the receiver, so a `BigInt` may live in a
//!     `var` that moves in memory; it does not need a stable address.

const std = @import("std");
const c = @import("c");
const memory = @import("memory.zig");
const bases = @import("base.zig");

/// How `div` rounds, mirroring GMP's three division rules.
pub const DivisionMode = enum {
    /// `mpz_tdiv_qr`: quotient rounds toward zero and the remainder takes the
    /// sign of the dividend.
    truncated,
    /// `mpz_fdiv_qr`: quotient rounds toward minus infinity and the remainder
    /// takes the sign of the divisor.
    floor,
    /// `mpz_cdiv_qr`: quotient rounds toward plus infinity and the remainder
    /// takes the sign of the divisor.
    ceiling,
};

/// Errors from parsing text into a value.
pub const ParseError = error{
    /// The text is not a valid number in the requested base: a digit outside
    /// the base, an empty string, a digit separator, a sign other than `-`, or
    /// trailing text. GMP refuses `1_000`, because `_` is neither a digit nor
    /// white space, and refuses a leading `+`, because the only sign it reads
    /// is `-`.
    ///
    /// White space is *not* one of these: `mpz_set_str` is documented in its
    /// own first line as allowing it, skips it before the sign
    /// (`mpz/set_str.c:67-68`) and among the leading zeros (`:102-104`), and
    /// drops every remaining white space character while converting the body
    /// (`:119-120`). So `" 12"`, `"12 "` and `"1 2"` all parse as `12`.
    InvalidDigit,
    /// The base is neither 0, which `mpz_set_str` reads as prefix detection,
    /// nor in the documented range 2..62. `mpz_set_str` rejects base 1 and a
    /// negative base outright; see `base.zig` for the two readings of a zero
    /// base.
    InvalidBase,
};

/// Errors from rendering a value into text.
///
/// There is no allocation error in this set, and that is the honest shape.
/// GMP's allocating entry points do not report a failed allocation: the
/// default allocator prints a message and aborts (`memory.c:53-58`), the
/// manual forbids `allocate_function` and `reallocate_function` from
/// returning `NULL` at all (`doc/gmp.texi:7487-7490`), and `mpz_get_str`
/// writes into the block it has just asked for without testing the result
/// (`mpz/get_str.c:71-78`). A program that installs an allocator returning
/// null gets a null dereference inside GMP, not an error to map, so an
/// `error.OutOfMemory` here would promise a recovery GMP cannot perform. The
/// null those rendering functions do return answers one question only, a
/// base outside 2..62 (`mpz/get_str.c:53-69`, `mpq/get_str.c:41-42`), and
/// that is rejected before either call.
pub const FormatError = error{
    /// The base is outside 2..62, the only range GMP's rendering functions and
    /// its digit count accept. Base 0 is a parsing convention; see `base.zig`.
    InvalidBase,
    /// `buffer` is shorter than the capacity `writeTo` publishes for this value
    /// and base. Nothing was written.
    BufferTooSmall,
};

/// Result of `div`: both parts are owned by the caller.
///
/// `quotient` and `remainder` are two independent `mpz_t` values, so `deinit`
/// releases both, once each. Copying the struct copies both names, not the
/// allocations.
pub const Division = struct {
    quotient: BigInt,
    remainder: BigInt,

    /// Release both parts. A second call is a double free on each of them.
    pub fn deinit(self: *Division) void {
        self.quotient.deinit();
        self.remainder.deinit();
    }
};

fn cmpToOrder(value: c_int) std.math.Order {
    return if (value == 0) .eq else if (value > 0) .gt else .lt;
}

pub const BigInt = struct {
    /// A NUL terminated string allocated by GMP, released with `deinit`.
    ///
    /// The block belongs to GMP's allocator, not to a Zig one, and
    /// `deinit` is the only release for it: `free` is the current
    /// `gmp_free_func` only by default, and `std.heap` was never given the
    /// block. `len` is the text length without the NUL. It is recorded rather
    /// than recomputed because GMP's `free_function` contract is about the size
    /// of the block, and for a string GMP allocated that block is exactly
    /// `len + 1` bytes.
    ///
    /// Zig has no move, so a copy made by assignment is a second name for one
    /// block and `deinit` on both names is a double free.
    pub const OwnedString = struct {
        ptr: [*c]u8,
        len: usize,

        /// The text without the terminating NUL, sentinel typed so it can be
        /// handed straight to `parse` or `setStr`. Borrowed from `self`, so it
        /// must not outlive it.
        pub fn slice(self: OwnedString) [:0]const u8 {
            return self.ptr[0..self.len :0];
        }

        /// Release the buffer through GMP's own free function, with the size
        /// GMP allocated it with: the text plus its NUL.
        ///
        /// Call it once. `ptr` is never null and `len + 1` is the block size
        /// GMP's contract expects (`doc/gmp.texi:7473-7478`), which a
        /// replaceable allocator may rely on even though the default `free`
        /// ignores it.
        pub fn deinit(self: OwnedString) void {
            memory.freeGmpMemory(self.ptr, self.len + 1);
        }
    };

    /// The GMP value itself.
    ///
    /// Exposed so the raw escape hatch (`gmp.c`) can be used on facade values.
    /// The field is reachable, so it is not read only by convention: a write
    /// through `c` changes this value and `deinit` still releases what GMP
    /// allocated for it.
    raw: c.mpz_t,

    /// The value as GMP's mutable C pointer, `mpz_ptr`.
    ///
    /// GMP writes through this, so it is only available on a mutable value.
    /// `gmp.h` declares it as `__mpz_struct *`, which `translate-c` renders as
    /// `[*c]struct___mpz_struct`. The pointer lives inside the receiver: it is
    /// valid until this value is released and does not survive a move, so a
    /// caller that keeps it across either has to re-ask.
    pub fn rawPtr(self: *BigInt) c.mpz_ptr {
        return &self.raw[0];
    }

    /// The value as GMP's read-only C pointer, `mpz_srcptr`.
    ///
    /// `gmp.h` declares every operand GMP only reads with this type
    /// (`const __mpz_struct *`), so a `*const BigInt` goes straight into the
    /// raw C API: GMP's prototypes are const correct, and no cast is needed to
    /// call them. Like `rawPtr`, it points inside the receiver and does not
    /// outlive it.
    pub fn rawSrcPtr(self: *const BigInt) c.mpz_srcptr {
        return &self.raw[0];
    }

    /// Allocate an initialised value equal to zero.
    pub fn init() BigInt {
        var self: BigInt = .{ .raw = undefined };
        c.mpz_init(self.rawPtr());
        return self;
    }

    /// Release the limbs GMP allocated for this value.
    ///
    /// The value is unusable afterwards and a second call is a double free.
    /// One `init` or `parse` is one `deinit`: a copy made by assignment is a
    /// second name for this same GMP value and must not be released.
    pub fn deinit(self: *BigInt) void {
        c.mpz_clear(self.rawPtr());
    }

    /// Parse `text` in `base`. Base 0 lets GMP auto detect the `0x`, `0X`,
    /// `0b` and leading `0` prefixes.
    ///
    /// `text` is a sentinel terminated string, which is what GMP reads: the
    /// pointer goes straight to `mpz_set_str`, with no copy and no allocation.
    /// A failed parse releases the half-built value, so an error leaves the
    /// caller nothing to release.
    pub fn parse(text: [:0]const u8, base: u8) ParseError!BigInt {
        var self = BigInt.init();
        errdefer self.deinit();
        try self.setStr(text, base);
        return self;
    }

    /// Parse `text`, returning null instead of an error. A `null` means the
    /// same thing `error.InvalidDigit` and `error.InvalidBase` do, and a
    /// non-null result owns a value the caller releases.
    pub fn parseOrNull(text: [:0]const u8, base: u8) ?BigInt {
        return parse(text, base) catch null;
    }

    /// Replace the value with the parsed `text`.
    ///
    /// `text` must be NUL terminated: `mpz_set_str` reads it as a C string and
    /// the pointer is passed through unchanged.
    ///
    /// On `error.InvalidBase` GMP is not called. On `error.InvalidDigit` the
    /// value is unchanged as well: each failure return in `mpz_set_str`
    /// (`mpz/set_str.c:62`, `:78`, `:126`) is on a path with no destination
    /// write. The write at `:108` is a separate all-zeros success path.
    pub fn setStr(self: *BigInt, text: [:0]const u8, base: u8) ParseError!void {
        if (!bases.validInputBase(base)) return error.InvalidBase;
        if (c.mpz_set_str(self.rawPtr(), text.ptr, base) < 0) return error.InvalidDigit;
    }

    /// Copy `other` into `self`, which is safe when they are the same value.
    pub fn set(self: *BigInt, other: *const BigInt) void {
        c.mpz_set(self.rawPtr(), other.rawSrcPtr());
    }

    /// Set the value from an unsigned machine word, GMP's `mpz_set_ui`.
    ///
    /// The word is the target's `unsigned long`: 64 bits on LP64, 32 bits on
    /// LLP64 and 32-bit targets. For a wider value, parse it or use the raw
    /// translated C.
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

    /// An independent copy of the value: a second GMP allocation with its own
    /// limbs and its own `deinit`. Assigning the result elsewhere copies that
    /// second name, not a further value.
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

    /// `self /= other`, truncated toward zero (`mpz_tdiv_q`).
    ///
    /// Use `div(.., .floor)` or `div(.., .ceiling)` when the rounding direction
    /// matters for negative operands. `other` must not be zero.
    pub fn divAssign(self: *BigInt, other: *const BigInt) void {
        c.mpz_tdiv_q(self.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr());
    }

    /// Exact division, `mpz_divexact`. `other` must divide `self` exactly and
    /// must not be zero; GMP's behaviour is undefined otherwise. The quotient
    /// is a new value the caller owns and releases with its own `deinit`.
    pub fn divexact(self: *const BigInt, other: *const BigInt) BigInt {
        var quotient = BigInt.init();
        c.mpz_divexact(quotient.rawPtr(), self.rawSrcPtr(), other.rawSrcPtr());
        return quotient;
    }

    /// Divide with an explicit rounding rule. `other` must not be zero.
    ///
    /// The three modes are GMP's `mpz_tdiv_qr`, `mpz_fdiv_qr` and
    /// `mpz_cdiv_qr`; they differ exactly for negative operands. Both results
    /// are new values, owned by the returned `Division`.
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

    /// `n mod d`, `mpz_mod`. `other` must not be zero.  The sign of the divisor
    /// is ignored and the result is never negative (doc/gmp.texi:3464-3465),
    /// so this is the floor-rule remainder, not the truncated one `div` gives.
    /// The remainder is a new value the caller owns and releases with its own
    /// `deinit`.
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

    /// Miller-Rabin plus Lucas primality test with `reps` rounds.
    ///
    /// Returns 2 when definitely prime, 1 when probably prime and 0 when
    /// composite. `reps` is a C `int`, because GMP declares it that way.
    pub fn probabPrime(self: *const BigInt, reps: c_int) u32 {
        const result = c.mpz_probab_prime_p(self.rawSrcPtr(), reps);
        return if (result < 0) 0 else @intCast(result);
    }

    /// `self *= 2^n`.
    pub fn shlAssign(self: *BigInt, n: c.mp_bitcnt_t) void {
        c.mpz_mul_2exp(self.rawPtr(), self.rawSrcPtr(), n);
    }

    /// `self /= 2^n`, rounding toward minus infinity (`mpz_fdiv_q_2exp`).
    ///
    /// For a negative value this rounds down, unlike a C style shift.
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
    /// `self = value^-1 mod modulus`, GMP's `mpz_invert`.
    ///
    /// Returns false and leaves `self` unchanged when the inverse does not
    /// exist, that is when `value` and `modulus` are not coprime.
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

    /// `self /= operand`, truncated toward zero. `operand` must not be zero.
    ///
    /// `mpz_tdiv_q_ui` is declared as returning `unsigned long`
    /// (`gmp-h.in:1090`) and does return one (`mpz/tdiv_q_ui.c:82`), but the
    /// value is the remainder that `mpn_divrem_1` computed
    /// (`mpz/tdiv_q_ui.c:77`), not the quotient, which lands in `self`. This
    /// wrapper names the operation it actually performs and discards the
    /// remainder; a caller who wants it should call `mpz_tdiv_r_ui` through
    /// the raw escape hatch rather than read it out of this return value.
    pub fn divUi(self: *BigInt, operand: c_ulong) void {
        _ = c.mpz_tdiv_q_ui(self.rawPtr(), self.rawSrcPtr(), operand);
    }

    /// `self = base^exponent` with machine words, GMP's `mpz_ui_pow_ui`.
    ///
    /// Both arguments are C words: GMP's function takes `unsigned long` for
    /// the exponent, not an integer. `self = self^n` is `powAssign`.
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

    /// Compare with a machine word.
    ///
    /// `_mpz_cmp_ui` is the function `gmp.h` declares; `mpz_cmp_ui` is only a
    /// macro over it, and macros over `__builtin_constant_p` do not survive
    /// translation.
    pub fn cmpUi(self: *const BigInt, operand: c_ulong) std.math.Order {
        return cmpToOrder(c._mpz_cmp_ui(self.rawSrcPtr(), operand));
    }

    /// -1, 0 or 1.
    ///
    /// GMP 6.3.0 has no `mpz_sgn` function: `gmp-h.in:2252` defines it as the
    /// macro `((Z)->_mp_size < 0 ? -1 : (Z)->_mp_size > 0)`, which has no
    /// translation, and there is no `mpz/sgn.c`. This reads the same documented
    /// `_mp_size` field directly, the way `Float.sign` does, so no C macro has
    /// to survive.
    pub fn sign(self: *const BigInt) i32 {
        if (self.raw[0]._mp_size == 0) return 0;
        return if (self.raw[0]._mp_size < 0) -1 else 1;
    }

    /// Whether the value is zero, `_mp_size == 0`.
    ///
    /// GMP 6.3 has no `mpz_sgn` function: `gmp-h.in:2252` defines it as the
    /// macro `((Z)->_mp_size < 0 ? -1 : (Z)->_mp_size > 0)`, which has no
    /// translation, and there is no `mpz/sgn.c`, so this reads the documented
    /// field directly, the way `sign` does. What it reads is GMP's own size:
    /// `mpz_size` is that field's absolute value (`gmp-h.in:1879-1883`), and
    /// the manual states a zero size for a zero value
    /// (`doc/gmp.texi:4247-4249`). So this is GMP's own test, and exactly one
    /// of `isZero`, `isNegative` and `isPositive` is true of any value.
    pub fn isZero(self: *const BigInt) bool {
        return self.raw[0]._mp_size == 0;
    }

    /// Whether the value is negative, `_mp_size < 0`: the negative half of the
    /// same `mpz_sgn` macro `isZero` describes. A value of zero is not
    /// negative, and there is no negative zero to be: the sign lives in the
    /// size and a size of zero carries none.
    pub fn isNegative(self: *const BigInt) bool {
        return self.raw[0]._mp_size < 0;
    }

    /// Whether the value is positive, `_mp_size > 0`: the positive half of the
    /// same `mpz_sgn` macro `isZero` describes. A value of zero is not
    /// positive.
    pub fn isPositive(self: *const BigInt) bool {
        return self.raw[0]._mp_size > 0;
    }

    /// Whether the value is odd.
    ///
    /// `mpz_odd_p` and `mpz_even_p` are macros that read the low limb
    /// directly, so this asks GMP for the same bit through the declared
    /// `mpz_tstbit`; bit 0 of GMP's two's complement representation is exactly
    /// parity, and `mpz/tstbit.c` handles negative values for it.
    pub fn isOdd(self: *const BigInt) bool {
        return c.mpz_tstbit(self.rawSrcPtr(), 0) != 0;
    }

    /// Whether the value is even, GMP's `mpz_even_p`.
    ///
    /// The exact complement of `isOdd`, and for the reason `isOdd` gives:
    /// `gmp-h.in:2286` defines `mpz_even_p(z)` as `(! mpz_odd_p (z))`, and
    /// `mpz_tstbit` answers with 0 or 1 and nothing else (`mpz/tstbit.c:79`),
    /// so the two ask the same question of the same call and cannot disagree.
    /// Zero is even, and so is a negative even value: for a negative operand
    /// `mpz_tstbit` builds the two's complement of the limb it is about to test
    /// before it tests bit 0 (`mpz/tstbit.c:64-77`), which is why this answers
    /// for a negative value at all.
    pub fn isEven(self: *const BigInt) bool {
        return c.mpz_tstbit(self.rawSrcPtr(), 0) == 0;
    }

    /// Number of bits in the absolute value, exact because base 2 is a power
    /// of two. Zero has one bit, matching GMP.
    pub fn bitLength(self: *const BigInt) usize {
        return c.mpz_sizeinbase(self.rawSrcPtr(), 2);
    }

    /// Number of set bits, GMP's `mpz_popcount`. For a negative value GMP
    /// returns the maximum bit count, because a two's complement negative
    /// number has no bounded population.
    pub fn popCount(self: *const BigInt) u64 {
        return @intCast(c.mpz_popcount(self.rawSrcPtr()));
    }

    /// Number of trailing zero bits in the absolute value. GMP returns the
    /// maximum bit count for zero, which has no lowest set bit.
    pub fn countTrailingZeroBits(self: *const BigInt) u64 {
        return @intCast(c.mpz_scan1(self.rawSrcPtr(), 0));
    }

    /// Digit count in `base`, GMP's `mpz_sizeinbase`.
    ///
    /// Exact for a base that is a power of two; for any other base the result
    /// is either exact or one digit too large, because GMP derives it from the
    /// bit length. Base 0 and base 1 are rejected with `error.InvalidBase`:
    /// `mpz_sizeinbase` documents 2 to 62 and asserts that range internally.
    pub fn sizeinbase(self: *const BigInt, base: u8) FormatError!u64 {
        if (!bases.validOutputBase(base)) return error.InvalidBase;
        return @intCast(c.mpz_sizeinbase(self.rawSrcPtr(), base));
    }

    /// Whether the value fits in an unsigned machine word, GMP's
    /// `mpz_fits_ulong_p`. The word is 32 bits wide on LLP64 and 32-bit
    /// targets.
    pub fn fitsUnsignedWord(self: *const BigInt) bool {
        return self.sign() >= 0 and c.mpz_fits_ulong_p(self.rawSrcPtr()) != 0;
    }

    /// Whether the value fits in a signed machine word, GMP's
    /// `mpz_fits_slong_p`.
    pub fn fitsSignedWord(self: *const BigInt) bool {
        return c.mpz_fits_slong_p(self.rawSrcPtr()) != 0;
    }

    /// The value as an unsigned machine word, as GMP's `mpz_get_ui` does.
    /// Negative values yield their absolute value.
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

    /// Render into caller owned storage.
    ///
    /// GMP writes the NUL terminated text straight into `buffer`; this wrapper
    /// allocates nothing and copies nothing. The returned slice is the text
    /// without the NUL, sentinel typed so it can be fed straight back into
    /// `parse` or `setStr`. It borrows `buffer` and is invalidated when the
    /// caller writes `buffer` again or lets it out of scope.
    ///
    /// Capacity: `buffer.len` must be at least
    /// `mpz_sizeinbase(value, base) + 2`. Those two bytes are what the GMP
    /// manual adds to the digit count: a possible minus sign and the
    /// terminating NUL. Because `mpz_sizeinbase` may itself be one digit too
    /// large for a base that is not a power of two, the bound is an upper
    /// bound and not a necessary condition: a buffer that happens to hold the
    /// text of a particular value can still be shorter and is then rejected
    /// with `error.BufferTooSmall`. Size the buffer with `sizeinbase` plus two,
    /// or use `toOwnedString` and skip the arithmetic.
    ///
    /// `mpz_get_str` never looks at a non null buffer, so this check is the
    /// only thing keeping the write in bounds. It happens before GMP is
    /// called, and a rejected buffer is left untouched.
    pub fn writeTo(self: *const BigInt, buffer: []u8, base: u8) FormatError![:0]const u8 {
        if (!bases.validOutputBase(base)) return error.InvalidBase;

        // A digit count that does not fit this target's `usize` cannot be
        // rendered into a `usize` sized buffer either, so saturating is the
        // honest reading: such a value is always too big for the buffer.
        const digits = try self.sizeinbase(base);
        const needed = (std.math.cast(usize, digits) orelse std.math.maxInt(usize)) +| 2;
        if (buffer.len < needed) return error.BufferTooSmall;

        // With a non null first argument `mpz_get_str` formats in place and
        // returns that same pointer, and for a base in 2..62 it cannot return
        // null at all, which is what the range check above guarantees.
        _ = c.mpz_get_str(buffer.ptr, base, self.rawSrcPtr());
        const terminated: [*:0]const u8 = @ptrCast(buffer.ptr);
        return buffer[0..std.mem.len(terminated) :0];
    }

    /// Render into a string allocated by GMP, released with `deinit`.
    ///
    /// The allocating counterpart of `writeTo`, for text that must outlive the
    /// caller's buffer. The base range is the same 2..62, and that range check
    /// is the only thing that can fail: see `FormatError` for why an
    /// allocation failure is not one of them.
    pub fn toOwnedString(self: *const BigInt, base: u8) FormatError!OwnedString {
        if (!bases.validOutputBase(base)) return error.InvalidBase;
        // `gmp.h` declares a plain `char *` return, which `translate-c` spells
        // as the non optional `[*c]u8`: nothing in the prototype marks it
        // nullable. A zero address stays a C pointer value inside that type,
        // so there is no `null` to unwrap and nothing to test.
        const raw: [*c]u8 = c.mpz_get_str(null, base, self.rawSrcPtr());
        // `mpz_get_str` shrinks its block to the exact text length plus the
        // NUL before returning (`mpz/get_str.c:106-113`), so that is the size
        // `deinit` must report.
        const terminated: [*:0]const u8 = @ptrCast(raw);
        return .{ .ptr = raw, .len = std.mem.len(terminated) };
    }
};
