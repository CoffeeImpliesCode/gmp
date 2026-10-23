//! Owned GMP random state with word-oriented draws.
//! `nextBits` returns `[0, 2^n)`; `nextBelow` is uniform in `[0, n)`.

const c = @import("c");

/// What `Rand` refuses to pass to GMP.
pub const Error = error{
    /// `nextBits` exceeds the width of target `unsigned long`.
    TooManyBits,
    /// `nextBelow` received a zero bound.
    EmptyRange,
};

pub const Rand = struct {
    /// The underlying GMP state, exposed for raw C access.
    raw: c.gmp_randstate_t,

    /// Mutable GMP pointer borrowed from this state; it expires on release or move.
    pub fn rawPtr(self: *Rand) c.gmp_randstate_ptr {
        return &self.raw[0];
    }

    /// Read-only GMP pointer borrowed from this state; it expires on release or move.
    pub fn rawSrcPtr(self: *const Rand) c.gmp_randstate_srcptr {
        return &self.raw[0];
    }

    /// Create GMP's fixed-default Mersenne Twister state; seed before relying on unpredictability.
    pub fn initMt() Rand {
        var self: Rand = .{ .raw = undefined };
        c.gmp_randinit_mt(self.rawPtr());
        return self;
    }

    /// Create GMP's default generator state.
    pub fn initDefault() Rand {
        var self: Rand = .{ .raw = undefined };
        c.gmp_randinit_default(self.rawPtr());
        return self;
    }

    /// Release the GMP state; call once and do not use the value afterwards.
    pub fn deinit(self: *Rand) void {
        c.gmp_randclear(self.rawPtr());
    }

    /// Reseed from a target-width word; equal seeds reproduce the same stream.
    pub fn seed(self: *Rand, value: c_ulong) void {
        c.gmp_randseed_ui(self.rawPtr(), value);
    }

    /// Return `nbits` random bits in `[0, 2^nbits)`; zero is valid.
    /// Reject counts wider than `unsigned long` before GMP truncates them.
    pub fn nextBits(self: *Rand, nbits: c_ulong) Error!c_ulong {
        if (nbits > @bitSizeOf(c_ulong)) return error.TooManyBits;
        return c.gmp_urandomb_ui(self.rawPtr(), nbits);
    }

    /// Return a uniform value in `[0, n)`; reject zero before GMP's divide-by-zero abort.
    pub fn nextBelow(self: *Rand, n: c_ulong) Error!c_ulong {
        if (n == 0) return error.EmptyRange;
        return c.gmp_urandomm_ui(self.rawPtr(), n);
    }
};
