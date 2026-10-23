//! Zig package root for the GMP 6.3.0 fork: the real GNU Multiple Precision
//! Arithmetic Library, built from the complete source tree with the portable C
//! backend (`NO_ASM`, mpn path `generic`), and published two ways.
//!
//!   * `dep.artifact("gmp")` is the static `libgmp` this tree builds, with the
//!     generated `gmp.h` in its include tree, for a C or `translate-c`
//!     dependent. `dep.module("gmp")` is the same library, linked, plus:
//!     * `gmp.c` — the complete translated GMP API, stdio and `va_list`
//!       functions included, which is the escape hatch for anything the
//!       facade does not cover;
//!     * `gmp.BigInt`, `gmp.Rational`, `gmp.Float` and `gmp.Rand` — owned Zig
//!       types with explicit `deinit`;
//!     * `gmp.DivisionMode`, `gmp.Division`, `gmp.OwnedString`,
//!       `gmp.ParseError`, `gmp.FormatError` — the facade's public result and
//!       error types;
//!     * `gmp.version`, `gmp.versionString`, `gmp.upstream_version` and
//!       `gmp.limb_bits`.
//!   * `zig build -fsys=gmp` links an installed GMP instead of compiling this
//!     tree, and the translated declarations then come from the installed
//!     `gmp.h`. See README.zig.md.
//!
//! What this module deliberately does not do: no library code here installs
//! allocator hooks, so GMP's own allocator stays in force; it does not run an
//! install step, so a dependent that wants headers on disk has a C build this
//! package does not perform; and GMP 6.3 has neither `mpf_const_pi` nor
//! `mpf_set_inf`, so there is no constant or special-value setter here. MPFR
//! is the separate package that provides a pi constant and an explicit
//! rounding mode.
//!
//! The shortest sequence that uses it, from a dependent package's `build.zig`:
//!
//! ```zig
//! const gmp_dep = b.dependency("gmp", .{ .target = target, .optimize = optimize });
//! module.addImport("gmp", gmp_dep.module("gmp"));
//! ```
//!
//! and from Zig source:
//!
//! ```zig
//! const std = @import("std");
//! const gmp = @import("gmp");
//!
//! pub fn main() !void {
//!     var value = try gmp.BigInt.parse("123456789012345678901234567890", 10);
//!     defer value.deinit();
//!     var buffer: [64]u8 = undefined;
//!     std.debug.print("{s}\n", .{try value.writeTo(&buffer, 10)});
//! }
//! ```
//!
//! Memory follows GMP: values are allocated by GMP's own allocator and freed
//! by `mpz_clear`, `mpq_clear` or `mpf_clear`, and a random state by
//! `gmp_randclear`. Those hooks are library-global, so a program that replaces
//! them through `c.__gmp_set_memory_functions` changes the allocator for every
//! value this package owns.
//!
//! Every `init` and every `parse` produces one owned value and every one of
//! them has exactly one `deinit`. Zig has no move, so a copy made by
//! assignment is a second name for one GMP allocation and releasing both is a
//! double free.
//!
//! Text crosses into GMP the way GMP reads it: `parse` and `setStr` take a
//! sentinel terminated `[:0]const u8` and hand the pointer straight over, and
//! `writeTo` returns the caller's own buffer as one, so rendered text can be
//! parsed again without a copy in between. Base 0 does not mean the same thing
//! at every call site: `mpz_set_str` and `mpq_set_str` read it as prefix
//! detection, `mpf_set_str` as base 10.
//!
//! ## Two configurations: linked and runtime-loaded
//!
//! This module is built in one of two shapes, and `runtime_loaded` says which
//! at comptime.
//!
//! *Linked* is the default. The C library is linked, `c` is the translated
//! header, and every call below is a direct C call: no table, no readiness
//! check, no cost added to arithmetic.
//!
//! *Runtime-loaded* is opt-in. The library is not linked; `c` is a dispatch
//! generated from the same translation step's output, and the entry points
//! `gmp.h` declares are resolved through the platform loader when the caller
//! calls
//!
//! ```zig
//! try gmp.load(.{ .path = "/usr/lib/libgmp.so.10" });
//! ```
//!
//! before using anything else. A call before that stops the program with a
//! message naming the function, in every optimization mode: that is a
//! programming error rather than a recoverable condition, because the table
//! does not exist yet and there is no partial state to fall back on.
//!
//! The provider is reached, never guessed. `.path` names a file and `.system`
//! names a library for the platform loader; neither falls back to the other,
//! there is no unload and no reset, and the handle and a copy of the request
//! live to the end of the process. `providerRequest` reads which file a run
//! should load from `--provider` or from `GMP_TEST_PROVIDER`, and nothing else
//! is tried.
//!
//! What a provider must be, and what is checked about it, is stated in
//! `runtime/library.zig`. The short form: every symbol this build's `gmp.h`
//! declares, compiled for a matching `GMP_LIMB_BITS`, reached through the
//! platform's C calling convention. The one load-time check is that limb width,
//! because it decides the layout of `mpz_t`, `mpq_t` and `mpf_t`.
//!
//! Exported data is reached the same way as functions, one guarded accessor
//! per object: `providerVersion`, `providerErrno` and `providerBitsPerLimb`
//! below are the provider's own `__gmp_version`, `__gmp_errno` and
//! `__gmp_bits_per_limb`, read where they live rather than copied into this
//! module at compile time.
//!
//! See README.zig.md for what the portable backend costs.

