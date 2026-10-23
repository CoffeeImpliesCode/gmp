//! Derive GMP's generated headers and pkg-config metadata from a Zig target.
//! ABI macros follow the resolved target rather than the build host.

// SPDX-License-Identifier: LGPL-3.0-or-later
const std = @import("std");

/// Target values used to render GMP's generated headers.
pub const Params = struct {
    /// Number of value bits per GMP limb.
    limb_bits: u16,
    /// Unused top bits in a limb; this backend uses none.
    nail_bits: u16 = 0,
    /// Target `unsigned long` size; LLP64 differs from pointer width.
    sizeof_unsigned_long: u16,
    /// GMP limb type size.
    sizeof_mp_limb_t: u16,
    /// Target pointer size.
    sizeof_void_p: u16,
    /// Use `unsigned long long` limbs on LLP64.
    long_long_limb: bool,
    /// Target byte order.
    big_endian: bool,
    /// Whether `<alloca.h>` exists; Clang uses its builtin `alloca` branch.
    have_alloca_h: bool,
    /// Whether `long double` is usable by GMP's formatted output.
    have_long_double: bool,
    /// Whether the target has `langinfo.h` and `nl_langinfo`.
    have_langinfo: bool,
    /// Whether target `sys/types.h` declares `quad_t` for GMP's `%q` handling.
    have_quad_t: bool,
    /// Whether the target libc provides `obstack_vprintf`.
    have_obstack_vprintf: bool,
    /// Enable GMP's internal assertions in Debug.
    want_assert: bool,
    /// Enable Windows DLL import/export decoration.
    libgmp_dll: bool,

    pub fn formatLong(self: Params, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{self.sizeof_unsigned_long}) catch unreachable;
    }

    pub fn formatLimb(self: Params, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{self.sizeof_mp_limb_t}) catch unreachable;
    }

    pub fn formatVoidPtr(self: Params, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{self.sizeof_void_p}) catch unreachable;
    }

    pub fn formatLimbBits(self: Params, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{self.limb_bits}) catch unreachable;
    }

    pub fn formatNailBits(self: Params, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}", .{self.nail_bits}) catch unreachable;
    }
};

/// Return pointer width for supported target architectures.
/// Unknown architectures panic rather than use an ABI-based guess.
pub fn pointerBits(arch: std.Target.Cpu.Arch) u16 {
    return switch (arch) {
        .x86_64,
        .aarch64,
        .aarch64_be,
        .powerpc64,
        .powerpc64le,
        .riscv64,
        .riscv64be,
        .s390x,
        .mips64,
        .mips64el,
        .loongarch64,
        .sparc64,
        .amdgcn,
        .wasm64,
        => 64,

        .wasm32,
        .x86,
        .arm,
        .armeb,
        .thumb,
        .thumbeb,
        .riscv32,
        .riscv32be,
        .powerpc,
        .powerpcle,
        .mips,
        .mipsel,
        .sparc,
        .loongarch32,
        .m68k,
        .csky,
        .sh,
        .sheb,
        .or1k,
        .xtensa,
        .xtensaeb,
        .nvptx,
        .bpfel,
        .bpfeb,
        // ARCompact and ARCv2 are 32-bit in both byte orders.
        .arc,
        .arceb,
        => 32,

        else => @panic("gmp: unsupported architecture; add its pointer width to zig/config_gen.zig"),
    };
}

/// Return the target `unsigned long` width for its ABI.
fn unsignedLongBits(target: std.Target, ptr_bits: u16) u16 {
    return switch (target.abi) {
        // Microsoft ABIs use 32-bit `long` regardless of pointer width.
        .msvc => 32,
        // x32 ABIs retain 64-bit `long` with 32-bit pointers.
        .gnux32, .muslx32 => 64,
        // Windows GNU targets follow the Microsoft 32-bit `long` ABI.
        else => if (target.os.tag == .windows) 32 else ptr_bits,
    };
}

/// Whether this target provides the glibc-specific obstack interface.
fn obstackVprintfAvailable(target: std.Target) bool {
    if (target.os.tag != .linux) return false;
    return switch (target.abi) {
        // Include x32 explicitly; it is glibc despite its distinct ABI tag.
        .gnu, .gnux32 => true,
        else => false,
    };
}

