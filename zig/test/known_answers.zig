//! Known-answer tests for the GMP core.
//!
//! Every expected value here is an independent mathematical fact, not the
//! output of GMP compared against itself:
//!
//!   * exact values of small integers, powers and factorials that can be
//!     written down by hand,
//!   * Fibonacci numbers computed in the test itself with `u64` arithmetic
//!     over a completely different code path than GMP's `mpz_fib_ui`,
//!   * modular exponentiation computed in the test with `u64` schoolbook
//!     `mulmod`/`modpow`, again independent of GMP's `mpz_powm`,
//!   * digit counts of factorials, which are standard tabulated values.
//!
//! Round trips are deliberately absent here; they live in `parsing.zig` and
//! `ownership.zig` where they can only supplement an external expectation.

const std = @import("std");
const gmp = @import("gmp");
const bootstrap = @import("bootstrap.zig");

const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

/// Independent `u64` modular exponentiation (schoolbook). The modulus stays
/// below 2^30, so every product fits in a `u64`.
fn referenceModPow(base: u64, exp: u64, modulus: u64) u64 {
    var result: u64 = 1 % modulus;
    var factor = base % modulus;
    var rest = exp;
    while (rest != 0) {
        if (rest & 1 == 1) result = (result * factor) % modulus;
        factor = (factor * factor) % modulus;
        rest >>= 1;
    }
    return result;
}

/// Independent `u64` Fibonacci, plain linear recurrence.
///
/// The loop stops one term short of `n`, so it never computes F(n+1). F93 is
/// the largest Fibonacci that fits in a `u64` (`12200160415121876738`, under
/// `18446744073709551615`) while F94 does not, so a recurrence that ran one
/// step further would overflow on the very value it is meant to produce.
fn referenceFib(n: u64) u64 {
    if (n == 0) return 0;
    var a: u64 = 0;
    var b: u64 = 1;
    var i: u64 = 1;
    while (i < n) : (i += 1) {
        const next = a + b;
        a = b;
        b = next;
    }
    return b;
}

test "powers of two are exact" {
    try bootstrap.ensureLoaded();
    const cases = [_]struct { exp: gmp.c.mp_bitcnt_t, decimal: []const u8 }{
        .{ .exp = 64, .decimal = "18446744073709551616" },
        .{ .exp = 100, .decimal = "1267650600228229401496703205376" },
        .{ .exp = 127, .decimal = "170141183460469231731687303715884105728" },
        .{ .exp = 128, .decimal = "340282366920938463463374607431768211456" },
        .{ .exp = 256, .decimal = "115792089237316195423570985008687907853269984665640564039457584007913129639936" },
    };

    var buf: [160]u8 = undefined;
    for (cases) |case| {
        var power = gmp.BigInt.init();
        defer power.deinit();

        power.setUnsignedWord(1);
        power.shlAssign(case.exp);

        try expectEqualStrings(case.decimal, try power.writeTo(&buf, 10));
        try expectEqual(@as(usize, @intCast(case.exp + 1)), power.bitLength());
    }
}

test "Mersenne prime 2^127-1 has the expected digits in every base" {
    try bootstrap.ensureLoaded();
    var value = try gmp.BigInt.parse("170141183460469231731687303715884105727", 10);
    defer value.deinit();

    try expectEqual(@as(usize, 127), value.bitLength());
    try expect(value.isOdd());
    try expectEqual(@as(i32, 1), value.sign());

    // 2^127 - 1 is thirty-two hexadecimal digits: a leading 7 and 31 f's.
    var expected_hex: [32]u8 = undefined;
    expected_hex[0] = '7';
    @memset(expected_hex[1..], 'f');
    var hex: [40]u8 = undefined;
    const hex_text = try value.writeTo(&hex, 16);
    try expectEqualStrings(expected_hex[0..], hex_text);

    // 2^127 - 1 is one hundred and twenty-seven binary ones.
    var expected_bin: [127]u8 = undefined;
    @memset(&expected_bin, '1');
    var bin: [140]u8 = undefined;
    try expectEqualStrings(expected_bin[0..], try value.writeTo(&bin, 2));

    // Reparsing the hexadecimal rendering must give back the same number.
    var again = try gmp.BigInt.parse(hex_text, 16);
    defer again.deinit();
    try expectEqual(std.math.Order.eq, value.cmp(&again));
}

