//! Exercise public facade methods against independent expected results.

const std = @import("std");
const c = @import("c");

const bigint_module = @import("BigInt.zig");
const rational_module = @import("Rational.zig");
const float_module = @import("Float.zig");
const rand_module = @import("Rand.zig");

const BigInt = bigint_module.BigInt;
const Rational = rational_module.Rational;
const Float = float_module.Float;
const Rand = rand_module.Rand;

pub const Failure = error{
    /// A facade result differed from its independent expectation.
    UnexpectedResult,
};

fn expect(condition: bool) Failure!void {
    if (!condition) return error.UnexpectedResult;
}

fn expectText(expected: []const u8, actual: []const u8) Failure!void {
    if (!std.mem.eql(u8, expected, actual)) return error.UnexpectedResult;
}

fn expectFailure(expected: anyerror, call: anytype) Failure!void {
    if (call) |_| {
        return error.UnexpectedResult;
    } else |err| {
        if (err != expected) return error.UnexpectedResult;
    }
}

/// Exercise the public facade methods with independent expected results.
pub fn exercise() (Failure || bigint_module.ParseError || bigint_module.FormatError || rational_module.ParseError || float_module.ParseError || float_module.FormatError || rand_module.Error)!void {
    var buffer: [512]u8 = undefined;

    try exerciseIntegers(&buffer);
    try exerciseRationals(&buffer);
    try exerciseFloats(&buffer);
    try exerciseRandom();
}