/// Derive GMP configuration from target, optimize mode, and DLL artifact kind.
pub fn paramsFor(
    target: std.Target,
    optimize: std.lang.Optimize,
    libgmp_dll: bool,
) Params {
    const ptr_bits = pointerBits(target.cpu.arch);
    const long_bits = unsignedLongBits(target, ptr_bits);

    // GMP uses 64-bit limbs where possible, then native 32-bit limbs.
    const limb_bits: u16 = if (long_bits >= 64)
        64
    else if (ptr_bits >= 64)
        64
    else
        32;
    const long_long_limb = long_bits < 64 and ptr_bits >= 64;

    const is_wasm = target.cpu.arch == .wasm32;

    return .{
        .limb_bits = limb_bits,
        .nail_bits = 0,
        .sizeof_unsigned_long = long_bits / 8,
        .sizeof_mp_limb_t = limb_bits / 8,
        .sizeof_void_p = ptr_bits / 8,
        .long_long_limb = long_long_limb,
        .big_endian = target.cpu.arch.endian() == .big,
        .have_alloca_h = target.os.tag != .macos and target.os.tag != .ios,
        // Avoid wasm32's 128-bit `long double` path in libc `printf`.
        .have_long_double = !is_wasm,
        // MinGW has no `<langinfo.h>` and uses `localeconv` instead.
        .have_langinfo = target.os.tag != .windows,
        // MinGW does not declare `quad_t`.
        .have_quad_t = target.os.tag != .windows,
        // Only glibc provides the selected obstack interface.
        .have_obstack_vprintf = obstackVprintfAvailable(target),
        .want_assert = optimize == .debug,
        .libgmp_dll = libgmp_dll and target.os.tag == .windows,
    };
}

const Macro = struct { name: []const u8, value: []const u8 };

/// GMP version shared by the generated header and pkg-config metadata.
pub const package_version = "6.3.0";

/// Shared macros; define only true flags because GMP often tests with `#ifdef`.
/// `NO_ASM` must be defined to disable GMP's inline assembly.
const common_macros = [_]Macro{
    .{ .name = "NO_ASM", .value = "1" },

    .{ .name = "STDC_HEADERS", .value = "1" },
    .{ .name = "HAVE_FLOAT_H", .value = "1" },
    .{ .name = "HAVE_INTTYPES_H", .value = "1" },
    .{ .name = "HAVE_INTPTR_T", .value = "1" },
    .{ .name = "HAVE_INTMAX_T", .value = "1" },
    .{ .name = "HAVE_LOCALE_H", .value = "1" },
    .{ .name = "HAVE_LOCALECONV", .value = "1" },
    .{ .name = "HAVE_MEMORY_H", .value = "1" },
    .{ .name = "HAVE_PTRDIFF_T", .value = "1" },
    .{ .name = "HAVE_STDINT_H", .value = "1" },
    .{ .name = "HAVE_STDLIB_H", .value = "1" },
    .{ .name = "HAVE_STRING_H", .value = "1" },
    .{ .name = "HAVE_SYS_TYPES_H", .value = "1" },
    .{ .name = "HAVE_UINT_LEAST32_T", .value = "1" },
    .{ .name = "HAVE_UNISTD_H", .value = "1" },

    .{ .name = "HAVE_ALLOCA", .value = "1" },
    .{ .name = "HAVE_LONG_LONG", .value = "1" },
    .{ .name = "HAVE_MEMSET", .value = "1" },
    .{ .name = "HAVE_RAISE", .value = "1" },
    .{ .name = "HAVE_STRCHR", .value = "1" },
    .{ .name = "HAVE_STRNLEN", .value = "1" },
    .{ .name = "HAVE_STRTOL", .value = "1" },
    .{ .name = "HAVE_STRTOUL", .value = "1" },
    .{ .name = "HAVE_VSNPRINTF", .value = "1" },

    .{ .name = "HAVE_DECL_FGETC", .value = "1" },
    .{ .name = "HAVE_DECL_FSCANF", .value = "1" },
    .{ .name = "HAVE_DECL_UNGETC", .value = "1" },
    .{ .name = "HAVE_DECL_VFPRINTF", .value = "1" },

    // Clang supports the attributes used by GMP's integer-width definitions.
    .{ .name = "HAVE_ATTRIBUTE_CONST", .value = "1" },
    .{ .name = "HAVE_ATTRIBUTE_MALLOC", .value = "1" },
    .{ .name = "HAVE_ATTRIBUTE_MODE", .value = "1" },
    .{ .name = "HAVE_ATTRIBUTE_NORETURN", .value = "1" },

    .{ .name = "SIZEOF_UNSIGNED", .value = "4" },
    .{ .name = "SIZEOF_UNSIGNED_SHORT", .value = "2" },

    // Keep FFT multiplication enabled; `mpn/generic/mul_fft.c` is compiled.
    .{ .name = "WANT_FFT", .value = "1" },

    // Select one temporary-allocation macro; GMP defines `TMP_*` only in that branch.
    // `WANT_TMP_ALLOCA` matches configure when the compiler provides `alloca`.
    .{ .name = "WANT_TMP_ALLOCA", .value = "1" },

    // Keep VERSION aligned with `package_version` and the public header.
    .{ .name = "VERSION", .value = "\"6.3.0\"" },
};

