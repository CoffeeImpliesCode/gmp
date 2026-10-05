//! Runnable example: the same file is used by `zig build smoke`, by
//! `zig build run` and by the cross target `check` step.
//!
//! Every line it prints is a fact that can be verified by hand, so the output
//! is deterministic and meaningful rather than a round trip. The program also
//! verifies each line against the expected text and fails with an error if GMP
//! disagrees, which makes `zig build smoke` a real check rather than a demo.
//!
//! In a runtime-loading build the provider is named on the command line
//! (`--provider <path>`) or in `GMP_TEST_PROVIDER`, and the program says which
//! configuration it is in on its first line. A linked build needs neither and
//! reads neither.
//!
//! Output goes to stderr because that is where Zig's standard debug print
//! writes, which keeps the example free of platform specific stdout handling.

const std = @import("std");
const gmp = @import("gmp");

const Mismatch = error{GmpExampleMismatch};

/// Print `label` and `text`, then check the text against `expected`.
fn report(label: []const u8, text: []const u8, expected: []const u8) Mismatch!void {
    std.debug.print("{s: <18}{s}\n", .{ label, text });
    if (!std.mem.eql(u8, text, expected)) {
        std.debug.print("expected: {s}\n", .{expected});
        return error.GmpExampleMismatch;
    }
}