test "factorials match hand computed values" {
    try bootstrap.ensureLoaded();
    const cases = [_]struct { n: c_ulong, decimal: []const u8 }{
        .{ .n = 0, .decimal = "1" },
        .{ .n = 5, .decimal = "120" },
        .{ .n = 10, .decimal = "3628800" },
        .{ .n = 20, .decimal = "2432902008176640000" },
        .{ .n = 25, .decimal = "15511210043330985984000000" },
    };

    var buf: [64]u8 = undefined;
    for (cases) |case| {
        var factorial = gmp.BigInt.init();
        defer factorial.deinit();
        factorial.facUi(case.n);
        try expectEqualStrings(case.decimal, try factorial.writeTo(&buf, 10));
    }
}

test "factorial digit counts and leading digits" {
    try bootstrap.ensureLoaded();
    // Exact decimal digit counts of n!, obtained by exact integer arithmetic
    // on the definition n! = 1*2*...*n rather than by running GMP, so the
    // expectation is independent of the code under test. They agree with
    // floor(log10(n!)) + 1 from Stirling's formula, and with the published
    // 1000! = 4023872607766... value whose first digits are asserted below.
    // 1000! begins 4023872600 77..., which pins the magnitude as well as the
    // digit count.
    const cases = [_]struct { n: c_ulong, digits: usize }{
        .{ .n = 10, .digits = 7 },
        .{ .n = 50, .digits = 65 },
        .{ .n = 100, .digits = 158 },
        .{ .n = 200, .digits = 375 },
        .{ .n = 500, .digits = 1135 },
        .{ .n = 1000, .digits = 2568 },
    };

    for (cases) |case| {
        var factorial = gmp.BigInt.init();
        defer factorial.deinit();
        factorial.facUi(case.n);

        const buf = try std.testing.allocator.alloc(u8, case.digits + 8);
        defer std.testing.allocator.free(buf);

        const text = try factorial.writeTo(buf, 10);
        try expectEqual(case.digits, text.len);

        // 1000! starts with these ten digits, which pins the magnitude as
        // well as the digit count.
        if (case.n == 1000) {
            try expectEqualStrings("4023872600", text[0..10]);
        }
    }
}

test "Fibonacci numbers match an independent u64 recurrence" {
    try bootstrap.ensureLoaded();
    // 93 is the largest index whose value still fits in a `u64`, so the
    // reference recurrence below cannot be the same code path as GMP's, and
    // every one of F0..F93 is compared, none of them skipped.
    //
    // The comparison is on the whole number rather than on a machine word.
    // `BigInt.toUnsignedWord` is `mpz_get_ui`, which returns exactly one
    // `unsigned long`, and that word is 32 bits wherever the long is not the
    // pointer width - `wasm32-wasi` among the six checked targets, and the
    // 32-bit ARM cell of the wider run that reported this. Assigning the
    // result to a `u64` cannot recover the limbs above it: F47 = 4807526976
    // comes back as 4807526976 - 4294967296 = 512559680 there, so the
    // widening compares 512559680 against 4807526976 and fails on a correct
    // library. The same would happen to F93 = 12200160415121876738.
    //
    // So the value is read back the way this file reads every other wide
    // number: as the decimal text GMP renders, parsed into the `u64` the
    // oracle already computed. `mpz_get_str` writes every digit of a
    // non-negative value, so nothing is lost on any target and the oracle
    // stays a plain `u64` recurrence that no word width can shorten.
    var i: c_ulong = 0;
    while (i <= 93) : (i += 1) {
        var value = gmp.BigInt.init();
        defer value.deinit();
        value.fibUi(i);

        // F93 has twenty decimal digits and F0 has one, so every value in
        // this loop is a non-negative number under twenty-one digits.
        // `writeTo` wants `sizeinbase` plus two - a possible sign and the NUL
        // - and `sizeinbase` may itself report one digit too many, which is
        // why 32 is sized here rather than 22.
        var decimal: [32]u8 = undefined;
        const actual = try std.fmt.parseInt(u64, try value.writeTo(&decimal, 10), 10);
        try expectEqual(referenceFib(i), actual);
    }

    var fib = gmp.BigInt.init();
    defer fib.deinit();
    var buf: [48]u8 = undefined;

    fib.fibUi(100);
    try expectEqualStrings("354224848179261915075", try fib.writeTo(&buf, 10));

    fib.fibUi(200);
    try expectEqualStrings("280571172992510140037611932413038677189525", try fib.writeTo(&buf, 10));
}

test "catalan numbers" {
    try bootstrap.ensureLoaded();
    // Catalan(20) = binom(40,20)/21 = 6564120420.
    var catalan = gmp.BigInt.init();
    defer catalan.deinit();
    catalan.binUiUi(40, 20);

    var twenty_one = gmp.BigInt.init();
    defer twenty_one.deinit();
    twenty_one.setUnsignedWord(21);
    catalan.divAssign(&twenty_one);

    var buf: [16]u8 = undefined;
    try expectEqualStrings("6564120420", try catalan.writeTo(&buf, 10));
}

