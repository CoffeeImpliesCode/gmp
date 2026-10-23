//! Exercises the published GMP facade and translated C API in linked and runtime-loaded builds.

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

    // Runtime builds load the explicitly requested provider before any GMP call.
    if (comptime gmp.runtime_loaded) {
        try gmp.load(.{ .path = try gmp.providerRequest(init) });
    }

    std.debug.print("consumer: GMP {s}, {d}-bit limbs, {s} build\n", .{
        gmp.upstream_version,
        gmp.limb_bits,
        if (gmp.runtime_loaded) "runtime-loaded" else "linked",
    });

    // Report version and limb width from the loaded provider.
    std.debug.print("consumer: provider {s} ({d} bits per limb)\n", .{
        gmp.providerVersion(),
        gmp.providerBitsPerLimb().*,
    });

    var factorial = gmp.BigInt.init();
    defer factorial.deinit();
    factorial.facUi(20);
    try report("20!", try factorial.writeTo(&buffer, 10), "2432902008176640000");

    // Keep base, exponent, and modulus distinct for the `2^160 mod p` check.
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

    var half = try gmp.Rational.parse("1/2", 10);
    defer half.deinit();
    var sixth = try gmp.Rational.parse("1/6", 10);
    defer sixth.deinit();
    var total = gmp.Rational.init();
    defer total.deinit();
    total.add(&half, &sixth);
    try report("1/2 + 1/6", try total.writeTo(&buffer, 10), "2/3");

    // The raw read-only operand uses the const pointer type declared by `gmp.h`.
    var value = gmp.BigInt.init();
    defer value.deinit();
    gmp.c.mpz_set_ui(value.rawPtr(), 7);
    gmp.c.mpz_mul_ui(value.rawPtr(), value.rawSrcPtr(), 6);
    try report("raw 7 * 6", try value.writeTo(&buffer, 10), "42");

    // `mpz_out_str` confirms the aggregate translation includes its `FILE *` API.
    const scratch_file = gmp.c.tmpfile();
    if (scratch_file != null) {
        _ = gmp.c.mpz_out_str(scratch_file, 10, value.rawSrcPtr());
        _ = gmp.c.fclose(scratch_file);
    }

    // Provider-allocated memory must return through the provider's active free hook.
    const raw_text = gmp.c.mpz_get_str(null, 10, value.rawSrcPtr());
    if (raw_text == null) return error.ConsumerMismatch;
    const rendered = std.mem.span(raw_text);
    // Capture allocation size before freeing the provider-owned buffer.
    const block_size = rendered.len + 1;
    try report("native buffer", rendered, "42");
    gmp.freeNativeBlock(raw_text, block_size);

    const owned = try value.toOwnedString(10);
    defer owned.deinit();
    try report("owned buffer", owned.slice(), "42");

    std.debug.print("consumer checks passed\n", .{});
}