fn exerciseIntegers(buffer: []u8) (Failure || bigint_module.ParseError || bigint_module.FormatError)!void {
    var value = try BigInt.parse("-123456789012345678901234567890", 10);
    defer value.deinit();
    try expect(BigInt.parseOrNull("nonsense", 10) == null);

    try value.setStr("ff", 16);
    try expectText("255", try value.writeTo(buffer, 10));
    var copy = value.clone();
    defer copy.deinit();
    try expect(value.cmp(&copy) == .eq);
    copy.set(&value);
    try expect(copy.cmp(&value) == .eq);

    var sixty_three = try BigInt.parse("63", 10);
    defer sixty_three.deinit();
    var signed_word = BigInt.init();
    defer signed_word.deinit();
    signed_word.setSignedWord(-63);
    try expect(signed_word.cmpAbs(&sixty_three) == .eq);

    var small = BigInt.init();
    defer small.deinit();
    small.setUnsignedWord(63);
    try expect(small.cmpUi(63) == .eq);
    try expect(small.fitsUnsignedWord());
    try expect(small.fitsSignedWord());
    try expect(small.toSignedWord() == 63);

    var from_double = BigInt.init();
    defer from_double.deinit();
    from_double.setDouble(7.9);
    try expect(from_double.toUnsignedWord() == 7);

    var a = BigInt.init();
    defer a.deinit();
    a.setUnsignedWord(48);
    var b = BigInt.init();
    defer b.deinit();
    b.setUnsignedWord(18);

    var scratch = BigInt.init();
    defer scratch.deinit();
    scratch.add(&a, &b);
    try expect(scratch.toUnsignedWord() == 66);
    scratch.sub(&a, &b);
    try expect(scratch.toUnsignedWord() == 30);
    scratch.mul(&a, &b);
    try expect(scratch.toUnsignedWord() == 864);

    scratch.setUnsignedWord(100);
    scratch.addAssign(&b);
    try expect(scratch.toUnsignedWord() == 118);
    scratch.subAssign(&b);
    try expect(scratch.toUnsignedWord() == 100);
    scratch.mulAssign(&b);
    try expect(scratch.toUnsignedWord() == 1800);
    scratch.divAssign(&b);
    try expect(scratch.toUnsignedWord() == 100);
    scratch.addUi(1);
    try expect(scratch.toUnsignedWord() == 101);
    scratch.subUi(1);
    try expect(scratch.toUnsignedWord() == 100);
    scratch.subUiRev(200);
    try expect(scratch.toUnsignedWord() == 100);
    scratch.mulUi(2);
    try expect(scratch.toUnsignedWord() == 200);
    scratch.divUi(8);
    try expect(scratch.toUnsignedWord() == 25);
    scratch.mul2Exp(3);
    try expect(scratch.toUnsignedWord() == 200);

    var dividend = try BigInt.parse("-7", 10);
    defer dividend.deinit();
    var divisor = BigInt.init();
    defer divisor.deinit();
    divisor.setUnsignedWord(2);
    for ([_]bigint_module.DivisionMode{ .truncated, .floor, .ceiling }) |mode| {
        var d = dividend.div(&divisor, mode);
        defer d.deinit();
        var check = d.quotient.clone();
        defer check.deinit();
        check.mul(&d.quotient, &divisor);
        check.addAssign(&d.remainder);
        try expect(check.cmp(&dividend) == .eq);
    }
    var remainder = dividend.mod(&divisor);
    defer remainder.deinit();
    try expect(remainder.toUnsignedWord() == 1);

    var exact = try BigInt.parse("1000", 10);
    defer exact.deinit();
    var eight = BigInt.init();
    defer eight.deinit();
    eight.setUnsignedWord(8);
    var quotient = exact.divexact(&eight);
    defer quotient.deinit();
    try expect(quotient.toUnsignedWord() == 125);

    var g = BigInt.init();
    defer g.deinit();
    g.gcd(&a, &b);
    try expect(g.toUnsignedWord() == 6);
    g.gcdAssign(&b);
    try expect(g.toUnsignedWord() == 6);
    g.lcm(&a, &b);
    try expect(g.toUnsignedWord() == 144);

    var six = BigInt.init();
    defer six.deinit();
    six.setUnsignedWord(6);
    var thirty_five = BigInt.init();
    defer thirty_five.deinit();
    thirty_five.setUnsignedWord(35);
    var bezout_g = BigInt.init();
    defer bezout_g.deinit();
    var bezout_s = BigInt.init();
    defer bezout_s.deinit();
    var bezout_t = BigInt.init();
    defer bezout_t.deinit();
    bezout_g.gcdext(&six, &thirty_five, &bezout_s, &bezout_t);
    try expect(bezout_g.toUnsignedWord() == 1);

    // 7^13 mod 1000 = 407.
    var seven = BigInt.init();
    defer seven.deinit();
    seven.setUnsignedWord(7);
    var thirteen = BigInt.init();
    defer thirteen.deinit();
    thirteen.setUnsignedWord(13);
    var thousand = try BigInt.parse("1000", 10);
    defer thousand.deinit();
    var powm = BigInt.init();
    defer powm.deinit();
    powm.powm(&seven, &thirteen, &thousand);
    try expect(powm.cmpUi(407) == .eq);

    var powers = BigInt.init();
    defer powers.deinit();
    powers.setUnsignedWord(3);
    powers.powAssign(40);
    // Use text for 3^40 so the fixture is independent of `unsigned long` width.
    try expectText("12157665459056928801", try powers.writeTo(buffer, 10));
    powers.powUi(1, 40);
    try expect(powers.toUnsignedWord() == 1);

    var binom = BigInt.init();
    defer binom.deinit();
    binom.binUiUi(40, 20);
    // Parse the expected value because it exceeds 32-bit `unsigned long`.
    var expected_binom = try BigInt.parse("137846528820", 10);
    defer expected_binom.deinit();
    try expect(binom.cmp(&expected_binom) == .eq);
    binom.facUi(25);
    try expectText("15511210043330985984000000", try binom.writeTo(buffer, 10));
    binom.fibUi(100);
    try expectText("354224848179261915075", try binom.writeTo(buffer, 10));
    // Assert only GMP's definite composite result for this large Fibonacci value.
    try expect(binom.probabPrime(15) == 0);

    // Modular inverse: 3^-1 mod 5 = 2, and an even value is not invertible.
    var three = BigInt.init();
    defer three.deinit();
    three.setUnsignedWord(3);
    var five = BigInt.init();
    defer five.deinit();
    five.setUnsignedWord(5);
    var inverse = BigInt.init();
    defer inverse.deinit();
    try expect(inverse.invert(&three, &five));
    try expect(inverse.toUnsignedWord() == 2);
    var four = BigInt.init();
    defer four.deinit();
    four.setUnsignedWord(4);
    try expect(!inverse.invert(&four, &eight));

    var bits = BigInt.init();
    defer bits.deinit();
    bits.setUnsignedWord(1);
    bits.shlAssign(127);
    try expect(bits.bitLength() == 128);
    try expect(bits.isEven());
    bits.setBit(0);
    try expect(bits.isOdd());
    try expect(bits.testBit(127));
    bits.clearBit(127);
    try expect(!bits.testBit(127));
    try expect(bits.countTrailingZeroBits() == 0);
    bits.negAssign();
    try expect(bits.isNegative());
    try expect(bits.sign() == -1);
    bits.absAssign();
    try expect(bits.isPositive());
    // GMP complement is `-x - 1`, so complementing 1 gives -2.
    bits.comAssign();
    try expect(bits.sign() == -1);
    try expect(bits.toSignedWord() == -2);
    bits.absAssign();
    try expect(bits.sign() == 1);
    try expect(bits.fitsUnsignedWord());
    try expect(bits.fitsSignedWord());

    // GMP's `fdiv` shift floors: `-7 / 2` becomes -4.
    var shifted = BigInt.init();
    defer shifted.deinit();
    try shifted.setStr("-7", 10);
    shifted.shrAssign(1);
    try expect(shifted.isNegative());
    try expectText("-4", try shifted.writeTo(buffer, 10));

    // Expected bitwise results: 12 & 10 = 8, 12 | 10 = 14, and 12 ^ 10 = 6.
    var twelve = BigInt.init();
    defer twelve.deinit();
    twelve.setUnsignedWord(12);
    var ten = BigInt.init();
    defer ten.deinit();
    ten.setUnsignedWord(10);

    var combined = BigInt.init();
    defer combined.deinit();
    combined.bitAnd(&twelve, &ten);
    try expect(combined.toUnsignedWord() == 8);
    combined.bitOr(&twelve, &ten);
    try expect(combined.toUnsignedWord() == 14);
    try expect(combined.popCount() == 3);
    combined.bitXor(&twelve, &ten);
    try expect(combined.toUnsignedWord() == 6);
    try expect(combined.popCount() == 2);

    bits.setUnsignedWord(255);
    c.mpz_add_ui(bits.rawPtr(), bits.rawSrcPtr(), 1);
    try expect(bits.toUnsignedWord() == 256);

    var exchanged = BigInt.init();
    defer exchanged.deinit();
    exchanged.setUnsignedWord(1);
    var holder = BigInt.init();
    defer holder.deinit();
    holder.setUnsignedWord(2);
    exchanged.swap(&holder);
    try expect(exchanged.toUnsignedWord() == 2);
    try expect(holder.toUnsignedWord() == 1);

    try expect(value.getDouble() == 255.0);
    const owned = try value.toOwnedString(16);
    try expectText("ff", owned.slice());
    owned.deinit();

    // `-7` needs exactly `sizeinbase + 2 == 3` bytes, including its NUL.
    var boundary = try BigInt.parse("-7", 10);
    defer boundary.deinit();
    var exact_fit: [3]u8 = undefined;
    try expectText("-7", try boundary.writeTo(&exact_fit, 10));
    var one_short: [2]u8 = undefined;
    try expectFailure(error.BufferTooSmall, boundary.writeTo(&one_short, 10));

    // Base 0 is for parsing; rendering requires a base in 2..62.
    try expectFailure(error.InvalidBase, boundary.writeTo(&exact_fit, 0));
    try expectFailure(error.InvalidBase, boundary.writeTo(&exact_fit, 1));
    try expectFailure(error.InvalidBase, boundary.sizeinbase(0));
    try expectFailure(error.InvalidBase, boundary.sizeinbase(63));
}

