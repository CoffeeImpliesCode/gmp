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
    // 93 is the largest index whose value still fits in a `u64`, so the
    // reference recurrence below cannot be the same code path as GMP's.
    var i: c_ulong = 0;
    while (i <= 93) : (i += 1) {
        var value = gmp.BigInt.init();
        defer value.deinit();
        value.fibUi(i);
        // Widening to `u64` keeps the comparison typed the same on every
        // target, where `unsigned long` may be 32 bits.
        const actual: u64 = value.toUnsignedWord();
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
