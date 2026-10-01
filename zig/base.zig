//! The two different base ranges GMP has, kept apart on purpose.
//!
//! GMP does not use one base convention, and merging the two is a bug:
//!
//!   * The parsing entry points, `mpz_set_str`, `mpq_set_str` and
//!     `mpf_set_str`, accept base 0 to mean "detect the base from the `0x`,
//!     `0b` or leading `0` prefix", exactly as the C library's `strtoul` family
//!     does. Zero is a real input base.
//!   * The rendering entry points do not accept it. `mpz_sizeinbase`, which is
//!     what sizes a caller's buffer, is documented for base 2 to 62 and asserts
//!     `base >= 2` in `MPN_SIZEINBASE` (`gmp-impl.h`); with the assertion
//!     compiled out, base 0 takes the `POW2_P` branch and divides by
//!     `mp_bases[0].big_base`, which `gen-bases.c` emits as 0.
//!
//! So rendering takes 2 to 62 and reports `error.InvalidBase` for anything
//! else, rather than quietly reading a 0 as a 10 the way `mpz_get_str` itself
//! does, because the digit count that sizes the buffer cannot be asked for in
//! base 0 at all.

/// A base `mpz_set_str`, `mpq_set_str` or `mpf_set_str` accepts: 0 to detect,
/// or 2 to 62.
pub fn validInputBase(base: u8) bool {
    return base == 0 or (base >= 2 and base <= 62);
}

/// A base `mpz_sizeinbase`, `mpz_get_str`, `mpq_get_str` and `mpf_get_str`
/// accept: 2 to 62.
pub fn validOutputBase(base: u8) bool {
    return base >= 2 and base <= 62;
}
