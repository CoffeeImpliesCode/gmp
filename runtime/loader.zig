// SPDX-License-Identifier: LGPL-3.0-or-later
//! Generic process-wide loader for a generated dispatch table.
//! It publishes only fully resolved tables, retains successful handles, and never unloads.

const std = @import("std");
const builtin = @import("builtin");

/// Selects a library path or platform-loader name; there is no fallback between them.
pub const LoadSource = union(enum) {
    /// Absolute file path; relative paths are rejected.
    path: []const u8,
    /// Basename or SONAME for the platform loader; path separators and NUL are rejected.
    system: []const u8,
};

/// Errors returned when `load` declines a request.
pub const LoadError = error{
    /// The path or name is empty.
    EmptySource,
    /// The request exceeds `max_source_len`; it is refused, not truncated.
    SourceTooLong,
    /// The path is not absolute, the name has a path component, or the request contains NUL.
    InvalidSource,
    /// The target has no dynamic library loader.
    UnsupportedTarget,
    /// The platform loader could not open the object or a dependency.
    OpenFailed,
    /// Library-specific validation rejected the resolved provider.
    MissingSymbol,
    ValidationFailed,
    /// A different provider is already loaded or loading.
    ProviderMismatch,
    /// The thread already running a load attempt called `load` again.
    ReentrantLoad,
};

/// Maximum accepted request length, in bytes.
pub const max_source_len = 32768;

/// Fixed-size copy of a request retained for idempotence; no allocation is needed.
const SourceRecord = struct {
    tag: enum(u8) { none = 0, path, system } = .none,
    len: u32 = 0,
    bytes: [max_source_len]u8 = undefined,

    /// Records the request after its length is checked, while holding the loader lock.
    fn set(self: *SourceRecord, request: LoadSource) void {
        const text = switch (request) {
            .path => |p| p,
            .system => |s| s,
        };
        @memcpy(self.bytes[0..text.len], text);
        self.len = @intCast(text.len);
        self.tag = switch (request) {
            .path => .path,
            .system => .system,
        };
    }

    /// Returns this record's retained request, whose slice remains valid for its lifetime.
    pub fn source(self: *const SourceRecord) ?LoadSource {
        const text = self.bytes[0..self.len];
        return switch (self.tag) {
            .none => null,
            .path => .{ .path = text },
            .system => .{ .system = text },
        };
    }
};

/// Compares request kind and bytes without normalization.
pub fn eqlSource(a: LoadSource, b: LoadSource) bool {
    return switch (a) {
        .path => |pa| switch (b) {
            .path => |pb| std.mem.eql(u8, pa, pb),
            .system => false,
        },
        .system => |sa| switch (b) {
            .system => |sb| std.mem.eql(u8, sa, sb),
            .path => false,
        },
    };
}

fn validateSource(source: LoadSource) LoadError!void {
    const text = switch (source) {
        .path => |p| p,
        .system => |s| s,
    };
    if (text.len == 0) return error.EmptySource;
    if (text.len > max_source_len) return error.SourceTooLong;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSource;
    switch (source) {
        .path => {
            const absolute = if (builtin.os.tag == .windows)
                switch (std.fs.path.getWin32PathType(u8, text)) {
                    .drive_absolute, .unc_absolute, .local_device, .root_local_device => true,
                    .relative, .rooted, .drive_relative => false,
                }
            else
                std.fs.path.isAbsolutePosix(text);
            if (!absolute) return error.InvalidSource;
        },
        .system => {
            for (text) |byte| {
                if (std.fs.path.isSep(byte)) return error.InvalidSource;
                if (builtin.os.tag == .windows and byte == ':') return error.InvalidSource;
            }
        },
    }
}

/// Lifecycle states for one configured dispatch.
pub const Phase = enum(u8) {
    /// No successful load; a later call may retry.
    not_loaded = 0,
    /// A thread is resolving and validating a candidate.
    loading = 1,
    ready = 2,
};

/// Release-published after table fill; routed calls acquire-load before reading it.
pub const Ready = struct {
    phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.not_loaded)),

    /// Checks readiness with acquire ordering.
    pub fn isReady(self: *const Ready) bool {
        return self.phase.load(.acquire) == @intFromEnum(Phase.ready);
    }

    /// Returns the current phase with acquire ordering.
    pub fn state(self: *const Ready) Phase {
        return @enumFromInt(self.phase.load(.acquire));
    }

    /// Publishes or withdraws the table with release ordering.
    pub fn set(self: *Ready, value: Phase) void {
        self.phase.store(@intFromEnum(value), .release);
    }
};

