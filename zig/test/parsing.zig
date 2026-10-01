//! Parsing and formatting behaviour.
//!
//! The accepted inputs and the failure modes are GMP's, not this package's:
//! `mpz_set_str` accepts an optional sign, digits in the requested base, and
//! with base 0 it also honours the `0x`, `0X`, `0b` and `0` prefixes. Anything
//! else, including embedded whitespace, underscores and a trailing garbage
//! character, is rejected.

const std = @import("std");
const gmp = @import("gmp");

const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "decimal parsing accepts a minus sign and leading zeros" {
    const cases = [_]struct { text: [:0]const u8, decimal: []const u8 }{
        .{ .text = "0", .decimal = "0" },
        .{ .text = "42", .decimal = "42" },
        .{ .text = "-42", .decimal = "-42" },
        .{ .text = "0000123", .decimal = "123" },
        .{ .text = "-000", .decimal = "0" },
    };

    var buf: [16]u8 = undefined;
    for (cases) |case| {
        var value = try gmp.BigInt.parse(case.text, 10);
        defer value.deinit();
        try expectEqualStrings(case.decimal, try value.writeTo(&buf, 10));
    }
}

test "base 0 auto detection follows GMP prefixes" {
    const cases = [_]struct { text: [:0]const u8, value: c_ulong }{
        .{ .text = "0x1f", .value = 31 },
        .{ .text = "0X1F", .value = 31 },
        .{ .text = "0b1011", .value = 11 },
        .{ .text = "017", .value = 15 },
        .{ .text = "42", .value = 42 },
    };

    for (cases) |case| {
        var value = try gmp.BigInt.parse(case.text, 0);
        defer value.deinit();
        try expectEqual(case.value, value.toUnsignedWord());
    }
}

test "explicit bases from 2 to 62" {
    var buf: [32]u8 = undefined;

    var binary = try gmp.BigInt.parse("11111111", 2);
    defer binary.deinit();
    try expectEqual(@as(c_ulong, 255), binary.toUnsignedWord());

    var octal = try gmp.BigInt.parse("777", 8);
    defer octal.deinit();
    try expectEqual(@as(c_ulong, 511), octal.toUnsignedWord());

    var hex = try gmp.BigInt.parse("DEADBEEF", 16);
    defer hex.deinit();
    try expectEqualStrings("3735928559", try hex.writeTo(&buf, 10));

    // Base 36 uses the full alphabet.
    var base36 = try gmp.BigInt.parse("ZZZ", 36);
    defer base36.deinit();
    try expectEqual(@as(c_ulong, 35 * 36 * 36 + 35 * 36 + 35), base36.toUnsignedWord());
}

test "invalid input is rejected" {
    // Digits that do not belong to the base.
    try expectError(error.InvalidDigit, gmp.BigInt.parse("12a", 10));
    try expectError(error.InvalidDigit, gmp.BigInt.parse("0b12", 2));
    try expectError(error.InvalidDigit, gmp.BigInt.parse("9", 8));
    try expectError(error.InvalidDigit, gmp.BigInt.parse("g", 16));

    // Structurally broken input. An empty string is refused because the first
    // character is the terminator and `digit_value[0]` is `0xff`
    // (`mpz/set_str.c:66-78`, `mp_dv_tab.c:46-48`), and a bare sign is refused
    // for the same reason.
    try expectError(error.InvalidDigit, gmp.BigInt.parse("", 10));
    try expectError(error.InvalidDigit, gmp.BigInt.parse("-", 10));
    try expectError(error.InvalidDigit, gmp.BigInt.parse("+", 10));
    // A leading `+` is not a sign here. `mpz_set_str` reads `-` at
    // `mpz/set_str.c:70-75` and nothing else, so `+` reaches the digit test
    // with `digit_value['+'] == 0xff` and is refused (`mpz/set_str.c:77-78`).
    try expectError(error.InvalidDigit, gmp.BigInt.parse("+42", 10));

    // Whitespace is not a digit separator and is not rejected either: GMP
    // skips leading whitespace (`mpz/set_str.c:65-68`), skips it among the
    // leading zeros (`:102-104`) and drops every whitespace character from the
    // body (`:118-131`). These parse as their digits with the spaces gone.
    var spaced = try gmp.BigInt.parse(" 12 ", 10);
    defer spaced.deinit();
    var buf: [16]u8 = undefined;
    try expectEqualStrings("12", try spaced.writeTo(&buf, 10));
    var split = try gmp.BigInt.parse("1 2", 10);
    defer split.deinit();
    try expectEqualStrings("12", try split.writeTo(&buf, 10));

    // An underscore is neither a digit nor whitespace, so it is refused.
    try expectError(error.InvalidDigit, gmp.BigInt.parse("1_000", 10));
    // Trailing garbage after a valid number.
    try expectError(error.InvalidDigit, gmp.BigInt.parse("12abc", 10));
}

