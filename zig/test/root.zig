//! Test binary root.
//!
//! The behaviour tests live next to this file. They are pulled in here, and
//! the facade exercise is run as a test as well, so one binary covers both the
//! external expectations and the full public surface.

const std = @import("std");
const gmp = @import("gmp");
const bootstrap = @import("bootstrap.zig");

test {
    _ = @import("known_answers.zig");
    _ = @import("division.zig");
    _ = @import("parsing.zig");
    _ = @import("ownership.zig");
    _ = @import("rational_float_random.zig");
}

test "every public facade method produces its known answer" {
    try bootstrap.ensureLoaded();
    try gmp.api_exercise.exercise();
}

test "translated obstack declarations follow the target libc" {
    comptime {
        const has_obstack = @import("builtin").target.isGnuLibC();
        if (@hasDecl(gmp.c, "__gmp_obstack_printf") != has_obstack or
            @hasDecl(gmp.c, "__gmp_obstack_vprintf") != has_obstack)
        {
            @compileError("GMP obstack declarations must match the target libc");
        }
        if (has_obstack) {
            _ = gmp.c.struct_obstack;
            _ = @TypeOf(gmp.c.__gmp_obstack_printf);
            _ = @TypeOf(gmp.c.__gmp_obstack_vprintf);
        }
    }
}
