// SPDX-License-Identifier: LGPL-3.0-or-later

//! Naming the provider a run has to load.
//!
//! In a runtime-loading build nothing in this package works until `load` has
//! been called, and `load` is told which library to open. This file is the one
//! place that decision is read from a run's own inputs, so the example, the
//! tests and the consumer package all answer it the same way.
//!
//! Two inputs are accepted and nothing else is:
//!
//!   * `--provider <path>` on the command line, and
//!   * the `GMP_TEST_PROVIDER` environment variable.
//!
//! There is no default location, no search path and no fallback from one form
//! to the other. A runtime-loading build that was not told which file to load
//! reports that it was not told, rather than loading whatever happens to be
//! installed: a smoke run that quietly used the bundled linkage would prove
//! nothing about the runtime route.
//!
//! A linked build never asks. `runtime_loaded` is a comptime constant, so the
//! calls below compile away there and neither input is read.

const std = @import("std");

/// The environment variable a run may name its provider in.
pub const environment_variable = "GMP_TEST_PROVIDER";

/// What a run does when it was told nothing.
///
/// A distinct error rather than a load failure, because nothing was attempted:
/// the answer belongs in the command line or the environment, not in the
/// loader.
pub const NoProviderConfigured = error{NoProviderConfigured};

/// The provider this run should load, from `--provider` or from the
/// environment.
///
/// The command line wins when both are given, because a run that passes one
/// explicitly has already decided. The returned slice borrows the argument
/// vector or the environment block, both of which outlive the call.
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

/// The provider this run should load, from the environment alone.
///
/// This is the form a program with no `main` of its own uses, a test binary in
/// particular: the test runner owns that entry point, so the only place a test
/// can be told which provider to load is the environment it inherits.
pub fn requestFromEnvironment(init: std.process.Init) NoProviderConfigured![]const u8 {
    return init.environ_map.get(environment_variable) orelse noProviderConfigured();
}

/// The provider a program with no `main` should load, read from the process
/// environment through the C library.
///
/// `std.c.getenv` rather than anything from `std.process`, because that API is
/// built around an `Init` this function has no way to receive. It is the C
/// library's own lookup, which is exactly the environment a program loaded
/// through the platform loader is running in.
pub fn requestFromCEnvironment() NoProviderConfigured![]const u8 {
    const value = std.c.getenv(environment_variable) orelse return noProviderConfigured();
    if (value[0] == 0) return noProviderConfigured();
    return std.mem.span(value);
}

/// Say which variable is missing and stop.
///
/// An error name on its own would send the next person into the loader instead
/// of to the command line.
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