test "a bare radix prefix with no digits is zero, not an error" {
    // `mpz_set_str` consumes `0x`, sets base 16, and lands on the terminator
    // (`mpz/set_str.c:85-99`). The empty-body case that follows stores zero and
    // reports success (`:105-110`), so this is a defined result rather than a
    // malformed string.
    var value = try gmp.BigInt.parse("0x", 0);
    defer value.deinit();
    try expect(value.isZero());
}

test "out of range bases are rejected before reaching GMP" {
    // GMP only documents bases 0 and 2..62; anything else is rejected here
    // instead of being undefined behaviour inside `mpz_set_str`.
    try expectError(error.InvalidBase, gmp.BigInt.parse("1", 1));
    try expectError(error.InvalidBase, gmp.BigInt.parse("1", 63));
    try expectError(error.InvalidBase, gmp.BigInt.parse("1", 255));
}

test "base 2 through 62 are accepted" {
    var base: u8 = 2;
    while (base <= 62) : (base += 1) {
        var value = try gmp.BigInt.parse("1", base);
        defer value.deinit();
        try expectEqual(@as(c_ulong, 1), value.toUnsignedWord());
    }
}

test "setStr reports failure and leaves the value unspecified" {
    var value = gmp.BigInt.init();
    defer value.deinit();
    value.setUnsignedWord(1234);
    try expectError(error.InvalidDigit, value.setStr("not a number", 10));

    // The contract of `mpz_set_str` is that the value is undefined after a
    // failed parse, so the facade only promises the error. Re-initialising is
    // the supported way to recover.
    value.setUnsignedWord(1234);
    try value.setStr("4321", 10);
    try expectEqual(@as(c_ulong, 4321), value.toUnsignedWord());
}

test "the published capacity bound is the manual's bound, no more" {
    // `-7` is one digit with a sign, so `mpz_sizeinbase + 2` is three bytes,
    // and three bytes are exactly what "-7" and its NUL occupy.
    var small_value = try gmp.BigInt.parse("-7", 10);
    defer small_value.deinit();

    var exact: [3]u8 = undefined;
    const text = try small_value.writeTo(&exact, 10);
    try expectEqualStrings("-7", text);
    try expectEqual(@as(usize, 2), text.len);
    try expectEqual(@as(u8, 0), exact[text.len]);

    // One byte below the published bound is rejected, and the buffer is left
    // alone: the first two bytes still hold the NUL this test wrote itself.
    var one_short: [2]u8 = undefined;
    @memset(&one_short, 0xaa);
    try expectError(error.BufferTooSmall, small_value.writeTo(&one_short, 10));
    try expectEqual(@as(u8, 0xaa), one_short[0]);
    try expectEqual(@as(u8, 0xaa), one_short[1]);

    // A value with a longer text is accepted at the same bound and rejected
    // one byte below it, whatever `mpz_sizeinbase` reports for it.
    var long = try gmp.BigInt.parse("-1234567890123456789012345678901234567890", 10);
    defer long.deinit();
    const digits: usize = @intCast(try long.sizeinbase(10));
    const roomy = try std.testing.allocator.alloc(u8, digits + 2);
    defer std.testing.allocator.free(roomy);
    try expectEqualStrings("-1234567890123456789012345678901234567890", try long.writeTo(roomy, 10));

    const tight = try std.testing.allocator.alloc(u8, digits + 1);
    defer std.testing.allocator.free(tight);
    try expectError(error.BufferTooSmall, long.writeTo(tight, 10));
}

test "rendering needs a real base, parsing may guess one" {
    var value = try gmp.BigInt.parse("255", 10);
    defer value.deinit();
    var buffer: [8]u8 = undefined;

    // Base 0 is an input convention only. `mpz_get_str` happens to read it as
    // base 10, but `mpz_sizeinbase`, which sizes the buffer, asserts
    // `base >= 2` and would divide by `mp_bases[0].big_base` with the
    // assertion compiled out, so no rendering entry point accepts it.
    try expectError(error.InvalidBase, value.writeTo(&buffer, 0));
    try expectError(error.InvalidBase, value.writeTo(&buffer, 1));
    try expectError(error.InvalidBase, value.writeTo(&buffer, 63));
    try expectError(error.InvalidBase, value.sizeinbase(0));
    try expectError(error.InvalidBase, value.sizeinbase(1));
    try expectError(error.InvalidBase, value.sizeinbase(63));
    // Rejected before anything is allocated, not after.
    try expectError(error.InvalidBase, value.toOwnedString(0));
}

test "formatting round trips through every base" {
    var value = gmp.BigInt.init();
    defer value.deinit();
    value.setUnsignedWord(1);
    value.shlAssign(1000);
    value.subUi(1);

    var buffer: [1200]u8 = undefined;
    const bases = [_]u8{ 2, 8, 10, 16, 36, 62 };
    for (bases) |base| {
        const text = try value.writeTo(&buffer, base);
        var again = try gmp.BigInt.parse(text, base);
        defer again.deinit();
        try expectEqual(std.math.Order.eq, value.cmp(&again));
    }
}
