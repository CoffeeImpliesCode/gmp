// SPDX-License-Identifier: LGPL-3.0-or-later

//! Loading the provider a runtime-loading test run was told to use.
//!
//! The test runner owns the test binary's entry point, so a test cannot read a
//! command line: the only place a run can say which `libgmp` to load is the
//! environment the binary inherits, which is `GMP_TEST_PROVIDER` (see
//! `zig/provider.zig`). Every test that touches GMP calls `ensureLoaded` first,
//! and it is idempotent: the loader answers a repeated
//! request with the same request successfully, so the forty-six calls this
//! binary makes cost one load and no state change.
//!
//! In a linked build the whole body compiles away. `runtime_loaded` is a
//! comptime constant, so neither the environment lookup nor `load` is
//! referenced there and a linked `zig build test` needs no provider at all.

const gmp = @import("gmp");

/// Load this process's GMP if this build resolves it at run time.
///
/// `error.NoProviderConfigured` means the run was told nothing, which is a
/// deliberate failure rather than a fallback: a test that silently used the
/// bundled linkage would not be testing the route its configuration claims.
pub fn ensureLoaded() !void {
    if (comptime gmp.runtime_loaded) {
        const path = try gmp.providerFromCEnvironment();
        try gmp.load(.{ .path = path });
    }
}
