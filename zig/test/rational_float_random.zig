//! Behaviour of the rational, floating point and random facades.
//!
//! The expectations are mathematical facts, not round trips: exact fractions,
//! the published digits of the square root of two, and the reproducibility of
//! a seeded generator.

const std = @import("std");
const gmp = @import("gmp");

const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "rationals are exact, and canonical only once the caller asks" {
    var third = try gmp.Rational.parse("1/3", 10);
    defer third.deinit();

    var sixth = try gmp.Rational.parse("1/6", 10);
    defer sixth.deinit();

    // `mpq_set_str` parses the two parts and does not canonicalise, so this is
    // 2/4 until the value says otherwise.
    var half = try gmp.Rational.parse("2/4", 10);
    defer half.deinit();
    var half_text = try half.toOwnedString(10);
    try expectEqualStrings("2/4", half_text.slice());
    half_text.deinit();

    half.canonicalize();
    half_text = try half.toOwnedString(10);
    defer half_text.deinit();
    try expectEqualStrings("1/2", half_text.slice());

    var sum = gmp.Rational.init();
    defer sum.deinit();
    sum.add(&third, &sixth);

    var buf: [32]u8 = undefined;
    try expectEqualStrings("1/2", try sum.writeTo(&buf, 10));

    var product = gmp.Rational.init();
    defer product.deinit();
    product.mul(&third, &third);
    try expectEqualStrings("1/9", try product.writeTo(&buf, 10));

    var quotient = gmp.Rational.init();
    defer quotient.deinit();
    quotient.div(&third, &sixth);
    try expectEqualStrings("2", try quotient.writeTo(&buf, 10));

    var inverse = gmp.Rational.init();
    defer inverse.deinit();
    inverse.set(&third);
    inverse.inv();
    try expectEqualStrings("3", try inverse.writeTo(&buf, 10));

    var negative = gmp.Rational.init();
    defer negative.deinit();
    negative.set(&third);
    negative.negAssign();
    try expect(negative.isNegative());
    negative.absAssign();
    try expect(!negative.isNegative());

    // Numerator and denominator are independent owned copies.
    var numerator = sum.numerator();
    defer numerator.deinit();
    var denominator = sum.denominator();
    defer denominator.deinit();
    var text: [16]u8 = undefined;
    try expectEqualStrings("1", try numerator.writeTo(&text, 10));
    try expectEqualStrings("2", try denominator.writeTo(&text, 10));
    try expectEqual(@as(f64, 0.5), sum.getDouble());
}

test "rational parsing rejects malformed text" {
    try expectError(error.InvalidDigit, gmp.Rational.parse("1/", 10));
    try expectError(error.InvalidDigit, gmp.Rational.parse("/2", 10));
    try expectError(error.InvalidDigit, gmp.Rational.parse("1/x", 10));
    try expectError(error.InvalidDigit, gmp.Rational.parse("", 10));
    try expectError(error.InvalidBase, gmp.Rational.parse("1/2", 63));
}

test "the rational capacity bound is the manual's, and it is an upper bound" {
    var negative = try gmp.Rational.parse("-1/2", 10);
    defer negative.deinit();

    // `mpz_sizeinbase(1) + mpz_sizeinbase(2) + 3` is five bytes: the digits of
    // both parts, a possible minus sign, a possible slash and the NUL.
    var exact: [5]u8 = undefined;
    try expectEqualStrings("-1/2", try negative.writeTo(&exact, 10));

    // Four bytes hold "-1/2" and its NUL exactly and are still rejected: the
    // published bound is sufficient, not necessary, because the denominator
    // is counted whether or not this value prints a slash.
    var text_fitting: [4]u8 = undefined;
    @memset(&text_fitting, 0xaa);
    try expectError(error.BufferTooSmall, negative.writeTo(&text_fitting, 10));
    try expectEqual(@as(u8, 0xaa), text_fitting[0]);

    // A denominator of one prints no slash, and the bound does not shrink for
    // it: the denominator is still a one digit part of the value.
    var integer = try gmp.Rational.parse("-1", 10);
    defer integer.deinit();
    var five: [5]u8 = undefined;
    try expectEqualStrings("-1", try integer.writeTo(&five, 10));
    var four: [4]u8 = undefined;
    try expectError(error.BufferTooSmall, integer.writeTo(&four, 10));
}

