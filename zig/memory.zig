//! Memory helpers shared by the facade types.
//!
//! GMP has one allocator for the whole library, held in the global slots
//! `gmp_allocate_func`, `gmp_reallocate_func` and `gmp_free_func`, and
//! `mp_set_memory_functions` is the only thing that replaces them
//! (`doc/gmp.texi:7440-7450`). No built library code or facade method calls
//! the setter. The facade uses the provider's current hooks, which default to
//! `malloc` and matching reallocation/free functions. This fork's Zig tests
//! replace them through `zig/test/alloc_probe.zig`, which reaches the same
//! setter. Using a Zig allocator for GMP memory, or `free` for a Zig
//! allocation, would be a bug in both directions.
//!
//! Two consequences are worth stating where they bite. First, a program that
//! does replace the hooks changes the allocator for *every* value the facade
//! owns, before the replacement and after it, and GMP asks for that only while
//! no GMP object is live (`doc/gmp.texi:7448-7450`). Second, nothing here
//! reports an allocation failure: GMP's own functions may not return `NULL`
//! from an allocator (`doc/gmp.texi:7487-7490`) and the default one aborts
//! instead (`memory.c:53-58`), so a native GMP block is invisible to a Zig
//! leak oracle and an `error.OutOfMemory` in this package would promise a
//! recovery GMP cannot perform.
//!
//! ## Which GMP this asks
//!
//! Through `c`, which is the translated header in a linked build and the
//! generated dispatch in a runtime-loading one. The declaration reached here is
//! `__gmp_get_memory_functions`, the name the library really exports:
//! `gmp-h.in:490` renames the public spelling with `#define
//! mp_get_memory_functions __gmp_get_memory_functions`, and that macro is
//! expanded before the C is parsed, so the object file defines
//! `__gmp_get_memory_functions` and never `mp_get_memory_functions`.
//! Declaring the C spelling here would be an undefined symbol at link time, and
//! a hand-written declaration would be a *direct* extern: in a runtime-loading
//! build nothing links libgmp, so it would fail to link rather than reach the
//! table. One declaration, taken from `c`, is both correct in the two
//! configurations and the one that asks the provider rather than the linker.
//!
//! ## Why the out parameters are spelled the way they are
//!
//! `gmp.h:491-493` declares three parameters that are pointers *to pointers to
//! functions*, and `translate-c` renders a pointer to a function prototype as
//! the optional `?*const fn (...) callconv(.c) R` (`Translator.zig:1215-1237`),
//! which for a pointer to that pointer is `[*c]const ?*const fn (...)`. The
//! address of a local of that element type is a `*?*const fn (...)`, which
//! coerces to the parameter type without a cast, so the call below passes
//! `&free_func` unchanged. `size_t` is `usize` in `translate-c`'s output, and
//! `void *` is `?*anyopaque`, so the local below has the element type the
//! parameter declares.

const c = @import("c");

/// Release a block GMP allocated, of exactly `size` bytes.
///
/// GMP's `free_function` is documented as receiving a pointer that "is always a
/// previously allocated block of SIZE bytes", and `gmp-impl.h` releases a NUL
/// terminated string it allocated itself as `(*__gmp_free_func) (str, len+1)`.
/// A replaceable allocator may keep that size, so this passes the real block
/// size and never a placeholder such as 0. The free function read here is the
/// one installed right now, so a program that replaced the hooks must keep
/// replacing them for as long as it holds blocks allocated under the old ones.
///
/// This is not idempotent and the value is not cleared: a second call with the
/// same block and size is a double free, which is why every type that owns such
/// a block states the exactly-once rule at its own `deinit`.
///
/// In a runtime-loading build the free function read is the provider's, because
/// the call that reads it is itself routed. Freeing a block with anything else
/// would hand memory to an allocator that never owned it.
pub fn freeGmpMemory(ptr: [*c]u8, size: usize) void {
    var free_func: ?*const fn (?*anyopaque, usize) callconv(.c) void = null;
    c.__gmp_get_memory_functions(null, null, &free_func);
    // GMP's free slot is never null, so there is no condition to report here.
    // The three allocator slots start out pointing at the built-in functions
    // before `main` runs (`memory.c:37-39`), and a program that clears them
    // with `mp_set_memory_functions(NULL, NULL, NULL)` gets the built-in one
    // back rather than a null, because that setter substitutes
    // `__gmp_default_free` for a null argument (`mp_set_fns.c:39-48`,
    // `doc/gmp.texi:7441-7443`). The unwrap states that contract; there is no
    // other free function to fall back on, and inventing one would hide the
    // block from the allocator that owns it.
    const free_it = free_func.?;
    // GMP's `free_function` takes `void *`; the block is opaque bytes here, so
    // this is the child type widening and nothing else, made explicit.
    const block: *anyopaque = @ptrCast(ptr);
    free_it(block, size);
}

/// Replace GMP's allocator for the whole library.
///
/// This is `mp_set_memory_functions`. It is published as
/// `gmp.setMemoryFunctions` rather than kept private because a program that
/// wants to account for GMP's blocks has no other way to install hooks: they
/// are the library's own globals and this is the only setter it exports. It
/// changes the allocator for every other GMP value in the process, including
/// values this package owns, and GMP only sanctions that while none are live
/// (`doc/gmp.texi:7448-7450`), which is why nothing in this package calls it
/// and why the ownership tests restore the defaults afterwards.
///
/// A null argument selects GMP's built-in function for that slot
/// (`mp_set_fns.c:39-48`), which is how the probe puts the library back.
pub fn setGmpMemoryFunctions(
    allocate: ?*const fn (usize) callconv(.c) ?*anyopaque,
    reallocate: ?*const fn (?*anyopaque, usize, usize) callconv(.c) ?*anyopaque,
    free: ?*const fn (?*anyopaque, usize) callconv(.c) void,
) void {
    c.__gmp_set_memory_functions(allocate, reallocate, free);
}