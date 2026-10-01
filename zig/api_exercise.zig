//! Compile-time and run-time exercise of every public facade method.
//!
//! Referencing a function only proves that it is declared. This module calls
//! every public method of `BigInt`, `Rational`, `Float` and `Rand` with valid
//! arguments and checks a mathematical result afterwards, so:
//!
//!   * `zig build check` compiles this for every supported target, which forces
//!     every facade body to be instantiated, and
//!   * `zig build test` runs it natively, which shows the calls really work.
//!
//! The checks are independent known answers, the same ones the test suite
//! uses: exact factorials, exact rational arithmetic and the digits of the
//! square root of two.

const std = @import("std");
const c = @import("c");

// `@import` of a path yields the file's namespace, so each type comes from the
// module that declares it while the error sets come from the module itself.
const bigint_module = @import("BigInt.zig");
const rational_module = @import("Rational.zig");
const float_module = @import("Float.zig");
const rand_module = @import("Rand.zig");

const BigInt = bigint_module.BigInt;
const Rational = rational_module.Rational;
const Float = float_module.Float;
const Rand = rand_module.Rand;

pub const Failure = error{
    /// A public call produced a result that contradicts an independent
    /// expectation.
    UnexpectedResult,
};

fn expect(condition: bool) Failure!void {
    if (!condition) return error.UnexpectedResult;
}

fn expectText(expected: []const u8, actual: []const u8) Failure!void {
    if (!std.mem.eql(u8, expected, actual)) return error.UnexpectedResult;
}

/// Assert that a fallible facade call failed, and failed for the stated
/// reason. The boundary between an accepted and a rejected buffer is part of
/// the public contract, so it is exercised, not merely declared.
fn expectFailure(expected: anyerror, call: anytype) Failure!void {
    if (call) |_| {
        return error.UnexpectedResult;
    } else |err| {
        if (err != expected) return error.UnexpectedResult;
    }
}