fn exerciseRationals(buffer: []u8) (Failure || rational_module.ParseError || rational_module.FormatError)!void {
    var half = try Rational.parse("1/2", 10);
    defer half.deinit();

    var third = Rational.init();
    defer third.deinit();
    third.setUi(1, 3);

    var sum = Rational.init();
    defer sum.deinit();
    sum.add(&half, &third);
    try expectText("5/6", try sum.writeTo(buffer, 10));

    var difference = Rational.init();
    defer difference.deinit();
    difference.sub(&third, &half);
    try expectText("-1/6", try difference.writeTo(buffer, 10));

    var product = Rational.init();
    defer product.deinit();
    product.mul(&third, &third);
    try expectText("1/9", try product.writeTo(buffer, 10));

    var quotient = Rational.init();
    defer quotient.deinit();
    quotient.div(&half, &third);
    try expectText("3/2", try quotient.writeTo(buffer, 10));

    quotient.addAssign(&half);
    try expect(quotient.cmpZero() == .gt);
    try expect(quotient.cmp(&half) == .gt);
    try expect(quotient.cmpUi(2, 1) == .eq);
    try expect(!quotient.isZero());
    try expect(!quotient.isNegative());

    quotient.negAssign();
    try expect(quotient.isNegative());
    quotient.absAssign();
    quotient.inv();
    // 3/2 + 1/2 = 2, negated, made positive again, then inverted: 1/2.
    try expect(quotient.cmpUi(1, 2) == .eq);

    var duplicate = Rational.init();
    defer duplicate.deinit();
    duplicate.set(&half);
    var cloned = duplicate.clone();
    defer cloned.deinit();
    cloned.swap(&duplicate);
    try expectText("1/2", try cloned.writeTo(buffer, 10));

    var numerator = sum.numerator();
    defer numerator.deinit();
    try expect(numerator.toUnsignedWord() == 5);
    var denominator = sum.denominator();
    defer denominator.deinit();
    try expect(denominator.toUnsignedWord() == 6);

    var forty_two = try BigInt.parse("42", 10);
    defer forty_two.deinit();
    var integer = Rational.init();
    defer integer.deinit();
    integer.setInteger(&forty_two);
    try expect(integer.cmpUi(42, 1) == .eq);
    try expect(integer.getDouble() == 42.0);

    var six = try BigInt.parse("6", 10);
    defer six.deinit();
    var eight = try BigInt.parse("8", 10);
    defer eight.deinit();
    // `mpq_set_str` does not reduce; `canonicalize` does.
    var unsimplified = try Rational.parse("6/8", 10);
    defer unsimplified.deinit();
    try expectText("6/8", try unsimplified.writeTo(buffer, 10));
    unsimplified.canonicalize();
    try expectText("3/4", try unsimplified.writeTo(buffer, 10));

    var reduced = Rational.init();
    defer reduced.deinit();
    reduced.setFraction(&six, &eight);
    try expectText("3/4", try reduced.writeTo(buffer, 10));

    const owned = try sum.toOwnedString(10);
    try expectText("5/6", owned.slice());
    owned.deinit();

    // This upper-bound buffer rejects four bytes even though `-1/2` fits.
    var negative = Rational.init();
    defer negative.deinit();
    negative.set(&half);
    negative.negAssign();
    var exact: [5]u8 = undefined;
    try expectText("-1/2", try negative.writeTo(&exact, 10));
    var text_fitting: [4]u8 = undefined;
    try expectFailure(error.BufferTooSmall, negative.writeTo(&text_fitting, 10));
    try expectFailure(error.InvalidBase, negative.writeTo(&exact, 0));
}

