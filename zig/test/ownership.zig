//! Ownership and lifetime behaviour.
//!
//! GMP allocates its limb arrays and every string it hands out through its own
//! allocator (`gmp_allocate_func`, which defaults to `malloc`). This package
//! never installs allocator hooks, so correctness means two things:
//!
//!   * every value the facade owns is released exactly once through GMP's own
//!     `mpz_clear` / `mpq_clear` / `mpf_clear` path, and
//!   * strings allocated by GMP are released with GMP's own free function,
//!     never with a Zig allocator.
//!
//! The tests below observe both by counting GMP allocations on this thread
//! through `alloc_probe.c`, which is linked into the test binary only.

const std = @import("std");
const gmp = @import("gmp");

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expect = std.testing.expect;

extern fn gmp_probe_enable() void;
extern fn gmp_probe_disable() void;
extern fn gmp_probe_live_allocations() c_ulong;
extern fn gmp_probe_free_size_mismatches() c_ulong;

test "a BigInt lifecycle releases every GMP allocation" {
    gmp_probe_enable();
    // Registered first, so it runs last: the values below are destroyed while
    // counting is still on.
    defer gmp_probe_disable();

    var value = try gmp.BigInt.parse("123456789012345678901234567890", 10);
    defer value.deinit();

    var scratch = gmp.BigInt.init();
    defer scratch.deinit();

    // Rendering into the caller's own buffer borrows it: no allocation, no
    // copy, and the text is the value that was parsed.
    var buffer: [64]u8 = undefined;
    try expectEqualStrings("123456789012345678901234567890", try value.writeTo(&buffer, 10));

    // Force GMP to allocate, grow and shrink limb buffers several times.
    scratch.facUi(500);
    value.mul(&scratch, &scratch);
    value.shlAssign(1000);
    value.addUi(1);
    value.gcdAssign(&scratch);

    // What is still live is exactly the two BigInts above, so the rendering
    // left nothing behind.
    try expectEqual(@as(c_ulong, 2), gmp_probe_live_allocations());
}

test "an owning string result is freed with GMP's allocator and its real size" {
    gmp_probe_enable();
    defer gmp_probe_disable();

    var value = gmp.BigInt.init();
    value.setUnsignedWord(1);
    value.shlAssign(1000);
    try expectEqual(@as(c_ulong, 1), gmp_probe_live_allocations());

    var buffer: [400]u8 = undefined;
    const expected = try value.writeTo(&buffer, 10);

    const owned = try value.toOwnedString(10);
    try expectEqual(@as(c_ulong, 2), gmp_probe_live_allocations());
    try expectEqualStrings(expected, owned.slice());

    // GMP's `free_function` is documented to receive the size of the block it
    // releases, and GMP releases its own allocated strings as `len + 1`; a
    // replaceable allocator may rely on that number, so the release must not
    // pass a placeholder such as 0. The probe compares what each release
    // claims against the size the block was allocated with.
    const mismatches_before = gmp_probe_free_size_mismatches();
    owned.deinit();
    try expectEqual(mismatches_before, gmp_probe_free_size_mismatches());
    try expectEqual(@as(c_ulong, 1), gmp_probe_live_allocations());

    value.deinit();
    try expectEqual(@as(c_ulong, 0), gmp_probe_live_allocations());
    try expectEqual(mismatches_before, gmp_probe_free_size_mismatches());
}

test "an owned rational string is released with its real size too" {
    gmp_probe_enable();
    defer gmp_probe_disable();

    // -355/113 is already canonical: 113 is prime and does not divide 355, so
    // `mpq_get_str` renders both parts with a slash between them.
    var value = try gmp.Rational.parse("-355/113", 10);
    defer value.deinit();

    // The parsed value already owns its limbs, so the string is counted
    // against that baseline instead of an absolute number.
    const baseline = gmp_probe_live_allocations();
    const owned = try value.toOwnedString(10);
    try expectEqual(baseline + 1, gmp_probe_live_allocations());
    try expectEqualStrings("-355/113", owned.slice());

    const mismatches_before = gmp_probe_free_size_mismatches();
    owned.deinit();
    try expectEqual(mismatches_before, gmp_probe_free_size_mismatches());
    try expectEqual(baseline, gmp_probe_live_allocations());
}