const std = @import("std");

/// The loader core, which is where a linked build's two public types come from.
///
/// Imported only by the linked configuration. In a runtime-loading build the
/// dispatch carries the same two declarations and this reference is comptime
/// dead, so the module is never analyzed and never compiled. Either way there
/// is exactly one `LoadSource` and one `LoadError` in a build, which is what
/// keeps them one type for a consumer that names them.
const rt = @import("rt");

const provider = @import("zig/provider.zig");
const memory = @import("zig/memory.zig");

/// The complete translated GMP API.
pub const c = @import("c");

/// Whether this module resolves its native symbols at run time.
///
/// False for the ordinary build, where the C library is linked and `c` is the
/// translated header itself. True when the build generated a dispatch that
/// resolves the same symbols through the platform loader, in which case `load`
/// is the one call that makes the library usable.
///
/// A comptime constant, so a consumer can write both code paths and have only
/// the one it chose analyzed.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Which native library `load` should open.
///
/// `.path` is an explicit file path and `.system` is an explicit name for the
/// platform loader. There is no path-to-system fallback and no implicit
/// fallback of any kind; a request that cannot be honoured is an error, not a
/// different library.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Every way `load` can decline.
///
/// Declared here, in the module a consumer imports, rather than only inside the
/// loader: the caller names the failure it is handling.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the native library this module dispatches to.
///
/// In a runtime-loading build this is the whole contract: call it once, then
/// use this module as if it were linked. Calling it again with the same request
/// succeeds and changes nothing; calling it with a different request after a
/// success is `ProviderMismatch`, and the library already in use stays in use.
/// A failed attempt publishes nothing and can be retried explicitly, by calling
/// this again: there is no automatic retry and no implicit second source.
///
/// Safe to call from any thread. A thread that arrives while an attempt for the
/// same request is in flight waits for that attempt and gets its result,
/// whatever it was. A call from the thread running the attempt is
/// `ReentrantLoad` rather than a deadlock.
///
/// In a linked build there is no provider, no table and nothing to resolve, so
/// this stops the program with a message saying so instead of quietly
/// succeeding. `runtime_loaded` is false there, so a consumer that supports
/// both configurations tells them apart at comptime instead of meeting this at
/// run time.
pub fn load(source: LoadSource) LoadError!void {
    if (runtime_loaded) return c.load(source);
    std.debug.panic(
        "gmp: load was called on a linked build; this module is not " ++
            "runtime-loaded, so there is no library to load. Build with runtime " ++
            "loading configured, or do not call load.",
        .{},
    );
}

/// The request that succeeded, or null when nothing has loaded yet.
///
/// The loader's own retained copy, valid for the life of the process. Null in a
/// linked build, which has no request.
pub fn loadedSource() ?LoadSource {
    if (runtime_loaded) return c.loadedSource();
    return null;
}

/// The provider a run should load, from `--provider <path>` or from
/// `GMP_TEST_PROVIDER`.
///
/// Only meaningful in a runtime-loading build, and only used by a program that
/// has to load one. Nothing is inferred from the file system and no other input
/// is consulted; see `zig/provider.zig`.
pub const providerRequest = provider.requestFromRun;

/// The same choice for a program with no `main` of its own, which is what a
/// test binary needs: it reads the environment and nothing else.
pub const providerFromCEnvironment = provider.requestFromCEnvironment;

/// What the two functions above return when a run was told nothing.
pub const NoProviderConfigured = provider.NoProviderConfigured;

/// The version string the GMP this build is talking to reports for itself.
///
/// This is the provider's own `__gmp_version`, read where it lives, and it is
/// not the same thing as `upstream_version` or `version`: those two come from
/// the macros in `gmp.h`, which say what this build was *compiled against*,
/// while this says what the library *says it is*. In a linked build they are
/// the same string, and in a runtime-loading build this is how a consumer sees
/// which file it actually loaded.
///
/// The slice borrows the provider's string constant, which lives as long as
/// the provider does.
pub fn providerVersion() [:0]const u8 {
    if (runtime_loaded) return std.mem.span(c.__gmp_versionAddr().*);
    return std.mem.span(c.__gmp_version);
}

