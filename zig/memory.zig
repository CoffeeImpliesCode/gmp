//! Memory helpers shared by the facade types.
//!
//! GMP has its own allocator, replaceable by the program through
//! `mp_set_memory_functions`. Nothing in this package replaces it, so GMP keeps
//! using `malloc` and everything GMP allocates is released through GMP's own
//! free function. Using a Zig allocator for GMP memory, or `free` for a Zig
//! allocation, would be a bug in both directions.

/// GMP's `mp_get_memory_functions`, declared under the name the library really
/// exports.
///
/// `gmp-h.in:485` renames it with `#define mp_get_memory_functions
/// __gmp_get_memory_functions`, and that macro is expanded before the C is
/// parsed, so the object file defines `__gmp_get_memory_functions` and never
/// `mp_get_memory_functions`. Declaring the C spelling here would be an
/// undefined symbol at link time; the exported name is declared instead, with
/// GMP's own signature, unchanged.
///
/// It is spelled out here rather than taken from the translated header
/// (`c.__gmp_get_memory_functions`, which that macro also aliases) for a second
/// reason: its three parameters are *out* parameters, and `translate-c` renders
/// a pointer to a function prototype as the optional
/// `?*const fn (...) callconv(.c) void` (`Translator.zig:1215-1237`). The address
/// of a local of that type is a `*?*const fn (...)`, a different Zig type from
/// the parameter even though the two have the same representation, so the out
/// parameter is declared here as the exact pointer to the optional and the call
/// passes `&free_func` unchanged. `c` is kept out of this file so the one
/// declaration and its one caller are the whole story.
extern fn __gmp_get_memory_functions(
    get: ?*const fn (usize) callconv(.c) ?*anyopaque,
    realloc: ?*const fn (?*anyopaque, usize, usize) callconv(.c) ?*anyopaque,
    free: *?*const fn (?*anyopaque, usize) callconv(.c) void,
) void;

/// Release a block GMP allocated, of exactly `size` bytes.
///
/// GMP's `free_function` is documented as receiving a pointer that "is always a
/// previously allocated block of SIZE bytes", and `gmp-impl.h` releases a NUL
/// terminated string it allocated itself as `(*__gmp_free_func) (str, len+1)`.
/// A replaceable allocator may keep that size, so this passes the real block
/// size and never a placeholder such as 0.
///
/// `size_t` is `usize` in `translate-c`'s output, which is what the free
/// function pointer above is declared with.
pub fn freeGmpMemory(ptr: [*c]u8, size: usize) void {
    var free_func: ?*const fn (?*anyopaque, usize) callconv(.c) void = null;
    __gmp_get_memory_functions(null, null, &free_func);
    // GMP's free slot is never null, so there is no condition to report here.
    // The three allocator slots start out pointing at the built-in functions
    // before `main` runs (`memory.c:37-39`), and a program that clears them
    // with `mp_set_memory_functions(NULL, NULL, NULL)` gets the built-in one
    // back rather than a null, because that setter substitutes
    // `__gmp_default_free` for a null argument (`mp_set_fns.c:39-48`,
    // `doc/gmp.texi:7441-7443`). The unwrap states that contract; there is no
    // other free function to fall back to, and inventing one would hide the
    // block from the allocator that owns it.
    const free_it = free_func.?;
    // GMP's `free_function` takes `void *`; the block is opaque bytes here, so
    // this is the child type widening and nothing else, made explicit.
    const block: *anyopaque = @ptrCast(ptr);
    free_it(block, size);
}
