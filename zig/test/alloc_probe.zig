// SPDX-License-Identifier: LGPL-3.0-or-later

//! Installing GMP's allocator hooks for the ownership tests, and nothing else.
//!
//! The accounting itself is `alloc_probe.c`, linked into the test binary by the
//! build. This file is the seam between it and the library, and the seam is
//! here for one reason: GMP's `mp_set_memory_functions` has to be called on
//! whichever GMP this build is talking to. A C file could only reach it through
//! a link-time symbol, which works where libgmp is linked and cannot work at all
//! where it is not, because in a runtime-loading build the symbols arrive
//! through the generated dispatch when `load` runs.
//!
//! So the hooks are installed from Zig, through the package's own published
//! setter, and they are taken out the same way. Everything else about the
//! probe, including the thread-local counters and the size checks, is the C
//! file's.

const gmp = @import("gmp");

extern fn gmp_probe_alloc(size: usize) callconv(.c) ?*anyopaque;
extern fn gmp_probe_realloc(ptr: ?*anyopaque, old_size: usize, new_size: usize) callconv(.c) ?*anyopaque;
extern fn gmp_probe_free(ptr: ?*anyopaque, size: usize) callconv(.c) void;
extern fn gmp_probe_reset() void;
extern fn gmp_probe_stop() void;
extern fn gmp_probe_live_allocations() c_ulong;
extern fn gmp_probe_free_size_mismatches() c_ulong;

/// Start counting GMP's blocks on this thread, through the probe's hooks.
///
/// The counters are reset first, so a second test starts from a known state
/// even though the hooks are process-global.
pub fn enable() void {
    gmp.setMemoryFunctions(gmp_probe_alloc, gmp_probe_realloc, gmp_probe_free);
    gmp_probe_reset();
}

/// Stop counting and put GMP's own allocator back.
///
/// A null argument selects GMP's built-in function for each slot
/// (`mp_set_fns.c:39-48`), which is how the probe gets out of the way entirely
/// rather than leaving the accounting installed behind it.
pub fn disable() void {
    gmp_probe_stop();
    gmp.setMemoryFunctions(null, null, null);
}

/// Number of live GMP blocks this thread holds since `enable`.
pub fn liveAllocations() usize {
    return @intCast(gmp_probe_live_allocations());
}

/// Number of releases since `enable` that reported a size other than the one
/// their block was allocated with.
pub fn freeSizeMismatches() usize {
    return @intCast(gmp_probe_free_size_mismatches());
}