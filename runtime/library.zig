// SPDX-License-Identifier: LGPL-3.0-or-later
//
//! GMP's side of the runtime loader: the names its synchronization binding
//! has, and what it requires of a provider beyond resolving its symbols.
//!
//! Everything else about the runtime route is generic. `runtime/loader.zig` is
//! the state machine and the platform layer; `runtime/generate.zig` builds the
//! dispatch from whatever the translation step actually produced;
//! `runtime/graph.zig` wires them together. This file is what makes them GMP's.
//!
//! ## What a provider must be
//!
//! Every symbol the generated `gmp.h` declares once its own macros are
//! expanded, which is 294 of them on a glibc target: the `__gmpz_*`,
//! `__gmpq_*`, `__gmpf_*` and `__gmpn_*` families, `__gmp_randinit_*` and
//! `__gmp_randclear`, `__gmp_set_memory_functions` and
//! `__gmp_get_memory_functions`, the `__gmp_printf` / `__gmp_fprintf` /
//! `__gmp_asprintf` / `__gmp_snprintf` / `__gmp_sprintf` / `__gmp_vasprintf` /
//! `__gmp_vprintf` / `__gmp_vfprintf` / `__gmp_vsnprintf` / `__gmp_vsprintf`
//! family and its `scanf` counterpart, and the three exported objects
//! `__gmp_version`, `__gmp_errno` and `__gmp_bits_per_limb`.
//!
//! The obstack pair, `__gmp_obstack_printf` and `__gmp_obstack_vprintf`, is
//! part of that set on a target with `<obstack.h>` and absent from it on a
//! target without. Both halves of that decision are the same decision: the
//! header declares them behind `#if defined (_OBSTACK_H)` and the library
//! compiles them behind `HAVE_OBSTACK_VPRINTF`, so a provider built from the
//! same configuration exports exactly what the header describes. See
//! `provider_optional` in `runtime/graph.zig`.
//!
//! ## The external ABI family
//!
//! C, and the platform's own calling convention for it. Every function pointer
//! the table holds has the type `translate-c` produced for that declaration,
//! which is `callconv(.c)` for each of the checked targets, so a routed call
//! goes out through exactly the pointer a C compiler would have used.
//! `size_t` arrives as `usize`, `unsigned long` as `c_ulong`, `long` as
//! `c_long`, `int` as `c_int` and `long double` as `c_longdouble`.
//!
//! The C library is the other external family, and it is *not* routed: the
//! dispatch keeps every `<stdio.h>` and `<stdarg.h>` declaration direct,
//! because those symbols are the C library's and a table lookup for a function
//! the program already links would add a load and an acquire to every stream
//! operation. The one consequence worth naming is that a provider is loaded
//! against a libc it did not necessarily build against; that is fine, because
//! nothing in GMP's own ABI crosses libc except through its own formatted
//! input and output entry points, which are routed and therefore reach the
//! provider.
//!
//! ## The scalar and layout facts that are not negotiable
//!
//!   * `mp_limb_t` is `unsigned long` where the target's `long` is at least 64
//!     bits and `unsigned long long int` where it is not, `mp_limb_signed_t`
//!     following it. The second arm is LLP64, where `unsigned long` is still 32
//!     bits: `gmp-h.in:137-145` selects the typedef behind `_LONG_LONG_LIMB`
//!     and `zig/config_gen.zig:224-230` sets that macro from the resolved
//!     target, so `x86_64-windows-gnu` gets `unsigned long long int`. Either
//!     way `GMP_LIMB_BITS` is 64 on a 64-bit target and 32 on a 32-bit one. A
//!     provider whose limb is a different typedef, or a different word size,
//!     lays `__mpz_struct`, `__mpq_struct` and `__mpf_struct` out differently
//!     and is not interchangeable: those three structs are passed by pointer
//!     across the boundary on every call.
//!   * `GMP_NAIL_BITS` is 0 here (`gmp.h:50`), so `mp_size_t` counts whole
//!     limbs and `mp_bitcnt_t` counts bits.
//!   * The long-double family in `<stdio.h>` differs between the four C
//!     libraries this SDK's matrix builds against (glibc routes it through
//!     `bits/stdio-ldbl.h` to `__printf__` and `__isoc99_*`, mingw through
//!     `__mingw_v*` and `__ms_v*`, musl through `__stdio_common_*`). All of
//!     them are in the direct set, and GMP adds no long-double entry point of
//!     its own, so this only decides how the program itself reaches libc.
//!   * `mpf_t` carries its precision in limbs of the *provider's* `mp_limb_t`,
//!     so `mpf_init2`'s bit count is converted by the provider and
//!     `mpf_get_prec` is reported back in the provider's limbs.
//!
//! ## The allocator, and what crossing it costs
//!
//! GMP allocates every limb array, every `mpz_get_str` result and every
//! random state through three function pointers the library owns:
//! `__gmp_allocate_func`, `__gmp_reallocate_func` and `__gmp_free_func`
//! (`memory.c:37-39`). They are internal globals: `gmp.h` declares only
//! `__gmp_set_memory_functions` and `__gmp_get_memory_functions`, and both are
//! routed. A program that replaces the hooks replaces them *in the provider*,
//! because the only setter it has is the provider's.
//!
//! That has one consequence a consumer must respect. A block the provider
//! allocated must be released through the provider's current free function with
//! the size it was allocated with (`gmp-impl.h` releases its own strings as
//! `(*__gmp_free_func)(str, len+1)`), and a program that swaps the hooks has to
//! keep swapping them for as long as it holds blocks taken under the old ones.
//! `gmp.freeNativeBlock` reads the installed free function through
//! `__gmp_get_memory_functions` for exactly that reason.
//!
//! ## What is checked at load time, and what is not
//!
//! The one check is limb width: the provider's `__gmp_bits_per_limb` must equal
//! the `GMP_LIMB_BITS` the translated header in this build was generated for.
//! That is a real ABI fact rather than a version string, it is the one that
//! decides whether the structs the two sides share have the same layout, and it
//! costs one load of a `const int` the provider has already initialised.
//!
//! Resolving the symbols and reading that word are the boundary. They are not
//! proof that a provider is otherwise interchangeable. Nothing here checks the
//! `mpn` backend or the tuning a provider was compiled with, because the
//! public ABI does not depend on either: the same entry points answer the same
//! questions whatever produced the arithmetic. What configuration does change
//! is the set of entry points, and that shows up two ways. A build whose
//! `GMP_LIMB_BITS` differs fails the check above, and a build whose header
//! declares a different set fails to resolve the ones it lacks, by name.

