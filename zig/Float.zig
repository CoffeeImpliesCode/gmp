//! Owned floating point numbers backed by GMP's `mpf_t`.
//!
//! An `mpf` value is a binary float whose precision is chosen at `init` and
//! kept for later operations. Three properties of that precision are what a
//! caller has to plan around, and none of them is IEEE 754:
//!
//!   * The precision is a *minimum*. `init` asks GMP for at least
//!     `precision_bits`, GMP keeps whole limbs and rounds the request up
//!     (`doc/gmp.texi:4762-4765`), so `getPrecision` can report more bits than
//!     were asked for.
//!   * Results are **truncated** to the destination's precision, never rounded
//!     to nearest. The manual says so outright: GMP sometimes computes
//!     internally at higher precision, but "final results are always truncated
//!     to the destination variable's precision" (`doc/gmp.texi:4700-4702`), and
//!     `mpf_set_prec` truncates the value it keeps (`doc/gmp.texi:4807-4809`).
//!     `set`, `setDouble`, `setPrecision` and the arithmetic methods here all
//!     reach that behaviour through those C functions.
//!   * `mpf` has no infinity and no NaN, and an exponent that outruns the type
//!     gives an unpredictable result (`doc/gmp.texi:4711-4713`). The manual
//!     adds that the `mpf` functions are not a smooth extension of IEEE 754
//!     arithmetic (`doc/gmp.texi:4715-4718`), and `getDouble` truncates toward
//!     zero rather than rounding to nearest (`doc/gmp.texi:4944-4946`).
//!
//! The other place the C contract differs from what the name suggests is
//! parsing: base 0 reaches `mpf_set_str` as base 10, not as the prefix
//! detection `mpz_set_str` and `mpq_set_str` do (`mpf/set_str.c:153-155`,
//! `doc/gmp.texi:4877-4879`). See `base.zig` for both readings and for the
//! negative base a `u8` cannot express.
//!
//! Every signature used here was checked against the `gmp-h.in` shipped in this
//! tree. Two consequences are worth knowing:
//!
//!   * `mpf_set_str` takes three arguments in GMP 6.3, there is no digit count.
//!   * GMP 6.3 has neither `mpf_const_pi` nor `mpf_set_inf`, so the facade has
//!     no constant for pi; MPFR is the package that provides one. Use
//!     `setStr` with a literal or compute the value.
//!
//! A `Float` owns one `mpf_t`: `init` produces it and `deinit` releases it,
//! once per `init`. Zig has no move, so a copy made by assignment is a second
//! name for that one GMP value and releasing both is a double free; `parse` is
//! the only way this type produces a second value, and it has its own
//! allocation. Nothing needs a stable address, because no method stores a
//! pointer to the receiver.

const std = @import("std");
const c = @import("c");
const bases = @import("base.zig");

/// Errors from parsing text into a value.
pub const ParseError = error{
    /// `mpf_set_str` rejected the text.
    InvalidFormat,
    /// The base is outside 0 and 2..62, the range the facade accepts for a
    /// parser. Zero reaches `mpf_set_str` as base 10, not as prefix detection,
    /// and a negative base, which `mpf_set_str` does accept, cannot be written
    /// in a `u8`; see `base.zig`.
    InvalidBase,
};

