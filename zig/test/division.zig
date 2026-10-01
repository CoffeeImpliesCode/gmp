//! Signed division semantics.
//!
//! GMP offers three division rules and they differ exactly where it matters:
//! the quotient rounds in three different directions and the remainder takes
//! the sign of the dividend (truncated) or of the divisor (floor, ceiling).
//! The expectations below are the documented GMP semantics, written out as
//! explicit fractions, not observed behaviour.

const std = @import("std");
const gmp = @import("gmp");

const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const Case = struct {
    /// Parsed input, so sentinel typed: the facade hands the pointer straight to
    /// GMP. The expectations below are only compared as text.
    numerator: [:0]const u8,
    denominator: [:0]const u8,
    /// `mpz_tdiv_q` / `mpz_tdiv_r`: quotient toward zero, remainder takes the
    /// sign of the dividend.
    tdiv_q: []const u8,
    tdiv_r: []const u8,
    /// `mpz_cdiv_q` / `mpz_cdiv_r`: quotient toward +infinity, remainder
    /// `n - q*d`. 7/2 is 3.5, so the quotient is 4 and the remainder is -1;
    /// -7/2 is -3.5, so the quotient is -3 and the remainder is -1.
    cdiv_q: []const u8,
    cdiv_r: []const u8,
    /// `mpz_fdiv_q` / `mpz_fdiv_r`: quotient toward -infinity, remainder takes
    /// the sign of the divisor.
    fdiv_q: []const u8,
    fdiv_r: []const u8,
};

const cases = [_]Case{
    .{
        .numerator = "7",
        .denominator = "2",
        .tdiv_q = "3",
        .tdiv_r = "1",
        .cdiv_q = "4",
        .cdiv_r = "-1",
        .fdiv_q = "3",
        .fdiv_r = "1",
    },
    .{
        .numerator = "-7",
        .denominator = "2",
        .tdiv_q = "-3",
        .tdiv_r = "-1",
        .cdiv_q = "-3",
        .cdiv_r = "-1",
        .fdiv_q = "-4",
        .fdiv_r = "1",
    },
    .{
        .numerator = "7",
        .denominator = "-2",
        .tdiv_q = "-3",
        .tdiv_r = "1",
        .cdiv_q = "-3",
        .cdiv_r = "1",
        .fdiv_q = "-4",
        .fdiv_r = "-1",
    },
    .{
        .numerator = "-7",
        .denominator = "-2",
        .tdiv_q = "3",
        .tdiv_r = "-1",
        .cdiv_q = "4",
        .cdiv_r = "1",
        .fdiv_q = "3",
        .fdiv_r = "-1",
    },
};

/// Render a BigInt as decimal text through a caller owned buffer.
fn decimal(value: *const gmp.BigInt, buffer: []u8) ![:0]const u8 {
    return value.writeTo(buffer, 10);
}

test "the three division rules match GMP's documented semantics" {
    for (cases) |case| {
        var numerator = try gmp.BigInt.parse(case.numerator, 10);
        defer numerator.deinit();
        var denominator = try gmp.BigInt.parse(case.denominator, 10);
        defer denominator.deinit();

        var buf: [8]u8 = undefined;

        {
            var d = numerator.div(&denominator, .truncated);
            defer d.deinit();
            try expectEqualStrings(case.tdiv_q, try decimal(&d.quotient, &buf));
            try expectEqualStrings(case.tdiv_r, try decimal(&d.remainder, &buf));
        }
        {
            var d = numerator.div(&denominator, .floor);
            defer d.deinit();
            try expectEqualStrings(case.fdiv_q, try decimal(&d.quotient, &buf));
            try expectEqualStrings(case.fdiv_r, try decimal(&d.remainder, &buf));
        }
        {
            var d = numerator.div(&denominator, .ceiling);
            defer d.deinit();
            try expectEqualStrings(case.cdiv_q, try decimal(&d.quotient, &buf));
            try expectEqualStrings(case.cdiv_r, try decimal(&d.remainder, &buf));
        }

        // Quotient * denominator + remainder == numerator, in every mode.
        for ([_]gmp.DivisionMode{ .truncated, .floor, .ceiling }) |mode| {
            var d = numerator.div(&denominator, mode);
            defer d.deinit();

            var check = gmp.BigInt.init();
            defer check.deinit();
            check.mul(&d.quotient, &denominator);
            check.addAssign(&d.remainder);
            try expectEqual(std.math.Order.eq, check.cmp(&numerator));
        }
    }
}

