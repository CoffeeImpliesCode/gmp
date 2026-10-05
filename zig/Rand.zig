//! Owned random number state backed by GMP's `gmp_randstate_t`.
//!
//! GMP's public random interface is word oriented and already covers either
//! shape a caller wants, so nothing here adds a second algorithm on top of it:
//!
//!   * `gmp_urandomb_ui` returns `n` random bits, that is a value in
//!     `[0, 2^n)`, which is `nextBits`;
//!   * `gmp_urandomm_ui` returns a uniformly distributed value in `[0, n)` for
//!     any positive `n`, which is `nextBelow`.
//!
//! `rand/randmui.c` is that range mapping: it draws the bits that reach `n`,
//! rejects the values in the incomplete top block and retries, and returns 0
//! for `n == 1`. The manual states the result is `0` to `n-1` inclusive for an
//! arbitrary `n` (`doc/gmp.texi`).
//!
//! Both entry points take the conditions the manual states as ordinary
//! comparisons and report them as `error.TooManyBits` and `error.EmptyRange`.
//! Neither condition crashes GMP, so an assertion is not what a caller of this
//! facade should be handed; the errors name the argument that was rejected and
//! leave the state untouched.
//!
//! A `Rand` owns one `gmp_randstate_t`: `initMt` or `initDefault` produces it,
//! `deinit` releases it, once per initialisation. Zig has no move, so a copy
//! made by assignment is a second name for the same state and releasing both
//! is a double free. `seed` replaces the contents of the state rather than
//! replacing the state, so it costs nothing extra to release.

const c = @import("c");

/// What `Rand` refuses to pass to GMP.
pub const Error = error{
    /// `nextBits` was asked for more bits than the target's `unsigned long`
    /// can hold.
    TooManyBits,
    /// `nextBelow` was asked for a value in `[0, 0)`.
    EmptyRange,
};

pub const Rand = struct {
    /// The GMP state itself, for the raw escape hatch (`gmp.c`).
    ///
    /// The field is reachable, so it is not read only by convention: a write
    /// through `c` changes this state and `deinit` still releases what GMP
    /// allocated for it.
    raw: c.gmp_randstate_t,

    /// The state as GMP's mutable C pointer, `gmp_randstate_ptr`. GMP writes
    /// through this, so it is only available on a mutable value. The pointer
    /// lives inside the receiver: it does not outlive this state and does not
    /// survive a move.
    pub fn rawPtr(self: *Rand) c.gmp_randstate_ptr {
        return &self.raw[0];
    }

    /// The state as GMP's read-only C pointer, `gmp_randstate_srcptr`, which
    /// is what `gmp_randinit_set` reads. Like `rawPtr`, it points inside the
    /// receiver and does not outlive it.
    pub fn rawSrcPtr(self: *const Rand) c.gmp_randstate_srcptr {
        return &self.raw[0];
    }

    /// A state using the Mersenne Twister, `gmp_randinit_mt`.
    ///
    /// It starts at GMP's fixed Mersenne Twister default table
    /// (`rand/randmts.c:166-171`, `rand/randmt.c:410-414`), so the stream is
    /// reproducible rather than random until `seed` is called. The facade draws
    /// no entropy of its own and adds no seed source; GMP's own seeding note is
    /// that the method for choosing a seed is critical where the numbers matter,
    /// for instance when generating cryptographic keys
    /// (`doc/gmp.texi:6153-6158`).
    pub fn initMt() Rand {
        var self: Rand = .{ .raw = undefined };
        c.gmp_randinit_mt(self.rawPtr());
        return self;
    }

    /// A state using GMP's default generator, which is `gmp_randinit_mt` at
    /// this pin (`rand/randdef.c:33-37`) and is unseeded in the same way.
    pub fn initDefault() Rand {
        var self: Rand = .{ .raw = undefined };
        c.gmp_randinit_default(self.rawPtr());
        return self;
    }

    /// Release the state, `gmp_randclear`.
    ///
    /// The value is unusable afterwards and a second call is a double free.
    /// One initialisation is one `deinit`: a copy made by assignment is a
    /// second name for this same state and must not be released.
    pub fn deinit(self: *Rand) void {
        c.gmp_randclear(self.rawPtr());
    }

    /// Reseed the generator from a machine word, GMP's `gmp_randseed_ui`.
    ///
    /// GMP expands the word into the whole state, so the same seed always
    /// reproduces the same sequence, and a different seed reproduces a
    /// different one. The word is the target's `unsigned long`, so a seed
    /// above 2^32 only fits where that word is 64 bits; GMP's own note is
    /// that the seed's quality decides the quality of the sequences and that
    /// the system clock is a poor source (`doc/gmp.texi:6153-6166`).
    pub fn seed(self: *Rand, value: c_ulong) void {
        c.gmp_randseed_ui(self.rawPtr(), value);
    }

    /// `nbits` random bits, GMP's `gmp_urandomb_ui`.
    ///
    /// The result is uniform in `[0, 2^nbits)`. The manual's condition is that
    /// `nbits` is at most the width of an `unsigned long`, and GMP does not
    /// enforce it: `rand/randbui.c` calls `_gmp_rand` with
    /// `MIN (bits, BITS_PER_ULONG)`, so a wider count is quietly truncated to a
    /// full word of bits. That is a wrong answer rather than a crash, so it is
    /// rejected here with `error.TooManyBits` instead of being accepted.
    /// `nbits == 0` is legal and returns 0, which is what that function does:
    /// it starts from a zero limb and stores no bits
    /// (`rand/randbui.c:42-49`). It also leaves the stream where it was, since
    /// a zero bit request runs no loop in the generator.
    pub fn nextBits(self: *Rand, nbits: c_ulong) Error!c_ulong {
        if (nbits > @bitSizeOf(c_ulong)) return error.TooManyBits;
        return c.gmp_urandomb_ui(self.rawPtr(), nbits);
    }

    /// A uniform value in `[0, n)`, GMP's `gmp_urandomm_ui`.
    ///
    /// Any positive `n` is valid, power of two or not: GMP draws the bits that
    /// reach `n`, rejects the values in the incomplete top block and retries,
    /// so the result is uniform without a second algorithm here. `n == 1`
    /// returns 0 and draws nothing to do so, because the bit count for a bound
    /// of one is zero (`rand/randmui.c:64`) and the generator is not asked for
    /// bits. `n == 0` is rejected with `error.EmptyRange`, because
    /// `rand/randmui.c` answers it with GMP's own `DIVIDE_BY_ZERO`, which
    /// aborts the process rather than returning an error.
    pub fn nextBelow(self: *Rand, n: c_ulong) Error!c_ulong {
        if (n == 0) return error.EmptyRange;
        return c.gmp_urandomm_ui(self.rawPtr(), n);
    }
};