/// Type of provider-owned export stored in a dispatch table.
pub const SymbolKind = enum {
    /// Function pointer with the translated C signature.
    function,
    /// Address of provider-owned data, never a copy.
    data,
};

/// Required provider export name and kind.
pub const Symbol = struct {
    /// Exported name exactly as the C header declares it.
    name: [:0]const u8,
    kind: SymbolKind,
};

/// Panics with the library and symbol when a routed call occurs before loading.
pub fn panicNotReady(library: []const u8, comptime symbol: []const u8) noreturn {
    std.debug.panic(
        "{s}: {s} was called before this module was loaded; call " ++
            "load({{ .path = \"...\" }}) or load({{ .system = \"...\" }}) first",
        .{ library, symbol },
    );
}

/// Whether this target supports dynamic loading; false for WASI, Emscripten, and freestanding.
pub const supported_target: bool = switch (builtin.os.tag) {
    .wasi, .emscripten, .freestanding => false,
    else => true,
};

/// Process-global loader that publishes only complete tables and retains successful handles.
/// Identical concurrent requests share an attempt; different providers fail, and retries are explicit.
pub fn Loader(comptime Config: type) type {
    return struct {
        const LoaderType = @This();

        /// Table type filled by this loader.
        pub const table_type = Config.table;

        /// Active or undrained attempt; waiters keep it alive after completion.
        attempt: ?Attempt = null,

        /// Request copy, guarded by the loader lock until the table is published.
        request: SourceRecord = .{},

        /// Loads a provider, sharing an identical in-flight request and refusing a different one.
        /// Failure publishes nothing and requires a later explicit retry.
        pub fn load(self: *LoaderType, source: LoadSource) LoadError!void {
            try validateSource(source);
            // The ready fast path compares an already published request without taking the lock.
            if (Config.ready().isReady()) return self.accept(source);

            Config.sync.lock();
            while (true) {
                switch (Config.ready().state()) {
                    .ready => {
                        Config.sync.unlock();
                        return self.accept(source);
                    },
                    .loading => {
                        const attempt = &self.attempt.?;
                        if (attempt.owner == Config.sync.threadSelf()) {
                            Config.sync.unlock();
                            return error.ReentrantLoad;
                        }
                        if (!eqlSource(self.request.source().?, source)) {
                            Config.sync.unlock();
                            return error.ProviderMismatch;
                        }
                        // Join the same attempt and return its result.
                        attempt.waiters += 1;
                        while (Config.ready().state() == .loading) Config.sync.wait();
                        const result = attempt.result;
                        attempt.waiters -= 1;
                        // Waiters drain before the attempt record can be cleared for retry.
                        Config.sync.broadcast();
                        Config.sync.unlock();
                        return result;
                    },
                    .not_loaded => {
                        // A completed attempt remains until its waiters have drained.
                        if (self.attempt != null) {
                            Config.sync.wait();
                            continue;
                        }
                        break;
                    },
                }
            }

            self.request.set(source);
            self.attempt = .{ .owner = Config.sync.threadSelf() };
            Config.ready().set(.loading);
            Config.sync.unlock();

            // Open outside the lock so provider constructors cannot block other loader state.
            const outcome = runAttempt(self.request.source().?);
            const succeeded = if (outcome) |_| true else |_| false;

            Config.sync.lock();
            self.attempt.?.result = outcome;
            Config.ready().set(if (succeeded) .ready else .not_loaded);
            // Wake all waiters; each must take this result before the attempt can be cleared.
            Config.sync.broadcast();
            // Release the lock while waiters drain.
            while (self.attempt.?.waiters > 0) Config.sync.wait();
            self.attempt = null;
            // Wake threads waiting to start a retry.
            Config.sync.broadcast();
            Config.sync.unlock();

            return outcome;
        }

        /// Returns the successful request retained for process life, or null.
        pub fn loadedSource(self: *const LoaderType) ?LoadSource {
            if (!Config.ready().isReady()) return null;
            return self.request.source();
        }

        /// Rejects a request different from the published one.
        fn accept(self: *const LoaderType, source: LoadSource) LoadError!void {
            // Called only after readiness was acquire-loaded.
            const published = self.request.source() orelse unreachable;
            if (eqlSource(published, source)) return;
            return error.ProviderMismatch;
        }

        /// Resolves and validates a candidate without holding the loader lock.
        /// Closes the candidate on every failure path.
        fn runAttempt(source: LoadSource) LoadError!void {
            const handle = platform.open(source) catch |err| return err;

            var retain = false;
            defer if (!retain) platform.close(handle);

            if (@hasDecl(Config, "optional_symbols")) {
                inline for (Config.optional_symbols, 0..) |_, index| {
                    Config.assignMissing(index, Config.tablePtr());
                }
            }

            inline for (Config.symbols, 0..) |symbol, index| {
                const address = platform.lookup(handle, symbol.name) orelse
                    return error.MissingSymbol;
                Config.assign(index, Config.tablePtr(), address);
            }

            if (@hasDecl(Config, "optional_symbols")) {
                inline for (Config.optional_symbols, 0..) |symbol, index| {
                    if (platform.lookup(handle, symbol.name)) |address| {
                        Config.assignOptional(index, Config.tablePtr(), address);
                    }
                }
            }

            if (@hasDecl(Config, "validate")) {
                if (Config.validate(Config.tablePtr())) |refusal| {
                    // Preserve the library-specific refusal reason.
                    std.debug.print("{s}: refusing this provider: {s}\n", .{
                        Config.library_name,
                        refusal,
                    });
                    return error.ValidationFailed;
                }
            }

            // Retain the successful handle for the table's process-long lifetime.
            retain = true;
        }
    };
}