test "modular exponentiation matches an independent u64 modpow" {
    try bootstrap.ensureLoaded();
    const cases = [_]struct { base: c_ulong, exp: c_ulong, modulus: c_ulong }{
        .{ .base = 2, .exp = 1000, .modulus = 1_000_000_007 },
        .{ .base = 3, .exp = 12345, .modulus = 1_000_000_007 },
        .{ .base = 123456789, .exp = 65537, .modulus = 1_000_000_009 },
    };

    for (cases) |case| {
        var base = gmp.BigInt.init();
        defer base.deinit();
        base.setUnsignedWord(case.base);

        var exponent = gmp.BigInt.init();
        defer exponent.deinit();
        exponent.setUnsignedWord(case.exp);

        var modulus = gmp.BigInt.init();
        defer modulus.deinit();
        modulus.setUnsignedWord(case.modulus);

        var result = gmp.BigInt.init();
        defer result.deinit();
        result.powm(&base, &exponent, &modulus);

        // The modulus is below 2^30, so the reference result fits the
        // narrowest `unsigned long` a checked target has.
        const expected: c_ulong = @intCast(referenceModPow(case.base, case.exp, case.modulus));
        try expectEqual(expected, result.toUnsignedWord());
    }
}

test "probabilistic primality on known primes and composites" {
    try bootstrap.ensureLoaded();
    // 2^61 - 1 is a Mersenne prime, 2^64 - 59 is the largest prime below 2^64.
    var mersenne = gmp.BigInt.init();
    defer mersenne.deinit();
    mersenne.setUnsignedWord(1);
    mersenne.shlAssign(61);
    mersenne.subUi(1);
    try expectEqual(@as(u32, 1), mersenne.probabPrime(25));

    // 2^64 - 59 is wider than the `unsigned long` of two checked targets, so
    // it is parsed from its decimal text rather than set from a word.
    var largest = try gmp.BigInt.parse("18446744073709551615", 10);
    defer largest.deinit();
    largest.subUi(58);
    try expectEqual(@as(u32, 1), largest.probabPrime(25));

    // Any power of two greater than one is composite.
    var composite = gmp.BigInt.init();
    defer composite.deinit();
    composite.setUnsignedWord(1);
    composite.shlAssign(61);
    try expectEqual(@as(u32, 0), composite.probabPrime(25));
}

test "gcd and lcm of known integers" {
    try bootstrap.ensureLoaded();
    var a = gmp.BigInt.init();
    defer a.deinit();
    var b = gmp.BigInt.init();
    defer b.deinit();
    a.setUnsignedWord(462);
    b.setUnsignedWord(1071);

    var g = gmp.BigInt.init();
    defer g.deinit();
    g.gcd(&a, &b);
    try expectEqual(@as(c_ulong, 21), g.toUnsignedWord());

    var l = gmp.BigInt.init();
    defer l.deinit();
    l.lcm(&a, &b);
    try expectEqual(@as(c_ulong, 23562), l.toUnsignedWord());
}

test "squares at the signed 32-bit boundary" {
    try bootstrap.ensureLoaded();
    var x = gmp.BigInt.init();
    defer x.deinit();
    var square = gmp.BigInt.init();
    defer square.deinit();

    x.setUnsignedWord(46340);
    square.mul(&x, &x);
    try expectEqual(@as(c_ulong, 2147395600), square.toUnsignedWord());

    x.setUnsignedWord(46341);
    square.mul(&x, &x);
    try expectEqual(@as(c_ulong, 2147488281), square.toUnsignedWord());
}

test "a negative value's size helpers have the hand checked answers" {
    try bootstrap.ensureLoaded();
    // 123456789012345678901234567890 lies between 2^96 and 2^97 and is twice
    // 61728394506172839450617283945, so its absolute value has 97 bits, one
    // trailing zero bit, and 25 hexadecimal digits, and neither machine word
    // of any checked target is wide enough to hold it.
    var value = try gmp.BigInt.parse("-123456789012345678901234567890", 10);
    defer value.deinit();

    try expectEqual(@as(usize, 97), value.bitLength());
    try expectEqual(@as(u64, 1), value.countTrailingZeroBits());
    try expectEqual(@as(i32, -1), value.sign());
    // 97 bits round up to 25 hexadecimal digits, exactly, because 16 is a
    // power of two (for other bases mpz_sizeinbase may overestimate by one).
    try expectEqual(@as(u64, 25), try value.sizeinbase(16));
    try expect(!value.fitsUnsignedWord());
    try expect(!value.fitsSignedWord());
}