/// Number of entries returned by `targetMacros`.
const target_macro_count = 12;

/// Return target-derived macros; formatted values borrow `buf`.
/// The buffer must outlive consumers of the returned entries.
fn targetMacros(p: Params, buf: []u8) [target_macro_count]Macro {
    return .{
        .{ .name = "SIZEOF_UNSIGNED_LONG", .value = p.formatLong(buf[0..8]) },
        .{ .name = "SIZEOF_MP_LIMB_T", .value = p.formatLimb(buf[8..16]) },
        .{ .name = "SIZEOF_VOID_P", .value = p.formatVoidPtr(buf[16..24]) },
        .{ .name = "WANT_ASSERT", .value = if (p.want_assert) "1" else "0" },
        .{ .name = "HAVE_ALLOCA_H", .value = if (p.have_alloca_h) "1" else "0" },
        .{ .name = "HAVE_LONG_DOUBLE", .value = if (p.have_long_double) "1" else "0" },
        .{ .name = "HAVE_LANGINFO_H", .value = if (p.have_langinfo) "1" else "0" },
        .{ .name = "HAVE_NL_LANGINFO", .value = if (p.have_langinfo) "1" else "0" },
        .{ .name = "HAVE_QUAD_T", .value = if (p.have_quad_t) "1" else "0" },
        .{ .name = "HAVE_OBSTACK_VPRINTF", .value = if (p.have_obstack_vprintf) "1" else "0" },
        .{ .name = if (p.big_endian)
            "HAVE_LIMB_BIG_ENDIAN"
        else
            "HAVE_LIMB_LITTLE_ENDIAN", .value = "1" },
        .{ .name = if (p.big_endian)
            "HAVE_DOUBLE_IEEE_BIG_ENDIAN"
        else
            "HAVE_DOUBLE_IEEE_LITTLE_ENDIAN", .value = "1" },
    };
}

/// Resolve a macro value, returning null when it must remain undefined.
fn macroValue(p: Params, name: []const u8, buf: []u8) ?[]const u8 {
    for (common_macros) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.value;
    }
    const target = targetMacros(p, buf);
    for (target[0..]) |m| {
        if (std.mem.eql(u8, m.name, name)) return m.value;
    }
    return null;
}

const undef_prefix = "#undef ";

/// Render `config.h`, replacing known `#undef` entries and preserving the rest.
pub fn renderConfigH(gpa: std.mem.Allocator, template: []const u8, p: Params) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try writeConfigHPrologue(gpa, &out);
    var scratch: [32]u8 = undefined;

    var pos: usize = 0;
    while (pos < template.len) {
        const rest = template[pos..];
        const eol = std.mem.findScalar(u8, rest, '\n');
        const line = if (eol) |n| rest[0 .. n + 1] else rest;
        pos += line.len;

        if (std.mem.startsWith(u8, line, undef_prefix)) {
            const name = std.mem.trim(u8, line[undef_prefix.len..], " \t\r\n");
            if (macroValue(p, name, &scratch)) |value| {
                try out.print(gpa, "#define {s} {s}\n", .{ name, value });
            } else {
                try out.print(gpa, "/* #undef {s} */\n", .{name});
            }
        } else {
            try out.appendSlice(gpa, line);
        }
    }

    return out.toOwnedSlice(gpa);
}

/// Write the generated `config.h` prologue.
fn writeConfigHPrologue(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.print(gpa,
        \\/* config.h.  Generated from config.in by the Zig build of this GMP fork;
        \\   do not edit.  Upstream input: GMP 6.3.0 (LGPLv3 or later, or GPLv2 or
        \\   later).  Backend: portable C, mpn path "generic", NO_ASM. */
        \\
        \\
    , .{});
}

