//! GMP parsers and renderers use different base ranges.
//! Base 0 is parser-specific; `mpf_set_str` also supports negative bases unavailable through `u8`.

/// Accept parsing bases 0 or 2..62; GMP defines the meaning of base 0 per parser.
pub fn validInputBase(base: u8) bool {
    return base == 0 or (base >= 2 and base <= 62);
}

/// Accept output bases 2..62.
pub fn validOutputBase(base: u8) bool {
    return base >= 2 and base <= 62;
}