/// Where the provider's `__gmp_errno` is.
///
/// `gmp.h` declares it writable and the C library's `errno` is per-thread, so
/// this is a pointer rather than a value on purpose: copying the number out
/// would be a snapshot of one instant, and writing to a copy would write
/// nowhere. The pointer is `const` because the dispatch's data accessor hands
/// out the object's address rather than taking a writable alias of it; a
/// program that wants to set the value calls GMP's own entry points.
pub fn providerErrno() *const c_int {
    if (runtime_loaded) return c.__gmp_errnoAddr();
    return &c.__gmp_errno;
}

/// Where the provider's `__gmp_bits_per_limb` is.
///
/// This is the number the load-time check in `runtime/library.zig` compared
/// against the header's `GMP_LIMB_BITS`, exposed because it is the fact a
/// program embedding GMP needs when it wants to know what it is working with.
pub fn providerBitsPerLimb() *const c_int {
    if (runtime_loaded) return c.__gmp_bits_per_limbAddr();
    return &c.__gmp_bits_per_limb;
}

/// The facade files, taken whole: each wraps its type and its supporting
/// declarations in one file, and `@import` of a path yields that file's own
/// namespace rather than the type it declares.
const bigint = @import("zig/BigInt.zig");
const rational = @import("zig/Rational.zig");
const float = @import("zig/Float.zig");
const rand = @import("zig/Rand.zig");

/// Owned integer, GMP `mpz_t`.
pub const BigInt = bigint.BigInt;

/// Owned rational number, GMP `mpq_t`.
pub const Rational = rational.Rational;

/// Owned binary floating point number, GMP `mpf_t`.
pub const Float = float.Float;

/// Owned random state, GMP `gmp_randstate_t`.
pub const Rand = rand.Rand;

/// GMP version this package was built from, as encoded in the generated
/// `gmp.h` (`__GNU_MP_VERSION` and friends).
pub const version = .{
    .major = c.__GNU_MP_VERSION,
    .minor = c.__GNU_MP_VERSION_MINOR,
    .patchlevel = c.__GNU_MP_VERSION_PATCHLEVEL,
};

/// Upstream release this fork tracks.
pub const upstream_version = "6.3.0";

/// Bits per limb of the generated `gmp.h`, which is ABI critical: 64 on every
/// 64-bit target including LLP64 Windows, 32 on 32-bit pointer targets.
pub const limb_bits = c.GMP_LIMB_BITS;

/// Render the GMP version of the generated header, for diagnostics.
///
/// Returns `error.NoSpaceLeft` when `buffer` is too short, in which case
/// `buffer` holds as much of the version as fitted and must be discarded. The
/// result borrows `buffer`.
pub fn versionString(buffer: []u8) ![]u8 {
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}", .{ version.major, version.minor, version.patchlevel });
}

/// Division rounding modes, re-exported for convenience.
pub const DivisionMode = bigint.DivisionMode;

/// Result of `BigInt.div`, both parts owned by the caller.
pub const Division = bigint.Division;

/// A NUL terminated string allocated by GMP, released with `deinit`.
pub const OwnedString = BigInt.OwnedString;

/// Errors from parsing.
pub const ParseError = bigint.ParseError;

/// Errors from rendering into caller owned storage.
pub const FormatError = bigint.FormatError;

/// Release a block GMP allocated, of exactly `size` bytes.
///
/// The counterpart of GMP's own allocator, reachable through this module so a
/// consumer never has to spell `__gmp_get_memory_functions` and its four
/// out-parameter types itself. In a runtime-loading build this asks the
/// provider that allocated the block, which is the only one that may free it.
pub const freeNativeBlock = memory.freeGmpMemory;

/// Replace GMP's allocator for the whole library.
///
/// This is GMP's `mp_set_memory_functions` and it is process-global: the hooks
/// it installs are the ones every later allocation by this library uses, and
/// a block taken under one pair must be released under that same pair. GMP
/// sanctions a change only while no GMP object is live
/// (`doc/gmp.texi:7448-7450`), which is why nothing in this package calls it
/// and why the ownership tests, which do, restore the defaults afterwards.
/// A null argument selects GMP's built-in function for that slot.
///
/// In a runtime-loading build this asks the provider: the three hooks are the
/// provider's own globals, and the only setter a program has is the one the
/// provider exports.
pub const setMemoryFunctions = memory.setGmpMemoryFunctions;

/// Compile-time and run-time exercise of every public facade method.
///
/// `zig build check` compiles this for every supported target so the whole
/// facade is instantiated; `zig build test` also runs it natively.
pub const api_exercise = @import("zig/api_exercise.zig");

test {
    @import("std").testing.refAllDeclsRecursive(@This());
}
