//! Consumer of the GMP package: uses only what the package publishes.
//!
//! The results are fixed mathematical facts, so the output is deterministic and
//! a wrong answer fails the run instead of printing silently.
//!
//! It works in both of the package's configurations. In a runtime-loading one
//! the provider is named on the command line (`--provider <path>`) or in
//! `GMP_TEST_PROVIDER`, and nothing else is tried; in a linked one the library
//! is already there and neither input is read.

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

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;

    // The one explicit step a runtime-loading build needs, and a no-op in a
    // linked one. No default path is searched and no fallback exists.
    if (comptime gmp.runtime_loaded) {
        try gmp.load(.{ .path = try gmp.providerRequest(init) });
    }

    std.debug.print("consumer: GMP {s}, {d}-bit limbs, {s} build\n", .{
        gmp.upstream_version,
        gmp.limb_bits,
        if (gmp.runtime_loaded) "runtime-loaded" else "linked",
    });

    // What the loaded library says about itself, read from its own data rather
    // than from this program's idea of it.
    std.debug.print("consumer: provider {s} ({d} bits per limb)\n", .{
        gmp.providerVersion(),
        gmp.providerBitsPerLimb().*,
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

    // A buffer GMP itself allocated, released through the package's own free
    // helper. `mpz_get_str` with a null buffer returns memory from GMP's own
    // allocator, and the free function that gives it back is the one GMP has
    // installed *now*, read through `__gmp_get_memory_functions`. In a
    // runtime-loading build both of those are the provider's, so this is a
    // complete round trip through the same library rather than a mixture.
    const raw_text = gmp.c.mpz_get_str(null, 10, value.rawSrcPtr());
    if (raw_text == null) return error.ConsumerMismatch;
    const rendered = std.mem.span(raw_text);
    // The size is read while the block is still alive; reading it after the
    // release would be reading freed memory.
    const block_size = rendered.len + 1;
    try report("native buffer", rendered, "42");
    gmp.freeNativeBlock(raw_text, block_size);

    // The same thing through the facade, which owns the block and releases it
    // in its own `deinit`.
    const owned = try value.toOwnedString(10);
    defer owned.deinit();
    try report("owned buffer", owned.slice(), "42");

    std.debug.print("consumer checks passed\n", .{});
}
