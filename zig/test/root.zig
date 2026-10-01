//! Test binary root.
//!
//! The behaviour tests live next to this file. They are pulled in here, and
//! the facade exercise is run as a test as well, so one binary covers both the
//! external expectations and the full public surface.

const std = @import("std");
const gmp = @import("gmp");

test {
    _ = @import("known_answers.zig");
    _ = @import("division.zig");
    _ = @import("parsing.zig");
    _ = @import("ownership.zig");
    _ = @import("rational_float_random.zig");
}

test "every public facade method is reachable and consistent" {
    try gmp.api_exercise.exercise();
}