const std = @import("std");
const rt = @import("rt");

/// The synchronization this loader calls, bound by exact name.
///
/// The names below are `runtime/sync.h` compiled with `RT_SYNC_PREFIX=gmp_rt`,
/// which is what `runtime/graph.zig` passes. Two spellings of that prefix have
/// to agree: this file names the symbols, and graph.zig defines the macro. A
/// build where they disagree does not link, and that is the whole error report:
/// there is no runtime path that could hide it.
///
/// The core in `runtime/loader.zig` never names a symbol of its own, which is
/// what lets two SDKs, or two configurations of one SDK, hold their own loader
/// state in one process without sharing any of it.
pub const Sync = struct {
    extern fn gmp_rt_lock() void;
    extern fn gmp_rt_unlock() void;
    extern fn gmp_rt_wait() void;
    extern fn gmp_rt_broadcast() void;
    // `unsigned long long`. Declared as u64, which is the same type in every
    // ABI this SDK targets: 64-bit on x86_64, aarch64, riscv64 and wasm32.
    extern fn gmp_rt_thread_self() u64;

    pub fn lock() void {
        gmp_rt_lock();
    }
    pub fn unlock() void {
        gmp_rt_unlock();
    }
    pub fn wait() void {
        gmp_rt_wait();
    }
    pub fn broadcast() void {
        gmp_rt_broadcast();
    }
    pub fn threadSelf() u64 {
        return gmp_rt_thread_self();
    }
};

/// The loader's configuration for this SDK, given the dispatch that owns the
/// table.
///
/// `dispatch` is the generated module, passed as a type by the dispatch itself
/// so that this file never has to import it. The direction is one-way on
/// purpose: the descriptor knows what the loader needs, the dispatch knows what
/// the header said, and neither imports the other.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Named in the pre-load panic, so the message says which library was
        /// reached for before it was loaded.
        pub const library_name = "gmp";

        /// The table the generated dispatch declares, and the symbols it needs
        /// to fill it. Both come from the translated header, not from this file.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// The project's namespaced synchronization binding.
        pub const sync = Sync;

        pub fn tablePtr() *table {
            return dispatch.tablePtr();
        }

        pub fn ready() *rt.Ready {
            return &dispatch.ready;
        }

        pub fn assign(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assign(index, dst, address);
        }

        /// One resolved address into one optional table field, and the empty
        /// case beside it. Both index `optional_symbols`, not `symbols`.
        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// The one library-specific check, run after every symbol resolved and
        /// before anything is published.
        ///
        /// `GMP_LIMB_BITS` is a macro in the generated header, so the dispatch
        /// re-exports it and the expected width is whatever this build's own
        /// `gmp.h` says rather than a constant written here. The provider's
        /// `__gmp_bits_per_limb` is a `const int` it initialised at load time
        /// from the same macro, so reading it is a plain load of one word from
        /// a mapped object.
        pub fn validate(dst: *const table) ?[]const u8 {
            const expected = dispatch.GMP_LIMB_BITS;
            const actual = dst.__gmp_bits_per_limb.*;
            if (actual != expected) {
                return std.fmt.comptimePrint(
                    "libgmp's __gmp_bits_per_limb does not match the {d} this " ++
                        "build's gmp.h declares: the two sides disagree on the " ++
                        "layout of mpz_t, mpq_t and mpf_t, so they are not " ++
                        "interchangeable",
                    .{expected},
                );
            }
            return null;
        }
    };
}