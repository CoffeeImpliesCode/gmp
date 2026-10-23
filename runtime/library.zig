// SPDX-License-Identifier: LGPL-3.0-or-later
//! GMP-specific runtime-loader configuration.
//! Providers must match the translated symbol set and limb-width ABI.
//! Provider allocations must be released through that provider's active hooks.

const std = @import("std");
const rt = @import("rt");

/// Namespaced synchronization ABI for this loader.
/// Its prefix must match `runtime/sync.c`'s `RT_SYNC_PREFIX`.
pub const Sync = struct {
    extern fn gmp_rt_lock() void;
    extern fn gmp_rt_unlock() void;
    extern fn gmp_rt_wait() void;
    extern fn gmp_rt_broadcast() void;
    // C `unsigned long long` maps to `u64` on supported targets.
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

/// Binds the generic loader to this generated dispatch.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Used in pre-load panic messages.
        pub const library_name = "gmp";

        /// The generated table and required/optional symbol lists.
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

        /// Assigns or clears an optional field by `optional_symbols` index.
        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// Rejects providers whose limb width differs from this build's header.
        /// Runs after symbol resolution and before table publication.
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