/// Substitute `@VAR@` placeholders; unknown placeholders pass through unchanged.
/// Resolver values are copied into the output before this function returns.
fn renderAtVars(
    gpa: std.mem.Allocator,
    template: []const u8,
    prologue: []const u8,
    context: anytype,
    comptime resolve: fn (@TypeOf(context), []const u8) ?[]const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, prologue);

    var pos: usize = 0;
    while (pos < template.len) {
        const at = std.mem.findScalarPos(u8, template, pos, '@') orelse {
            try out.appendSlice(gpa, template[pos..]);
            break;
        };
        try out.appendSlice(gpa, template[pos..at]);

        const close = std.mem.findScalarPos(u8, template, at + 1, '@') orelse {
            try out.appendSlice(gpa, template[at..]);
            break;
        };
        const name = template[at + 1 .. close];
        pos = close + 1;

        if (resolve(context, name)) |value| {
            try out.appendSlice(gpa, value);
        } else {
            // Preserve unknown placeholders so missing substitutions remain visible.
            try out.appendSlice(gpa, template[at .. close + 1]);
        }
    }

    return out.toOwnedSlice(gpa);
}

/// Context for rendering `gmp.h` placeholders.
const GmpH = struct {
    params: Params,
    cflags: []const u8,
    /// Scratch storage for numeric substitutions during `renderGmpH`.
    scratch: *[16]u8,
};

/// Render `gmp.h` from upstream's `gmp-h.in` template.
pub fn renderGmpH(
    gpa: std.mem.Allocator,
    template: []const u8,
    p: Params,
    cflags: []const u8,
) ![]u8 {
    var scratch: [16]u8 = undefined;
    return renderAtVars(
        gpa,
        template,
        try gmpHPrologue(gpa, p),
        GmpH{ .params = p, .cflags = cflags, .scratch = &scratch },
        gmpHSubstitution,
    );
}

/// Resolve one `gmp-h.in` placeholder.
fn gmpHSubstitution(h: GmpH, name: []const u8) ?[]const u8 {
    const p = h.params;
    if (std.mem.eql(u8, name, "GMP_LIMB_BITS")) return p.formatLimbBits(h.scratch[0..]);
    if (std.mem.eql(u8, name, "GMP_NAIL_BITS")) return p.formatNailBits(h.scratch[0..]);
    if (std.mem.eql(u8, name, "DEFN_LONG_LONG_LIMB")) {
        // This selects `unsigned long long` rather than `unsigned long` for `mp_limb_t`.
        return if (p.long_long_limb) "#define _LONG_LONG_LIMB 1" else "/* #undef _LONG_LONG_LIMB */";
    }
    // Match Windows import/export decoration to the delivered library artifact.
    if (std.mem.eql(u8, name, "LIBGMP_DLL")) return if (p.libgmp_dll) "1" else "0";
    if (std.mem.eql(u8, name, "HAVE_HOST_CPU_FAMILY_power")) return "0";
    if (std.mem.eql(u8, name, "HAVE_HOST_CPU_FAMILY_powerpc")) return "0";
    if (std.mem.eql(u8, name, "CC")) return "zig cc";
    if (std.mem.eql(u8, name, "CFLAGS")) return h.cflags;
    return null;
}

/// Render relocatable `gmp.pc` metadata from upstream's template.
/// Its prefix resolves from `${pcfiledir}` when pkg-config reads the file.
pub fn renderPkgConfig(gpa: std.mem.Allocator, template: []const u8) ![]u8 {
    return renderAtVars(gpa, template, "", {}, pkgConfigSubstitution);
}

/// Resolve one `gmp.pc.in` placeholder.
fn pkgConfigSubstitution(_: void, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "PACKAGE_NAME")) return "GNU MP";
    if (std.mem.eql(u8, name, "PACKAGE_VERSION")) return package_version;
    if (std.mem.eql(u8, name, "prefix")) return "${pcfiledir}/../..";
    if (std.mem.eql(u8, name, "exec_prefix")) return "${prefix}";
    if (std.mem.eql(u8, name, "includedir")) return "${prefix}/include";
    if (std.mem.eql(u8, name, "libdir")) return "${exec_prefix}/lib";
    return null;
}

/// Return the limb type name emitted in `gmp.h`.
pub fn limbTypeName(p: Params) []const u8 {
    if (p.limb_bits == 32) return "unsigned long int";
    return if (p.long_long_limb) "unsigned long long int" else "unsigned long int";
}

/// Generate `gmp.h`'s comment with its ABI-critical values.
fn gmpHPrologue(gpa: std.mem.Allocator, p: Params) ![]u8 {
    return gpa.print(
        \\/* gmp.h.  Generated from gmp-h.in by the Zig build of this GMP fork;
        \\   do not edit.  Upstream input: GMP 6.3.0 (LGPLv3 or later, or GPLv2 or
        \\   later).  Backend: portable C, mpn path "generic", NO_ASM.
        \\   mp_limb_t: {s}, GMP_LIMB_BITS {d}, LIBGMP_DLL {d}. */
        \\
        \\
    , .{ limbTypeName(p), p.limb_bits, @intFromBool(p.libgmp_dll) });
}