test "float rendering states its digit count and its capacity" {
    var value = try gmp.Float.parse("1.5", 128);
    defer value.deinit();

    // The manual asks for `n_digits + 2` bytes: the digits, a possible sign
    // and the NUL. Five digits of 1.5 are "15000", of which GMP returns "15".
    var exact: [7]u8 = undefined;
    const rendered = try value.writeTo(&exact, 10, 5);
    try expectEqualStrings("15", rendered.text);
    try expectEqual(@as(i64, 1), rendered.exponent);

    var one_short: [6]u8 = undefined;
    try expectError(error.BufferTooSmall, value.writeTo(&one_short, 10, 5));

    // Zero digits means "as many as the precision allows", a count GMP
    // computes internally and does not export, so the caller has to say how
    // many digits it wants before a capacity can be checked.
    try expectError(error.InvalidDigitCount, value.writeTo(&exact, 10, 0));
    try expectError(error.InvalidBase, value.writeTo(&exact, 0, 5));
}

test "floating point values have the published digits of sqrt(2)" {
    var two = try gmp.Float.parse("2", 256);
    defer two.deinit();

    var root = gmp.Float.init(512);
    defer root.deinit();
    root.sqrt(&two);

    var buf: [64]u8 = undefined;
    // `mpf_get_str` returns the significant digits with no radix point and the
    // exponent separately.
    //
    // The exact square root of two begins
    // 1.4142135623730950488016887242096980785696718753769 4 8..., so its
    // first 50 significant digits are
    // `14142135623730950488016887242096980785696718753769` and its 51st digit
    // is a 4.
    //
    // Rounding: `mpf_get_str` asks `mpn_get_str` for one digit more than
    // requested and then applies `if (tstr[n_digits] * 2 >= base)`, which is
    // half up (`mpf/get_str.c:223`, `:256-262`). Here 4 * 2 = 8 < 10, so no
    // carry happens and the rendering is the plain truncation of those 50
    // digits. The 50th digit is a 9, so the trailing-zero strip at
    // `mpf/get_str.c:291-292` removes nothing.
    //
    // The exponent is 1 because the value lies between 1 and 10.
    const rendered = try root.writeTo(&buf, 10, 50);
    try expectEqualStrings("14142135623730950488016887242096980785696718753769", rendered.text);
    try expectEqual(@as(i64, 1), rendered.exponent);

    // `mpf_get_d` truncates toward zero, not rounds to nearest
    // (doc/gmp.texi:4944-4946), so this is the largest double below
    // sqrt(2), 1.41421356237309492343001693370, and not the nearest one,
    // 1.4142135623730951.
    try expectEqual(@as(f64, 1.414213562373095), root.getDouble());
}

