// SPDX-License-Identifier: LGPL-3.0-or-later

//! Resolve an explicit provider path for runtime-loading builds.

const std = @import("std");

/// Environment variable that can name the provider.
pub const environment_variable = "GMP_TEST_PROVIDER";

/// Returned when neither command-line nor environment input names a provider.
pub const NoProviderConfigured = error{NoProviderConfigured};

/// Select `--provider` over `GMP_TEST_PROVIDER`; the returned slice borrows process inputs.
pub fn requestFromRun(init: std.process.Init) NoProviderConfigured![]const u8 {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena) catch return requestFromEnvironment(init);
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) {
            if (index + 1 >= args.len) return noProviderConfigured();
            return args[index + 1];
        }
    }
    return requestFromEnvironment(init);
}

/// Return a borrowed provider from `Init`'s environment map, or error if absent.
pub fn requestFromEnvironment(init: std.process.Init) NoProviderConfigured![]const u8 {
    return init.environ_map.get(environment_variable) orelse noProviderConfigured();
}

/// Return a borrowed C environment provider, or error if absent or empty.
pub fn requestFromCEnvironment() NoProviderConfigured![]const u8 {
    const value = std.c.getenv(environment_variable) orelse return noProviderConfigured();
    if (value[0] == 0) return noProviderConfigured();
    return std.mem.span(value);
}

fn noProviderConfigured() NoProviderConfigured {
    std.debug.print(
        "gmp: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export {s} with a shared libgmp that exports every entry point " ++
            "this build's gmp.h declares. Nothing is loaded by default and no " ++
            "other file is tried.\n",
        .{environment_variable},
    );
    return error.NoProviderConfigured;
}
