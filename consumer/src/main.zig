//! Consumer of the GMP package: uses only what the package publishes.
//!
//! The results are fixed mathematical facts, so the output is deterministic and
//! a wrong answer fails the run instead of printing silently.

const std = @import("std");
const gmp = @import("gmp");

const Mismatch = error{ConsumerMismatch};

fn report(label: []const u8, text: []const u8, expected: []const u8) Mismatch!void {
    std.debug.print("{s: <16}{s}\n", .{ label, text });
    if (!std.mem.eql(u8, text, expected)) {
        std.debug.print("expected: {s}\n", .{expected});
        return error.ConsumerMismatch;
    }
}

pub fn main() !void {
    var buffer: [256]u8 = undefined;

    std.debug.print("consumer: GMP {s}, {d}-bit limbs\n", .{
        gmp.upstream_version,
        gmp.limb_bits,
    });

    // Facade: owned integers, exact arithmetic and formatting into caller
    // storage.
    var factorial = gmp.BigInt.init();
    defer factorial.deinit();
    factorial.facUi(20);
    try report("20!", try factorial.writeTo(&buffer, 10), "2432902008176640000");

    // `mpz_powm` takes three different values, so the base and the exponent
    // are separate bindings here: 2^160 mod 1000000007 = 213932660. The base is
    // 2 and the exponent is 160; raising an already-raised base would compute
    // 2^25600, which is a different question.
    var base = gmp.BigInt.init();
    defer base.deinit();
    base.setUnsignedWord(2);
    var exponent = gmp.BigInt.init();
    defer exponent.deinit();
    exponent.setUnsignedWord(160);
    var modulus = gmp.BigInt.init();
    defer modulus.deinit();
    modulus.setUnsignedWord(1_000_000_007);
    var reduced = gmp.BigInt.init();
    defer reduced.deinit();
    reduced.powm(&base, &exponent, &modulus);
    try report("2^160 mod p", try reduced.writeTo(&buffer, 10), "213932660");

    // Facade: rationals.
    var half = try gmp.Rational.parse("1/2", 10);
    defer half.deinit();
    var sixth = try gmp.Rational.parse("1/6", 10);
    defer sixth.deinit();
    var total = gmp.Rational.init();
    defer total.deinit();
    total.add(&half, &sixth);
    try report("1/2 + 1/6", try total.writeTo(&buffer, 10), "2/3");

    // Raw C API through the translated header, on a facade owned value. The
    // read-only operand goes through `rawSrcPtr`, which is the type `gmp.h`
    // itself declares for a value GMP only reads.
    var value = gmp.BigInt.init();
    defer value.deinit();
    gmp.c.mpz_set_ui(value.rawPtr(), 7);
    gmp.c.mpz_mul_ui(value.rawPtr(), value.rawSrcPtr(), 6);
    try report("raw 7 * 6", try value.writeTo(&buffer, 10), "42");

    // `mpz_out_str` takes a `FILE *`, and `gmp.h` only declares it when
    // <stdio.h> has already been seen, so this call is the proof that the
    // aggregate header really does translate the whole public header and not
    // only the part that is declared unconditionally. The stream is discarded.
    const scratch_file = gmp.c.tmpfile();
    if (scratch_file != null) {
        _ = gmp.c.mpz_out_str(scratch_file, 10, value.rawSrcPtr());
        _ = gmp.c.fclose(scratch_file);
    }

    std.debug.print("consumer checks passed\n", .{});
}