test "a value can be moved and must be released once" {
    gmp_probe_enable();
    defer gmp_probe_disable();

    var value = try gmp.BigInt.parse("-987654321987654321", 10);
    var buf: [24]u8 = undefined;
    try expectEqualStrings("-987654321987654321", try value.writeTo(&buf, 10));
    try expectEqual(@as(c_ulong, 1), gmp_probe_live_allocations());

    // Moving copies the `mpz_t` struct, which owns the limb array by pointer.
    // Exactly one of the two must be released, and it is the one the caller
    // keeps. The source binding must not be used afterwards.
    var moved = value;
    value = undefined;
    moved.deinit();

    try expectEqual(@as(c_ulong, 0), gmp_probe_live_allocations());
}

test "a cleared value can be initialised again" {
    gmp_probe_enable();
    defer gmp_probe_disable();

    var value = gmp.BigInt.init();
    value.facUi(50);
    try expectEqual(@as(c_ulong, 1), gmp_probe_live_allocations());

    value.deinit();
    try expectEqual(@as(c_ulong, 0), gmp_probe_live_allocations());

    // `mpz_clear` leaves the struct reusable, which the raw escape hatch shows
    // directly: `gmp.c` is the translated GMP API.
    gmp.c.mpz_init(value.rawPtr());
    value.setUnsignedWord(7);
    var buf: [4]u8 = undefined;
    try expectEqualStrings("7", try value.writeTo(&buf, 10));
    value.deinit();
    try expectEqual(@as(c_ulong, 0), gmp_probe_live_allocations());
}

test "rational and float lifetimes are released too" {
    gmp_probe_enable();
    defer gmp_probe_disable();

    {
        const before = gmp_probe_live_allocations();
        var rational = try gmp.Rational.parse("6/8", 10);
        defer rational.deinit();
        // An `mpq` owns a limb array for the numerator and one for the
        // denominator, so the count to check is the delta, not a fixed number.
        try expectEqual(before + 2, gmp_probe_live_allocations());
        rational.canonicalize();
    }
    try expectEqual(@as(c_ulong, 0), gmp_probe_live_allocations());

    {
        var value = gmp.Float.init(64);
        defer value.deinit();
        try value.setStr("2.5", 0);
        try expectEqual(@as(c_ulong, 1), gmp_probe_live_allocations());
    }
    try expectEqual(@as(c_ulong, 0), gmp_probe_live_allocations());
}

test "a random state owns one GMP block and gives it back whole" {
    gmp_probe_enable();
    defer gmp_probe_disable();

    // A random state is not inline data. `gmp_randinit_mt` takes the whole
    // Mersenne Twister state in one block from GMP's allocator
    // (`rand/randmt.c:406`, `__gmp_randinit_mt_noseed`), so exactly one
    // allocation is live from the moment the state exists.
    var state = gmp.Rand.initMt();
    try expectEqual(@as(c_ulong, 1), gmp_probe_live_allocations());

    // Seeding is arithmetic, not storage: `randseed_mt` works in local `mpz`
    // temporaries it clears again (`rand/randmts.c:126-143`), and a draw only
    // reads the state, so neither adds to what stays live.
    state.seed(20_240_917);
    const first = try state.nextBits(32);
    const second = try state.nextBits(32);
    try expectEqual(@as(c_ulong, 1), gmp_probe_live_allocations());
    try expect(first != second);

    // `gmp_randclear` returns that block with the size it was taken with
    // (`rand/randmt.c:357-361`), so a release of a different size would be
    // recorded here.
    const mismatches_before = gmp_probe_free_size_mismatches();
    state.deinit();
    try expectEqual(@as(c_ulong, 0), gmp_probe_live_allocations());
    try expectEqual(mismatches_before, gmp_probe_free_size_mismatches());
}