/// Call every public facade method once and verify the results that do not
/// depend on how GMP implements them.
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

    // Construction, parsing and copying.
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

    // Arithmetic.
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

    // Division in the three rounding modes, plus exact division and modulo.
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

    // Number theory.
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

    // 7^13 = 96889010407, so 7^13 mod 1000 = 407.
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
    // 3^40 = 12157665459056928801, asserted as text so the fixture does not
    // depend on the width of `unsigned long` on the checked targets.
    try expectText("12157665459056928801", try powers.writeTo(buffer, 10));
    powers.powUi(1, 40);
    try expect(powers.toUnsignedWord() == 1);

    var binom = BigInt.init();
    defer binom.deinit();
    binom.binUiUi(40, 20);
    // Catalan(20) * 21 = 137846528820, which is wider than the 32-bit
    // `unsigned long` of two checked targets, so it is parsed rather than
    // written as a word.
    var expected_binom = try BigInt.parse("137846528820", 10);
    defer expected_binom.deinit();
    try expect(binom.cmp(&expected_binom) == .eq);
    binom.facUi(25);
    try expectText("15511210043330985984000000", try binom.writeTo(buffer, 10));
    binom.fibUi(100);
    try expectText("354224848179261915075", try binom.writeTo(buffer, 10));
    // A Fibonacci number above 2^64 is composite often enough that only the
    // definite answer is asserted.
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

    // Bits.
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
    // `mpz_com` is `-op - 1`, which is GMP's only complement, so the value 1
    // becomes -2. `sign` reports -1 for any negative value, so the value
    // itself is what distinguishes -2 from -1, and -2 fits every target's
    // machine word.
    bits.comAssign();
    try expect(bits.sign() == -1);
    try expect(bits.toSignedWord() == -2);
    bits.absAssign();
    try expect(bits.sign() == 1);
    try expect(bits.fitsUnsignedWord());
    try expect(bits.fitsSignedWord());

    // `shrAssign` is `mpz_fdiv_q_2exp`, which floors, so -7/2 is -4 and not
    // the -3 a truncating shift would give. `mpz_fdiv_q_2exp` is `dir = -1`
    // in `cfdiv_q_2exp` (`mpz/cfdiv_q_2exp.c:108-111`), where `rmask` is
    // all-ones for a negative input (`:67-70`) so any dropped low limb sets
    // `round` and the quotient is incremented (`:81-86`).
    var shifted = BigInt.init();
    defer shifted.deinit();
    try shifted.setStr("-7", 10);
    shifted.shrAssign(1);
    try expect(shifted.isNegative());
    try expectText("-4", try shifted.writeTo(buffer, 10));

    // Bitwise operators. Each expected value is worked out by hand from the
    // binary expansion, not read back from GMP:
    //   0b1100 = 12, 0b1010 = 10
    //   and    = 0b1000 = 8
    //   or     = 0b1110 = 14
    //   xor    = 0b0110 = 6
    // `popCount` counts the ones of the absolute value, and 0b1110 has three.
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

    // The raw escape hatch reaches the same value through `rawPtr`, with the
    // read-only operand taken through `rawSrcPtr`.
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

    // The published capacity bound at its exact boundary. `-7` is one digit
    // with a sign, so the manual's `mpz_sizeinbase + 2` is three bytes, and
    // those three bytes are exactly what the rendering occupies including the
    // NUL.
    var boundary = try BigInt.parse("-7", 10);
    defer boundary.deinit();
    var exact_fit: [3]u8 = undefined;
    try expectText("-7", try boundary.writeTo(&exact_fit, 10));
    var one_short: [2]u8 = undefined;
    try expectFailure(error.BufferTooSmall, boundary.writeTo(&one_short, 10));

    // Base 0 is a parsing convention; rendering and the digit count that sizes
    // the buffer need a real base.
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
    // `mpq_set_str` parses the two parts without reducing them, so parsing is
    // where an unreduced value comes from and `canonicalize` is what fixes it.
    var unsimplified = try Rational.parse("6/8", 10);
    defer unsimplified.deinit();
    try expectText("6/8", try unsimplified.writeTo(buffer, 10));
    unsimplified.canonicalize();
    try expectText("3/4", try unsimplified.writeTo(buffer, 10));

    // `setFraction` reduces as it goes, so it never needs a second pass.
    var reduced = Rational.init();
    defer reduced.deinit();
    reduced.setFraction(&six, &eight);
    try expectText("3/4", try reduced.writeTo(buffer, 10));

    const owned = try sum.toOwnedString(10);
    try expectText("5/6", owned.slice());
    owned.deinit();

    // `mpz_sizeinbase(1) + mpz_sizeinbase(2) + 3` is five bytes, while `-1/2`
    // and its NUL is exactly four: the bound is an upper bound, so the four
    // byte buffer is rejected even though this value would have fitted.
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
    // The exact square root of two begins 1.4142135623730950488016887..., so
    // its first 22 significant digits are `1414213562373095048801` and its 23rd
    // digit is a 6. `mpf_get_str` asks `mpn_get_str` for one digit more than
    // requested and rounds half up on `tstr[n_digits] * 2 >= base`
    // (`mpf/get_str.c:223`, `:256-262`). Here 6 * 2 >= 10, so the last digit
    // is carried from 1 to 2. Twenty-two digits rather than twenty-one because
    // the 21st digit is a zero and `mpf_get_str` strips trailing zeros
    // (`mpf/get_str.c:291-292`), which would silently shorten the answer. The
    // radix point stays implicit, and the exponent is 1 because the value lies
    // between 1 and 10.
    const rendered = try root.writeTo(buffer, 10, 22);
    try expectText("1414213562373095048802", rendered.text);
    try expect(rendered.exponent == 1);
    // `mpf_get_d` truncates toward zero (doc/gmp.texi:4944-4946).
    try expect(root.getDouble() == @as(f64, 1.414213562373095));

    // GMP stores the precision as a limb count that it rounds the requested
    // bits up to, so a 512 bit request comes back as 512 or more on every
    // target (`gmp-impl.h:4433-4440`, `mpf/set_prc_raw.c`), and a value that
    // is exact in binary is unchanged by the wider precision.
    var scaled = try Float.parse("1.5", 128);
    defer scaled.deinit();
    scaled.setPrecision(512);
    try expect(scaled.getPrecision() >= 512);
    try expect(scaled.getDouble() == 1.5);

    // `mpf_add` and `mpf_sub` round to the destination's precision
    // (doc/gmp.texi, "Floating Point Functions"), so this pair uses values that
    // are exact in binary at every precision involved. 3.5 and 1.5 are exact
    // three-bit significands, so `(1.5 + 2) - 1.5` is exactly 2 with no
    // rounding to absorb. Adding the 256-bit square root instead would leave a
    // rounding residue far below 1, and `cmpUnsignedWord` compares against the
    // integer exactly.
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

    // `digits + 2` is the capacity and `digits` has to be stated. Trailing
    // zeros are stripped and the radix point stays implicit, so ten requested
    // digits of 2 render as the single digit "2" at exponent 1.
    var exact: [12]u8 = undefined;
    const rendered_two = try two.writeTo(&exact, 10, 10);
    try expectText("2", rendered_two.text);
    try expect(rendered_two.exponent == 1);
    var one_short: [11]u8 = undefined;
    try expectFailure(error.BufferTooSmall, two.writeTo(&one_short, 10, 10));
    try expectFailure(error.InvalidDigitCount, two.writeTo(&exact, 10, 0));
    try expectFailure(error.InvalidBase, two.writeTo(&exact, 0, 10));

    // The raw escape hatch reaches the same value through `rawPtr`.
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
    // GMP's default generator is the Mersenne Twister, so identically seeded
    // states produce identical sequences. Every draw is taken from both
    // states, one after the other, so the two stay at the same position of
    // the stream: a draw taken from one state alone would leave the next pair
    // comparing two different positions, which is not a statement about the
    // seed at all.
    for (0..8) |_| {
        try expect((try first.nextBits(32)) == (try second.nextBits(32)));
        try expect((try first.nextBits(16)) == (try second.nextBits(16)));
        // Every draw below is taken from both states, one after the other, so
        // the two stay at the same position of the stream. A bound draw from
        // one state alone would leave the next pair comparing two different
        // positions, which is not a statement about the seed at all.
        //
        // A bound of 1000 is not a power of two, which is the case a
        // rejection sampler has to get right; the comparison is the range
        // check and the equality is the seed check, on the same draw.
        const first_below = try first.nextBelow(1000);
        const second_below = try second.nextBelow(1000);
        try expect(first_below < 1000);
        try expect(first_below == second_below);
        try expect((try first.nextBelow(1 << 16)) == (try second.nextBelow(1 << 16)));
        // The smallest accepted bound is 1, which always returns 0.
        try expect((try first.nextBelow(1)) == 0);
        try expect((try second.nextBelow(1)) == 0);

        // The two conditions the manual states are refused before GMP is
        // called, so neither draw moves the state.
        try expectFailure(error.EmptyRange, first.nextBelow(0));
        try expectFailure(error.TooManyBits, first.nextBits(@bitSizeOf(c_ulong) + 1));
    }
}
