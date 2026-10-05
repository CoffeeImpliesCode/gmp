//! The two different base ranges GMP has, kept apart on purpose.
//!
//! GMP does not use one base convention, and merging the two is a bug:
//!
//!   * `mpz_set_str` and `mpq_set_str` accept base 0 to mean "detect the base
//!     from the leading characters", `0x`/`0X`, `0b`/`0B` or a leading `0`
//!     (`doc/gmp.texi:3164-3166`, `doc/gmp.texi:4413-4418`,
//!     `mpz/set_str.c:80-100`). Zero is a real input base there.
//!   * `mpf_set_str` accepts base 0 as well and reads it as base 10, with no
//!     look at the leading characters at all (`mpf/set_str.c:153-155`). The
//!     manual gives the reason, so that a number like `0.23` is not read as
//!     octal (`doc/gmp.texi:4877-4879`). The same zero therefore carries two
//!     different meanings, and which one applies is the call site's to know.
//!   * The rendering entry points do not accept 0. `mpz_sizeinbase`, which is
//!     what sizes a caller's buffer, is documented for base 2 to 62 and asserts
//!     `base >= 2` in `MPN_SIZEINBASE` (`gmp-impl.h`); with the assertion
//!     compiled out, base 0 takes the `POW2_P` branch and divides by
//!     `mp_bases[0].big_base`, which `gen-bases.c` emits as 0.
//!
//! So rendering takes 2 to 62 and reports `error.InvalidBase` for anything
//! else, rather than quietly reading a 0 as a 10 the way `mpz_get_str` itself
//! does, because the digit count that sizes the buffer cannot be asked for in
//! base 0 at all.
//!
//! `mpf_set_str` alone also takes a negative base, -62 to -2, meaning that the
//! mantissa is in `base` while the exponent is in decimal
//! (`doc/gmp.texi:4869-4871`, `mpf/set_str.c:159-163`). A `u8` parameter
//! cannot express a negative value, so that feature is reachable through
//! `c.mpf_set_str` only; GMP's other two parsers reject a negative base
//! outright.

/// A base the parsing entry points accept: 0, or 2 to 62.
///
/// Zero is passed through, not interpreted. It means prefix detection to
/// `mpz_set_str` and `mpq_set_str` and base 10 to `mpf_set_str`; see this
/// file's own note. A negative base, which `mpf_set_str` accepts, cannot be
/// written in a `u8`.
pub fn validInputBase(base: u8) bool {
    return base == 0 or (base >= 2 and base <= 62);
}

/// A base `mpz_sizeinbase`, `mpz_get_str`, `mpq_get_str` and `mpf_get_str`
/// accept: 2 to 62.
pub fn validOutputBase(base: u8) bool {
    return base >= 2 and base <= 62;
}