test "floating point arithmetic is exact where binary allows it" {
    var a = try gmp.Float.parse("0.1", 256);
    defer a.deinit();
    var b = try gmp.Float.parse("0.2", 256);
    defer b.deinit();

    var sum = gmp.Float.init(256);
    defer sum.deinit();
    sum.add(&a, &b);

    var buf: [32]u8 = undefined;
    // 0.1 and 0.2 have no exact binary representation, so the sum is the
    // correctly rounded value a shade above 0.3. Its first ten significant
    // digits are 3000000000, of which `mpf_get_str` returns the significant
    // ones only, with no radix point, so the text is "3" and a value between
    // 0.1 and 1 has exponent 0.
    const rendered = try sum.writeTo(&buf, 10, 10);
    try expectEqualStrings("3", rendered.text);
    try expectEqual(@as(i64, 0), rendered.exponent);

    // Powers of two are exact, and 2^100 exceeds the largest machine word of
    // every checked target.
    var two = gmp.Float.init(256);
    defer two.deinit();
    two.setDouble(2);
    var power = gmp.Float.init(256);
    defer power.deinit();
    power.pow(&two, 100);
    try expect(power.cmpUnsignedWord(std.math.maxInt(c_ulong)) == .gt);

    var root_nine = gmp.Float.init(256);
    defer root_nine.deinit();
    root_nine.sqrtUnsignedWord(9);
    try expect(root_nine.cmpUnsignedWord(3) == .eq);
}

test "floating point parsing rejects malformed text" {
    var value = gmp.Float.init(64);
    defer value.deinit();

    try expectError(error.InvalidFormat, value.setStr("not a number", 0));
    try expectError(error.InvalidBase, value.setStr("1.5", 63));
}

test "a seeded generator reproduces its sequence" {
    var first = gmp.Rand.initMt();
    defer first.deinit();
    var second = gmp.Rand.initMt();
    defer second.deinit();

    first.seed(1234567);
    second.seed(1234567);
    for (0..32) |_| {
        const left = try first.nextBits(32);
        const right = try second.nextBits(32);
        try expectEqual(left, right);
    }

    // A different seed gives a different sequence. Both states have now drawn
    // the same number of words, so this compares the same position of two
    // different streams.
    var third = gmp.Rand.initMt();
    defer third.deinit();
    third.seed(1234568);
    const other = try third.nextBits(32);
    const reference = try second.nextBits(32);
    try expect(other != reference);
}

test "random draws respect their bound, and the degenerate ones draw nothing" {
    var state = gmp.Rand.initDefault();
    defer state.deinit();
    state.seed(42);

    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        try expect((try state.nextBelow(1000)) < 1000);
        try expect((try state.nextBelow(2)) < 2);
        try expect((try state.nextBits(8)) < 256);
    }

    // Zero bits and a bound of one are the two degenerate requests GMP
    // defines, and both answer 0 without moving the stream. `gmp_urandomb_ui`
    // starts from a zero limb and asks the generator for no bits at all
    // (`rand/randbui.c:42-49`); `gmp_urandomm_ui` reduces a bound of one to
    // zero bits the same way (`rand/randmui.c:35-41` and the bit count at
    // `rand/randmui.c:64`); and a zero bit request runs no loop in the
    // Mersenne Twister reader, so its index never moves
    // (`rand/randmt.c:206-243`). A second identically seeded state is the
    // proof that nothing was consumed.
    var degenerate = gmp.Rand.initDefault();
    defer degenerate.deinit();
    degenerate.seed(42);
    var reference = gmp.Rand.initDefault();
    defer reference.deinit();
    reference.seed(42);

    try expectEqual(@as(c_ulong, 0), try degenerate.nextBits(0));
    try expectEqual(@as(c_ulong, 0), try degenerate.nextBelow(1));
    try expectEqual(try reference.nextBits(32), try degenerate.nextBits(32));
    try expectEqual(try reference.nextBelow(1000), try degenerate.nextBelow(1000));
}

test "the manual's two conditions are refused, and refusing moves nothing" {
    var state = gmp.Rand.initMt();
    defer state.deinit();
    state.seed(42);

    try expectError(error.EmptyRange, state.nextBelow(0));
    try expectError(error.TooManyBits, state.nextBits(@bitSizeOf(c_ulong) + 1));

    // Neither refusal reached GMP, so the seeded stream is where it was.
    var reference = gmp.Rand.initMt();
    defer reference.deinit();
    reference.seed(42);
    const first = try state.nextBits(32);
    const second = try reference.nextBits(32);
    try expectEqual(first, second);
}