test "mpn add_1 and sub_1 carry and borrow across two limbs" {
    try bootstrap.ensureLoaded();
    // GMP's low-level layer is published through preprocessor aliases:
    // `gmp.h:1475` writes `#define mpn_add_1 __MPN(add_1)`, which expands to
    // `__gmpn_add_1`, the name the prototype two lines below is declared under.
    // A translation that kept the macro and lost its target would publish
    // `mpn_add_1` as a declaration nobody can call while every symbol behind
    // it is exported, so naming the alias is the point of these two tests.
    //
    // `mp_limb_t` and `GMP_NUMB_MAX` are the header's own, so the same
    // expectations hold on a 32-bit limb target and a 64-bit one, and no limb
    // width is written down anywhere below.
    const Limb = gmp.c.mp_limb_t;
    const max = gmp.c.GMP_NUMB_MAX;
    // GMP counts limbs in `mp_size_t`, a C `long`, which is not `usize` on
    // every checked target and is never the same type in Zig.
    const n: gmp.c.mp_size_t = 2;

    // 2^w - 1 + 1 == 2^w, written least significant limb first: the low limb
    // wraps to zero, the high limb gains the one, and the carry out of the top
    // limb is 0 because 2^w fits in two limbs.
    {
        const src = [2]Limb{ max, 7 };
        var dst: [2]Limb = undefined;
        const carry = gmp.c.mpn_add_1(&dst, &src, n, 1);
        const expected: [2]Limb = .{ 0, 8 };
        try std.testing.expectEqualSlices(Limb, &expected, &dst);
        try expectEqual(@as(Limb, 0), carry);
    }

    // The carry boundary: the largest two-limb value plus one is 2^(2w), which
    // no two-limb value can hold, so both limbs come back zero and the carry
    // out is 1. This is the only case where the carry is 1.
    {
        const src = [2]Limb{ max, max };
        var dst: [2]Limb = undefined;
        const carry = gmp.c.mpn_add_1(&dst, &src, n, 1);
        const expected: [2]Limb = .{ 0, 0 };
        try std.testing.expectEqualSlices(Limb, &expected, &dst);
        try expectEqual(@as(Limb, 1), carry);
    }

    // 2^w - 1 == 2^w - 1: the low limb borrows to all ones and the high limb
    // gives up the one it lends, so the borrow out of the top limb is 0.
    {
        const src = [2]Limb{ 0, 8 };
        var dst: [2]Limb = undefined;
        const borrow = gmp.c.mpn_sub_1(&dst, &src, n, 1);
        const expected: [2]Limb = .{ max, 7 };
        try std.testing.expectEqualSlices(Limb, &expected, &dst);
        try expectEqual(@as(Limb, 0), borrow);
    }

    // Zero minus one is the borrow chain run to the top: every limb borrows, so
    // every limb is all ones and the borrow out of the top limb is 1. That is
    // the only case where the borrow is 1.
    {
        const src = [2]Limb{ 0, 0 };
        var dst: [2]Limb = undefined;
        const borrow = gmp.c.mpn_sub_1(&dst, &src, n, 1);
        const expected: [2]Limb = .{ max, max };
        try std.testing.expectEqualSlices(Limb, &expected, &dst);
        try expectEqual(@as(Limb, 1), borrow);
    }
}

test "mpn_cmp returns exactly -1, 0 or +1 and decides on the high limb" {
    try bootstrap.ensureLoaded();
    const Limb = gmp.c.mp_limb_t;
    const max = gmp.c.GMP_NUMB_MAX;
    const n: gmp.c.mp_size_t = 2;

    // The one pair below is chosen so that a comparison reading the limbs in
    // the wrong order gets it backwards. {max, 7} is 2^w + 6 and {0, 8} is
    // 8 * 2^w, so the correct order is -1: the high limb 7 is below the high
    // limb 8 and that decides, even though the low limbs say the opposite
    // (max is far above 0). An implementation that compared limb 0 first would
    // answer +1 and fail here.
    const smaller = [2]Limb{ max, 7 };
    const larger = [2]Limb{ 0, 8 };

    try expectEqual(@as(c_int, -1), gmp.c.mpn_cmp(&smaller, &larger, n));
    try expectEqual(@as(c_int, 1), gmp.c.mpn_cmp(&larger, &smaller, n));

    // Equal operands compare equal, which is what pins the third of the three
    // answers: -1 and +1 above could both come from a function that never
    // returns 0.
    try expectEqual(@as(c_int, 0), gmp.c.mpn_cmp(&smaller, &smaller, n));
    try expectEqual(@as(c_int, 0), gmp.c.mpn_cmp(&larger, &larger, n));
}
