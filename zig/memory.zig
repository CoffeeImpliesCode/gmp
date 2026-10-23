//! GMP allocator helpers shared by facade types.
//! Free GMP-owned blocks through the current provider hooks, with their exact sizes.
//! Replace the global hooks only while no GMP objects are live.

const c = @import("c");

/// Release a GMP block through the current provider's free hook, with its exact size.
/// Call once and keep the allocating hooks installed until all their blocks are freed.
pub fn freeGmpMemory(ptr: [*c]u8, size: usize) void {
    var free_func: ?*const fn (?*anyopaque, usize) callconv(.c) void = null;
    c.__gmp_get_memory_functions(null, null, &free_func);
    // GMP replaces null hooks with its default functions, so the free slot is non-null.
    const free_it = free_func.?;
    const block: *anyopaque = @ptrCast(ptr);
    free_it(block, size);
}

/// Replace GMP's process-wide allocator hooks; do this only when no GMP objects are live.
/// Null slots restore GMP's defaults; changing hooks affects every GMP value.
pub fn setGmpMemoryFunctions(
    allocate: ?*const fn (usize) callconv(.c) ?*anyopaque,
    reallocate: ?*const fn (?*anyopaque, usize, usize) callconv(.c) ?*anyopaque,
    free: ?*const fn (?*anyopaque, usize) callconv(.c) void,
) void {
    c.__gmp_set_memory_functions(allocate, reallocate, free);
}