/// Errors from rendering a value into text.
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
    ///
    /// The field is reachable, so it is not read only by convention: a write
    /// through `c` changes this value and `deinit` still releases what GMP
    /// allocated for it.
    raw: c.mpf_t,

    /// The value as GMP's mutable C pointer, `mpf_ptr`. GMP writes through
    /// this, so it is only available on a mutable value. The pointer lives
    /// inside the receiver: it does not outlive this value and does not survive
    /// a move.
    pub fn rawPtr(self: *Float) c.mpf_ptr {
        return &self.raw[0];
    }

    /// The value as GMP's read-only C pointer, `mpf_srcptr`, which is what
    /// `gmp.h` declares its operands with. Like `rawPtr`, it points inside the
    /// receiver and does not outlive it.
    pub fn rawSrcPtr(self: *const Float) c.mpf_srcptr {
        return &self.raw[0];
    }

    /// Allocate an initialised value of 0 with at least `precision_bits` of
    /// precision. The precision is a C `mp_bitcnt_t`, which is GMP's own
    /// parameter type for it.
    ///
    /// Because GMP keeps whole limbs, the stored precision can exceed the
    /// request (`doc/gmp.texi:4762-4765`); `getPrecision` reports the stored
    /// one.
    pub fn init(precision_bits: c.mp_bitcnt_t) Float {
        var self: Float = .{ .raw = undefined };
        c.mpf_init2(self.rawPtr(), precision_bits);
        return self;
    }

    /// Release the limbs GMP allocated for this value.
    ///
    /// The value is unusable afterwards and a second call is a double free.
    /// One `init` is one `deinit`: a copy made by assignment is a second name
    /// for this same GMP value and must not be released.
    pub fn deinit(self: *Float) void {
        c.mpf_clear(self.rawPtr());
    }

    /// Parse `text`. Base 0 reaches `mpf_set_str` as base 10, with no look at a
    /// `0x` or leading `0` prefix, which is what separates it from
    /// `mpz_set_str` (`mpf/set_str.c:153-155`, `doc/gmp.texi:4877-4879`); any
    /// other base must be in 2..62. The radix point is the locale's
    /// `GMP_DECIMAL_POINT` (`mpf/set_str.c:132-133`) and the exponent follows
    /// `@`, or `e`/`E` in a base of 10 or less (`mpf/set_str.c:193`).
    ///
    /// `text` must be NUL terminated: `mpf_set_str` reads it as a C string and
    /// the pointer is passed through unchanged.
    ///
    /// White space is accepted, as it is by `mpz_set_str`: both functions skip
    /// leading white space (`mpf/set_str.c:142-144`, `mpz/set_str.c:67-68`) and
    /// drop white space from the body of the number (`mpf/set_str.c:211-212`,
    /// `mpz/set_str.c:119-120`).
    ///
    /// On `error.InvalidBase` GMP is not called and the value is untouched. On
    /// `error.InvalidFormat` it is untouched as well: every failure return in
    /// `mpf_set_str` happens before it writes the destination, at
    /// `mpf/set_str.c:172,181,183,225,237,308` against the writes at `:276`,
    /// `:331` and `:406`. The precision is unchanged either way.
    pub fn setStr(self: *Float, text: [:0]const u8, base: u8) ParseError!void {
        if (!bases.validInputBase(base)) return error.InvalidBase;
        if (c.mpf_set_str(self.rawPtr(), text.ptr, base) < 0) return error.InvalidFormat;
    }

    /// Parse `text` into a fresh value of `precision_bits` bits, with `setStr`'s
    /// base rule. A failed parse releases the half-built value, so an error
    /// leaves the caller nothing to release.
    pub fn parse(text: [:0]const u8, precision_bits: c.mp_bitcnt_t) ParseError!Float {
        var self = Float.init(precision_bits);
        errdefer self.deinit();
        try self.setStr(text, 0);
        return self;
    }

    /// Copy `other` into `self`, truncating to this value's precision.
    ///
    /// `mpf_set` drops the low limbs of a source that does not fit instead of
    /// rounding it (`mpf/set.c:46-50`), and `other` may be `self`.
    pub fn set(self: *Float, other: *const Float) void {
        c.mpf_set(self.rawPtr(), other.rawSrcPtr());
    }

    /// Set the value from a `double`, truncating to this value's precision.
    ///
    /// This is `mpf_set_d`, not a round-to-nearest-even conversion: GMP
    /// truncates to the destination precision (`doc/gmp.texi:4700-4702`).
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

    /// Current precision in bits, GMP's `mpf_get_prec`, which is the limb
    /// rounded precision this value actually stores rather than the bit count
    /// `init` was given (`doc/gmp.texi:4803-4805`).
    pub fn getPrecision(self: *const Float) c.mp_bitcnt_t {
        return c.mpf_get_prec(self.rawSrcPtr());
    }

    /// Set the precision to at least `precision_bits`, truncating the value to
    /// it.
    ///
    /// GMP keeps whole limbs, so the stored precision can exceed the request,
    /// and what the value loses here is truncated toward zero, not rounded to
    /// nearest (`doc/gmp.texi:4807-4809`). The call reallocates the limbs, so it
    /// is not one to put in a tight loop (`doc/gmp.texi:4811-4812`).
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

    /// Whether the value is zero, `sign() == 0`.
    ///
    /// `sign` reads `_mp_size`, which `gmp.h` documents as the limb count of
    /// the value with the sign folded into it (`gmp-h.in:195-197`) and which
    /// GMP reports as `mpf_size` (`mpf/size.c:34-38`). GMP normalises the size
    /// it stores, so a size of zero is this type's only zero: a cancelled
    /// subtraction strips its zero limbs down to it (`mpf/sub.c:375-390`), a
    /// division strips a zero high limb (`mpf/div.c:129-134`), and a zero from
    /// `mpf_set_d`, `mpf_set_ui` or `mpf_set_str` is stored as size zero
    /// (`mpf/set_d.c:49-53`, `mpf/set_ui.c:38-47`, `mpf/set_str.c:274-280`).
    ///
    /// So exactly one of `isZero`, `isNegative` and `isPositive` is true of any
    /// value. `mpf` has no infinity and no NaN, which are the two states that
    /// would leave all three false (`doc/gmp.texi:4711-4713`).
    pub fn isZero(self: *const Float) bool {
        return self.sign() == 0;
    }

    /// Whether the value is negative, `sign() < 0`: the same `_mp_size`, read
    /// for its sign rather than for being zero.
    ///
    /// There is no negative zero to read: `mpf_neg` negates the size, and
    /// negating a size of zero leaves it zero (`mpf/neg.c:38-60`), so a value
    /// of zero is not negative however it was produced.
    pub fn isNegative(self: *const Float) bool {
        return self.sign() < 0;
    }

    /// Whether the value is positive, `sign() > 0`: the same `_mp_size`, read
    /// for its sign rather than for being zero. A value of zero is not
    /// positive.
    pub fn isPositive(self: *const Float) bool {
        return self.sign() > 0;
    }

    /// Truncating conversion to `f64`: rounding toward zero, not to nearest
    /// (`doc/gmp.texi:4944-4946`). `mpf` has no infinity and no NaN, so an
    /// exponent too large or too small for a `f64` gives an unpredictable
    /// result rather than a saturated one (`doc/gmp.texi:4711-4713`).
    pub fn getDouble(self: *const Float) f64 {
        return c.mpf_get_d(self.rawSrcPtr());
    }

    /// Render `digits` significant digits into caller owned storage.
    ///
    /// The text and exponent follow `mpf_get_str`: see `Rendered`. The digits
    /// render *this* value, which the precision above has already truncated,
    /// and `mpf_get_str` then rounds the rendered text half up at the last
    /// requested digit (`mpf/get_str.c:256-262`). That rounding belongs to the
    /// rendering and does not recover the bits the value lost.
    ///
    /// `Rendered` borrows `buffer`: it is invalidated when the caller writes
    /// `buffer` again or lets it out of scope. Nothing is allocated and the
    /// text is not copied.
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