pub fn main(init: std.process.Init) !void {
    var version_buffer: [16]u8 = undefined;
    var buffer: [512]u8 = undefined;

    // Nothing below can run in a runtime-loading build until a provider has
    // been named and loaded, and that load is the one explicit step the
    // contract asks for. It compiles away in a linked build, where the library
    // is already there.
    if (comptime gmp.runtime_loaded) {
        try gmp.load(.{ .path = try gmp.providerRequest(init) });
    }

    std.debug.print(
        "GMP {s} (upstream {s}), portable C backend, {d}-bit limbs, {s} build\n",
        .{
            try gmp.versionString(&version_buffer),
            gmp.upstream_version,
            gmp.limb_bits,
            if (gmp.runtime_loaded) "runtime-loaded" else "linked",
        },
    );

    // The library's own idea of its version and its limb width, read from the
    // provider's live data rather than from the macros this build was compiled
    // against. They are the two words `runtime/library.zig` checks before a
    // load is published, so printing them shows what the check saw.
    const reported_version = gmp.providerVersion();
    if (reported_version.len == 0) return error.GmpExampleMismatch;
    const reported_limbs = gmp.providerBitsPerLimb().*;
    if (reported_limbs != gmp.limb_bits) return error.GmpExampleMismatch;
    std.debug.print(
        "{s: <18}{s}, {d} bits per limb\n",
        .{ "provider reports", reported_version, reported_limbs },
    );

    // Integers.
    var power = gmp.BigInt.init();
    defer power.deinit();
    power.setUnsignedWord(1);
    power.shlAssign(127);
    power.subUi(1);
    try report("2^127-1", try power.writeTo(&buffer, 10), "170141183460469231731687303715884105727");

    var factorial = gmp.BigInt.init();
    defer factorial.deinit();
    factorial.facUi(25);
    try report("25!", try factorial.writeTo(&buffer, 10), "15511210043330985984000000");

    var fibonacci = gmp.BigInt.init();
    defer fibonacci.deinit();
    fibonacci.fibUi(200);
    try report("fib(200)", try fibonacci.writeTo(&buffer, 10), "280571172992510140037611932413038677189525");

    var binom = gmp.BigInt.init();
    defer binom.deinit();
    binom.binUiUi(40, 20);
    try report("binomial(40,20)", try binom.writeTo(&buffer, 10), "137846528820");

    var a = gmp.BigInt.init();
    defer a.deinit();
    a.setUnsignedWord(462);
    var b = gmp.BigInt.init();
    defer b.deinit();
    b.setUnsignedWord(1071);
    var gcd = gmp.BigInt.init();
    defer gcd.deinit();
    gcd.gcd(&a, &b);
    try report("gcd(462,1071)", try gcd.writeTo(&buffer, 10), "21");

    // 2^64 mod 1000000007 = 582344008.
    var modulus = gmp.BigInt.init();
    defer modulus.deinit();
    modulus.setUnsignedWord(1_000_000_007);
    var exponent = gmp.BigInt.init();
    defer exponent.deinit();
    exponent.setUnsignedWord(64);
    var two = gmp.BigInt.init();
    defer two.deinit();
    two.setUnsignedWord(2);
    var reduced = gmp.BigInt.init();
    defer reduced.deinit();
    reduced.powm(&two, &exponent, &modulus);
    try report("2^64 mod 1e9+7", try reduced.writeTo(&buffer, 10), "582344008");

    // Signed division: the three GMP rules differ exactly here.
    var negative_seven = try gmp.BigInt.parse("-7", 10);
    defer negative_seven.deinit();
    var two_divisor = gmp.BigInt.init();
    defer two_divisor.deinit();
    two_divisor.setUnsignedWord(2);

    var truncated = negative_seven.div(&two_divisor, .truncated);
    defer truncated.deinit();
    try report("-7 tdiv_q 2", try truncated.quotient.writeTo(&buffer, 10), "-3");
    try report("-7 tdiv_r 2", try truncated.remainder.writeTo(&buffer, 10), "-1");

    var floor = negative_seven.div(&two_divisor, .floor);
    defer floor.deinit();
    try report("-7 fdiv_q 2", try floor.quotient.writeTo(&buffer, 10), "-4");
    try report("-7 fdiv_r 2", try floor.remainder.writeTo(&buffer, 10), "1");

    // Rationals.
    var half = try gmp.Rational.parse("1/2", 10);
    defer half.deinit();
    var third = try gmp.Rational.parse("1/3", 10);
    defer third.deinit();
    var sum = gmp.Rational.init();
    defer sum.deinit();
    sum.add(&half, &third);
    try report("1/2 + 1/3", try sum.writeTo(&buffer, 10), "5/6");

    // Floating point.
    var two_float = try gmp.Float.parse("2", 256);
    defer two_float.deinit();
    var root = gmp.Float.init(512);
    defer root.deinit();
    root.sqrt(&two_float);
    // `mpf_get_str` returns the significant digits with the radix point
    // implicit and the exponent separate. The exact square root of two
    // begins 1.4142135623730950488016887242096980785696718753769 4..., so
    // its first 50 significant digits are the ones below and its 51st digit
    // is a 4. `mpf_get_str` rounds half up on `tstr[n_digits] * 2 >= base`
    // (`mpf/get_str.c:256-262`) and 4 * 2 < 10, so no carry occurs and the
    // rendering is the plain truncation.
    const rendered = try root.writeTo(&buffer, 10, 50);
    try report("sqrt(2)", rendered.text, "14142135623730950488016887242096980785696718753769");

    // Random state: identical seeds reproduce identical streams.
    var state = gmp.Rand.initMt();
    defer state.deinit();
    state.seed(20240917);
    const first = try state.nextBits(32);
    state.seed(20240917);
    const again = try state.nextBits(32);
    if (first != again) return error.GmpExampleMismatch;
    std.debug.print("{s: <18}{d} (reproducible)\n", .{ "mt seeded twice", first });

    // The raw escape hatch is the same library, not a copy of it.
    var raw = gmp.BigInt.init();
    defer raw.deinit();
    gmp.c.mpz_set_ui(raw.rawPtr(), 42);
    try report("raw mpz_set_ui", try raw.writeTo(&buffer, 10), "42");

    // The `__gmp` spelling is the symbol the library really exports, and
    // `mpz_set_ui` is a macro that aliases it, so both spellings have to reach
    // the same library rather than one of them being a compile-time copy. The
    // value below is the one above times a million, through the prefixed name.
    var prefixed = gmp.BigInt.init();
    defer prefixed.deinit();
    gmp.c.__gmpz_mul_ui(prefixed.rawPtr(), raw.rawSrcPtr(), 1000000);
    try report("raw __gmpz_mul_ui", try prefixed.writeTo(&buffer, 10), "42000000");

    // Linked C varargs take individual arguments; routed wrappers take a
    // tuple, and one value tuple feeds both. The three values carry their C
    // types explicitly because those are the types the format reads: C
    // default argument promotions put a string in front of `%s` as a
    // NUL-terminated `char *` and each `%d` as an `int`, never as the array
    // or the pointer-to-data it is written as in Zig. The buffer being
    // rendered into lives in this frame, so it outlives the call the same way
    // in either configuration, and the format string is a comptime constant
    // that lives for the whole program.
    var formatted: [64]u8 = undefined;
    const format = "%s carries %d bits per limb, errno %d\n";
    const name: [*:0]const u8 = "libgmp";
    const errno_count: c_int = gmp.providerErrno().*;
    const arguments = .{ name, reported_limbs, errno_count };
    const written = if (comptime gmp.runtime_loaded)
        gmp.c.__gmp_snprintf(&formatted, formatted.len, format, arguments)
    else
        @call(.auto, gmp.c.__gmp_snprintf, .{ &formatted, formatted.len, format } ++ arguments);
    // A length past the end of the buffer would already have written out of
    // bounds, so it is refused before it is used as a slice.
    if (written <= 0 or written > @as(c_int, @intCast(formatted.len))) return error.GmpExampleMismatch;
    const produced = formatted[0..@intCast(written)];
    // What those three values have to render to. The limb width is the
    // provider's own and is 32 on a 32-bit limb target, so the text is
    // rendered from the same values with Zig's formatter rather than written
    // out as one constant; GMP's `vsnprintf` path and Zig's formatter share
    // no code, so agreeing with this text is the check.
    var expected: [96]u8 = undefined;
    const wanted = try std.fmt.bufPrint(
        &expected,
        "libgmp carries {d} bits per limb, errno {d}\n",
        .{ reported_limbs, errno_count },
    );
    std.debug.print("{s: <18}{s}", .{ "raw __gmp_snprintf", produced });
    if (!std.mem.eql(u8, produced, wanted)) {
        std.debug.print("expected: {s}", .{wanted});
        return error.GmpExampleMismatch;
    }

    std.debug.print("all example results verified\n", .{});
}
