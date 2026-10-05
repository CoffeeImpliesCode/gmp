//! Ownership and lifetime behaviour.
//!
//! GMP allocates its limb arrays and every string it hands out through its own
//! allocator (`gmp_allocate_func`, which defaults to `malloc`). No library
//! code installs allocator hooks, so correctness means two things:
//!
//!   * every value the facade owns is released exactly once through GMP's own
//!     `mpz_clear` / `mpq_clear` / `mpf_clear` / `gmp_randclear` path, and
//!   * strings allocated by GMP are released with GMP's own free function,
//!     never with a Zig allocator, and with the block's real size.
//!
//! Zig has no move, so exactly-once is the caller's rule and not the type's: a
//! copy made by assignment is a second name for one GMP allocation, and
//! releasing both names is a double free. `clone`, `div`, `divexact`, `mod`,
//! `numerator` and `denominator` are GMP's own copies into second allocations,
//! each with its own `deinit`.
//!
//! The tests below observe both by counting GMP allocations on this thread
//! through `alloc_probe.zig`, the one file in this tree that replaces GMP's
//! allocator, and it does so through the module's own published setter. That
//! matters in a runtime-loading build, where the free function it compares
//! against and the one the facade uses are both the provider's, reached through
//! the same table.

const std = @import("std");
const gmp = @import("gmp");
const probe = @import("alloc_probe.zig");
const bootstrap = @import("bootstrap.zig");

const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expect = std.testing.expect;

test "a BigInt lifecycle releases every GMP allocation" {
    try bootstrap.ensureLoaded();
    probe.enable();
    // Registered first, so it runs last: the values below are destroyed while
    // counting is still on.
    defer probe.disable();

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
    try expectEqual(@as(usize, 2), probe.liveAllocations());
}

test "an owning string result is freed with GMP's allocator and its real size" {
    try bootstrap.ensureLoaded();
    probe.enable();
    defer probe.disable();

    var value = gmp.BigInt.init();
    value.setUnsignedWord(1);
    value.shlAssign(1000);
    try expectEqual(@as(usize, 1), probe.liveAllocations());

    var buffer: [400]u8 = undefined;
    const expected = try value.writeTo(&buffer, 10);

    const owned = try value.toOwnedString(10);
    try expectEqual(@as(usize, 2), probe.liveAllocations());
    try expectEqualStrings(expected, owned.slice());

    // GMP's `free_function` is documented to receive the size of the block it
    // releases, and GMP releases its own allocated strings as `len + 1`; a
    // replaceable allocator may rely on that number, so the release must not
    // pass a placeholder such as 0. The probe compares what each release
    // claims against the size the block was allocated with.
    const mismatches_before = probe.freeSizeMismatches();
    owned.deinit();
    try expectEqual(mismatches_before, probe.freeSizeMismatches());
    try expectEqual(@as(usize, 1), probe.liveAllocations());

    value.deinit();
    try expectEqual(@as(usize, 0), probe.liveAllocations());
    try expectEqual(mismatches_before, probe.freeSizeMismatches());
}

test "an owned rational string is released with its real size too" {
    try bootstrap.ensureLoaded();
    probe.enable();
    defer probe.disable();

    // -355/113 is already canonical: 113 is prime and does not divide 355, so
    // `mpq_get_str` renders both parts with a slash between them.
    var value = try gmp.Rational.parse("-355/113", 10);
    defer value.deinit();

    // The parsed value already owns its limbs, so the string is counted
    // against that baseline instead of an absolute number.
    const baseline = probe.liveAllocations();
    const owned = try value.toOwnedString(10);
    try expectEqual(baseline + 1, probe.liveAllocations());
    try expectEqualStrings("-355/113", owned.slice());

    const mismatches_before = probe.freeSizeMismatches();
    owned.deinit();
    try expectEqual(mismatches_before, probe.freeSizeMismatches());
    try expectEqual(baseline, probe.liveAllocations());
}

test "a value can be moved and must be released once" {
    try bootstrap.ensureLoaded();
    probe.enable();
    defer probe.disable();

    var value = try gmp.BigInt.parse("-987654321987654321", 10);
    var buf: [24]u8 = undefined;
    try expectEqualStrings("-987654321987654321", try value.writeTo(&buf, 10));
    try expectEqual(@as(usize, 1), probe.liveAllocations());

    // Moving copies the `mpz_t` struct, which owns the limb array by pointer.
    // Exactly one of the two must be released, and it is the one the caller
    // keeps. The source binding must not be used afterwards.
    var moved = value;
    value = undefined;
    moved.deinit();

    try expectEqual(@as(usize, 0), probe.liveAllocations());
}

test "a cleared value can be initialised again" {
    try bootstrap.ensureLoaded();
    probe.enable();
    defer probe.disable();

    var value = gmp.BigInt.init();
    value.facUi(50);
    try expectEqual(@as(usize, 1), probe.liveAllocations());

    value.deinit();
    try expectEqual(@as(usize, 0), probe.liveAllocations());

    // `mpz_clear` leaves the struct reusable, which the raw escape hatch shows
    // directly: `gmp.c` is the translated GMP API.
    gmp.c.mpz_init(value.rawPtr());
    value.setUnsignedWord(7);
    var buf: [4]u8 = undefined;
    try expectEqualStrings("7", try value.writeTo(&buf, 10));
    value.deinit();
    try expectEqual(@as(usize, 0), probe.liveAllocations());
}

test "rational and float lifetimes are released too" {
    try bootstrap.ensureLoaded();
    probe.enable();
    defer probe.disable();

    {
        const before = probe.liveAllocations();
        var rational = try gmp.Rational.parse("6/8", 10);
        defer rational.deinit();
        // An `mpq` owns a limb array for the numerator and one for the
        // denominator, so the count to check is the delta, not a fixed number.
        try expectEqual(before + 2, probe.liveAllocations());
        rational.canonicalize();
    }
    try expectEqual(@as(usize, 0), probe.liveAllocations());

    {
        var value = gmp.Float.init(64);
        defer value.deinit();
        try value.setStr("2.5", 0);
        try expectEqual(@as(usize, 1), probe.liveAllocations());
    }
    try expectEqual(@as(usize, 0), probe.liveAllocations());
}

test "a random state owns one GMP block and gives it back whole" {
    try bootstrap.ensureLoaded();
    probe.enable();
    defer probe.disable();

    // A random state is not inline data. `gmp_randinit_mt` takes the whole
    // Mersenne Twister state in one block from GMP's allocator
    // (`rand/randmt.c:406`, `__gmp_randinit_mt_noseed`), so exactly one
    // allocation is live from the moment the state exists.
    var state = gmp.Rand.initMt();
    try expectEqual(@as(usize, 1), probe.liveAllocations());

    // Seeding is arithmetic, not storage: `randseed_mt` works in local `mpz`
    // temporaries it clears again (`rand/randmts.c:126-143`), and a draw only
    // reads the state, so neither adds to what stays live.
    state.seed(20_240_917);
    const first = try state.nextBits(32);
    const second = try state.nextBits(32);
    try expectEqual(@as(usize, 1), probe.liveAllocations());
    try expect(first != second);

    // `gmp_randclear` returns that block with the size it was taken with
    // (`rand/randmt.c:357-361`), so a release of a different size would be
    // recorded here.
    const mismatches_before = probe.freeSizeMismatches();
    state.deinit();
    try expectEqual(@as(usize, 0), probe.liveAllocations());
    try expectEqual(mismatches_before, probe.freeSizeMismatches());
}