test "truncated division assigns into the receiver" {
    // `divAssign` follows GMP's `mpz_tdiv_q`, i.e. the quotient rounds toward
    // zero. The floor rule is reachable through `div(.., .floor)`.
    var negative = try gmp.BigInt.parse("-7", 10);
    defer negative.deinit();
    var two = gmp.BigInt.init();
    defer two.deinit();
    two.setUnsignedWord(2);

    negative.divAssign(&two);
    var buf: [8]u8 = undefined;
    try expectEqualStrings("-3", try decimal(&negative, &buf));
}

test "modulo ignores the divisor's sign and is never negative" {
    // doc/gmp.texi:3464-3465: `mpz_mod` sets r to n mod d, "The sign of the
    // divisor is ignored; the result is always non-negative."  mpz/mod.c
    // takes a truncated remainder and adds the divisor's magnitude back when
    // that remainder came out negative, so both cases below are non-negative
    // rather than taking the divisor's sign.
    var negative_seven = try gmp.BigInt.parse("-7", 10);
    defer negative_seven.deinit();
    var three = gmp.BigInt.init();
    defer three.deinit();
    three.setUnsignedWord(3);

    var positive_modulo = negative_seven.mod(&three);
    defer positive_modulo.deinit();
    var buf: [8]u8 = undefined;
    try expectEqualStrings("2", try decimal(&positive_modulo, &buf));

    var seven = gmp.BigInt.init();
    defer seven.deinit();
    seven.setUnsignedWord(7);
    var negative_three = gmp.BigInt.init();
    defer negative_three.deinit();
    negative_three.setSignedWord(-3);

    var negative_modulo = seven.mod(&negative_three);
    defer negative_modulo.deinit();
    try expectEqualStrings("1", try decimal(&negative_modulo, &buf));
}

test "right shift of a negative value rounds toward minus infinity" {
    // mpz_fdiv_q_2exp: -7 / 2 = -3.5 floors to -4, it does not truncate to -3.
    var negative = try gmp.BigInt.parse("-7", 10);
    defer negative.deinit();
    negative.shrAssign(1);

    var buf: [8]u8 = undefined;
    try expectEqualStrings("-4", try decimal(&negative, &buf));

    var positive = gmp.BigInt.init();
    defer positive.deinit();
    positive.setUnsignedWord(7);
    positive.shrAssign(1);
    try expectEqualStrings("3", try decimal(&positive, &buf));
}

test "exact division of negative operands" {
    // mpz_divexact is only defined for exact division, where the rounding
    // direction cannot matter.
    var a = try gmp.BigInt.parse("-1000000000000000000", 10);
    defer a.deinit();
    var b = gmp.BigInt.init();
    defer b.deinit();
    b.setUnsignedWord(1000);

    var quotient = a.divexact(&b);
    defer quotient.deinit();

    var buf: [24]u8 = undefined;
    try expectEqualStrings("-1000000000000000", try decimal(&quotient, &buf));
}

test "division of a multi limb operand keeps the identity" {
    // A dividend large enough to force GMP to grow its limb buffer.
    var big = gmp.BigInt.init();
    defer big.deinit();
    big.setUnsignedWord(1);
    big.shlAssign(4096);
    big.subUi(1);

    var divisor = gmp.BigInt.init();
    defer divisor.deinit();
    divisor.setUnsignedWord(1_000_000_007);

    for ([_]gmp.DivisionMode{ .truncated, .floor, .ceiling }) |mode| {
        var d = big.div(&divisor, mode);
        defer d.deinit();

        // quotient * divisor + remainder == dividend, which GMP guarantees in
        // all three division modes.
        var check = gmp.BigInt.init();
        defer check.deinit();
        check.mul(&d.quotient, &divisor);
        check.addAssign(&d.remainder);
        try expectEqual(std.math.Order.eq, check.cmp(&big));

        // And the remainder really is smaller than the divisor.
        try expect(d.remainder.cmp(&divisor) == .lt);
    }
}