/// One active or undrained load attempt.
const Attempt = struct {
    /// Thread identity used to detect reentrant loads.
    owner: u64,
    /// Result, written under the loader lock before waiters are released.
    result: LoadError!void = error.OpenFailed,
    /// Waiters keep this record alive until they take the result.
    waiters: usize = 0,
};

/// UTF-16 buffer bound for Windows path conversion.
const windows_path_units = 32768;

const platform = if (builtin.os.tag == .windows)
    Windows
else if (supported_target)
    Unix
else
    NoLoader;

/// Loader backend for targets without dynamic loading.
const NoLoader = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget };

    fn open(source: LoadSource) OpenError!*anyopaque {
        _ = source;
        return error.UnsupportedTarget;
    }
    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        _ = handle;
        _ = name;
        return null;
    }
    fn close(handle: *anyopaque) void {
        _ = handle;
    }
};

/// Unix `dlopen` backend.
const Unix = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget };

    fn open(source: LoadSource) OpenError!*anyopaque {
        const text = switch (source) {
            .path => |p| p,
            .system => |s| s,
        };
        var buffer: [max_source_len + 1]u8 = undefined;
        @memcpy(buffer[0..text.len], text);
        buffer[text.len] = 0;
        // NOW reports missing dependencies at open; LOCAL avoids cross-SDK symbol lookup.
        return std.c.dlopen(
            // `dlopen` requires a sentinel-terminated filename.
            buffer[0..text.len :0].ptr,
            .{ .NOW = true, .GLOBAL = false },
        ) orelse error.OpenFailed;
    }

    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        return std.c.dlsym(handle, name.ptr);
    }

    fn close(handle: *anyopaque) void {
        _ = std.c.dlclose(handle);
    }
};

const kernel32 = struct {
    extern "kernel32" fn LoadLibraryExW(
        file_name: [*:0]const u16,
        file: ?*anyopaque,
        flags: u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) i32;
};

/// Windows `LoadLibraryExW` backend.
const Windows = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget, SourceTooLong };

    /// Search standard DLL directories without adding the current directory.
    const load_library_search_default_dirs: u32 = 0x0000_1000;
    const load_library_search_dll_load_dir: u32 = 0x0000_0100;

    fn open(source: LoadSource) OpenError!*anyopaque {
        const text = switch (source) {
            .path => |p| p,
            .system => |s| s,
        };
        if (text.len > windows_path_units) return error.SourceTooLong;
        var buffer: [windows_path_units + 1]u16 = undefined;
        const units = std.unicode.utf8ToUtf16Le(buffer[0..text.len], text) catch
            return error.OpenFailed;
        buffer[units] = 0;
        return kernel32.LoadLibraryExW(
            buffer[0..units :0],
            null,
            load_library_search_default_dirs | switch (source) {
                .path => load_library_search_dll_load_dir,
                .system => @as(u32, 0),
            },
        ) orelse error.OpenFailed;
    }

    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        return kernel32.GetProcAddress(handle, name.ptr);
    }

    fn close(handle: *anyopaque) void {
        _ = kernel32.FreeLibrary(handle);
    }
};