fn exerciseFloats(buffer: []u8) (Failure || float_module.ParseError || float_module.FormatError)!void {
    var two = try Float.parse("2", 128);
    defer two.deinit();
    try expect(two.cmpUnsignedWord(2) == .eq);
    try expect(two.sign() == 1);
    try expect(!two.isZero());
    try expect(!two.isNegative());
    try expect(two.isPositive());

    var root = Float.init(256);
    defer root.deinit();
    root.sqrt(&two);
    // GMP rounds the 23rd sqrt(2) digit up for this 22-digit result.
    // Trailing zeros are removed, and the exponent keeps the radix point implicit.
    const rendered = try root.writeTo(buffer, 10, 22);
    try expectText("1414213562373095048802", rendered.text);
    try expect(rendered.exponent == 1);
    // `mpf_get_d` truncates toward zero (doc/gmp.texi:4944-4946).
    try expect(root.getDouble() == @as(f64, 1.414213562373095));

    // GMP rounds precision to whole limbs; exact binary values remain unchanged.
    var scaled = try Float.parse("1.5", 128);
    defer scaled.deinit();
    scaled.setPrecision(512);
    try expect(scaled.getPrecision() >= 512);
    try expect(scaled.getDouble() == 1.5);

    // `mpf_add` and `mpf_sub` truncate to the destination precision.
    // These values are exact at both tested precisions.
    var sum = Float.init(128);
    defer sum.deinit();
    sum.add(&scaled, &two);
    try expect(sum.getDouble() == 3.5);
    var difference = Float.init(128);
    defer difference.deinit();
    difference.sub(&sum, &scaled);
    try expect(difference.cmpUnsignedWord(2) == .eq);

    var product = Float.init(128);
    defer product.deinit();
    product.mul(&two, &two);
    try expect(product.cmpUnsignedWord(4) == .eq);
    try expect(product.cmp(&two) == .gt);

    var quotient = Float.init(128);
    defer quotient.deinit();
    quotient.div(&product, &two);
    try expect(quotient.cmpUnsignedWord(2) == .eq);

    var power = Float.init(128);
    defer power.deinit();
    power.pow(&two, 10);
    try expect(power.cmpUnsignedWord(1024) == .eq);

    var square_root = Float.init(128);
    defer square_root.deinit();
    square_root.sqrtUnsignedWord(9);
    try expect(square_root.cmpUnsignedWord(3) == .eq);

    var copied = Float.init(64);
    defer copied.deinit();
    copied.set(&two);
    try expect(copied.cmpUnsignedWord(2) == .eq);
    copied.setDouble(2.5);
    try expect(copied.getDouble() == 2.5);
    copied.setUnsignedWord(3);
    try expect(copied.cmpUnsignedWord(3) == .eq);
    try copied.setStr(" 1.5", 0);
    try expect(copied.getDouble() == 1.5);

    // GMP strips trailing zeros; ten requested digits of 2 return `2` at exponent 1.
    var exact: [12]u8 = undefined;
    const rendered_two = try two.writeTo(&exact, 10, 10);
    try expectText("2", rendered_two.text);
    try expect(rendered_two.exponent == 1);
    var one_short: [11]u8 = undefined;
    try expectFailure(error.BufferTooSmall, two.writeTo(&one_short, 10, 10));
    try expectFailure(error.InvalidDigitCount, two.writeTo(&exact, 10, 0));
    try expectFailure(error.InvalidBase, two.writeTo(&exact, 0, 10));

    c.mpf_set_ui(copied.rawPtr(), 5);
    try expect(copied.cmpUnsignedWord(5) == .eq);
}

fn exerciseRandom() (Failure || rand_module.Error)!void {
    var first = Rand.initMt();
    defer first.deinit();
    var second = Rand.initDefault();
    defer second.deinit();

    const seed: c_ulong = 20240917;
    first.seed(seed);
    second.seed(seed);
    // Advance both states equally so comparisons test seed, not stream position.
    for (0..8) |_| {
        try expect((try first.nextBits(32)) == (try second.nextBits(32)));
        try expect((try first.nextBits(16)) == (try second.nextBits(16)));
        // Bound 1000 exercises rejection sampling while the streams stay aligned.
        const first_below = try first.nextBelow(1000);
        const second_below = try second.nextBelow(1000);
        try expect(first_below < 1000);
        try expect(first_below == second_below);
        try expect((try first.nextBelow(1 << 16)) == (try second.nextBelow(1 << 16)));
        // The smallest accepted bound is 1, which always returns 0.
        try expect((try first.nextBelow(1)) == 0);
        try expect((try second.nextBelow(1)) == 0);

        // Rejected arguments do not reach GMP or advance either state.
        try expectFailure(error.EmptyRange, first.nextBelow(0));
        try expectFailure(error.TooManyBits, first.nextBits(@bitSizeOf(c_ulong) + 1));
    }
}
