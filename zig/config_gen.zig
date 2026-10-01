//! Derivation of the GMP build configuration from a resolved Zig target.
//!
//! GMP obtains two headers from `configure` before any library source can be
//! compiled:
//!
//!   * `gmp.h`   - the public header, generated from `gmp-h.in` by `@VAR@`
//!                 substitution. It encodes the limb type and limb size, so it
//!                 is ABI critical.
//!   * `config.h` - the internal autoconf header, generated from `config.in`
//!                 by turning every `#undef NAME` into `#define NAME value` or
//!                 `/* #undef NAME */`.
//!
//! This module reproduces exactly those two derivations from the Zig target, so
//! that one source tree yields a correct library for every supported target and
//! nothing has to be guessed from the build host.
//!
//! Two rules shape the macro table below:
//!
//!   1. Only macros that are *true* for the target are defined. GMP tests some
//!      configuration macros with `#ifdef` rather than `#if` (for example
//!      `WANT_FAT_BINARY`, `HAVE_NATIVE_mpn_*` and `HAVE_HOST_CPU_FAMILY_*`),
//!      so defining a false macro would change behaviour.
//!   2. `HAVE_HOST_CPU_*` and `HAVE_NATIVE_mpn_*` stay undefined: this fork
//!      builds the portable C backend with mpn path `generic`, so no
//!      architecture specific routine exists.
//!
//! `NO_ASM` is defined on purpose. It is what `--disable-assembly` sets in
//! upstream `configure`, and it disables the inline assembly helpers that a few
//! `mpn/generic` files (and `longlong.h`) would otherwise use when the compiler
//! predefines `__amd64__` and friends. Those blocks cannot compile for
//! `wasm32`, so a genuinely assembly free backend is both faster to reason
//! about and portable.

const std = @import("std");

/// Everything that varies per target (and, for `WANT_ASSERT`, per optimize
/// mode).
pub const Params = struct {
    /// `GMP_LIMB_BITS`: number of value bits per limb. 64 except on 32-bit
    /// pointer targets, which use native 32-bit limbs.
    limb_bits: u16,
    /// `GMP_NAIL_BITS`: unused limbs at the top of each limb. Always 0; GMP
    /// only supports nails with tuned assembly.
    nail_bits: u16 = 0,
    /// `sizeof(unsigned long)`, which is not the pointer width on LLP64.
    sizeof_unsigned_long: u16,
    /// `sizeof(mp_limb_t)`: the limb type, `unsigned long` or
    /// `unsigned long long`.
    sizeof_mp_limb_t: u16,
    /// `sizeof(void *)`.
    sizeof_void_p: u16,
    /// True on LLP64 (Windows), where GMP must use `unsigned long long`
    /// limbs because `unsigned long` is only 32 bits wide.
    long_long_limb: bool,
    /// True for big endian targets.
    big_endian: bool,
    /// `<alloca.h>` exists. Not on macOS, where `alloca` comes from
    /// `<stdlib.h>`; irrelevant for clang, which takes the
    /// `__builtin_alloca` branch in `gmp-impl.h` anyway.
    have_alloca_h: bool,
    /// `long double` exists and is usable by GMP's `printf`.
    have_long_double: bool,
    /// `<langinfo.h>` and `nl_langinfo` exist. Absent on MinGW; GMP then falls
    /// back to `localeconv()->decimal_point`.
    have_langinfo: bool,
    /// The target's `<sys/types.h>` defines `quad_t`, which GMP's `printf`
    /// needs for the `%q` length modifier. glibc, musl and Darwin all have it;
    /// MinGW does not, and there GMP's `%q` fails loudly through
    /// `ASSERT_FAIL` instead of reading a vararg of an unknown type.
    have_quad_t: bool,
    /// `WANT_ASSERT`: GMP's internal assertions. Only in Debug, mirroring the
    /// `-DNDEBUG` driven configure default.
    want_assert: bool,

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

/// Pointer width in bits, derived from the architecture.
///
/// `std.Target` has no public pointer size accessor, and the mapping must be
/// explicit: guessing it from the ABI is wrong for `gnux32` (32-bit pointers,
/// 64-bit `long`).
///
/// Only architectures whose pointer width is known are listed; anything else
/// panics rather than guessing, so adding one is a deliberate act. Zig 0.16
/// keeps the endians of the common architectures in one enum member but gives
/// a few of them separate ones, and it has no `sparcel` at all, because LLVM
/// dropped that tag.
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

/// Width of `unsigned long` in bits.
///
/// This is where GMP's ABI forks: LP64 (64-bit `long`), LLP64 (Windows, 32-bit
/// `long`) and LP32 (32-bit `long`).
fn unsignedLongBits(target: std.Target, ptr_bits: u16) u16 {
    return switch (target.abi) {
        // 32-bit `long` regardless of pointer width.
        .msvc => 32,
        // The x32 ABIs keep a 64-bit `long` with 32-bit pointers.
        .gnux32, .muslx32 => 64,
        // Windows targets other than msvc use the GNU runtime, i.e. mingw,
        // which follows the Microsoft ABI: 32-bit `long`.
        else => if (target.os.tag == .windows) 32 else ptr_bits,
    };
}

/// Derive the GMP configuration for `target` built at `optimize`.
pub fn paramsFor(target: std.Target, optimize: std.builtin.OptimizeMode) Params {
    const ptr_bits = pointerBits(target.cpu.arch);
    const long_bits = unsignedLongBits(target, ptr_bits);

    // GMP picks the widest native limb type: `unsigned long` when that is at
    // least 64 bits, `unsigned long long` on LLP64 where `long` is 32 bits,
    // and native 32-bit limbs on 32-bit pointer targets.
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
        // Zig's clang gives wasm32 a 128-bit `long double`; GMP's printf only
        // needs it for `%Lf`, and the libc printf on that target is the least
        // exercised 128-bit path, so the portable choice is taken there.
        .have_long_double = !is_wasm,
        // MinGW has no `<langinfo.h>`; GMP falls back to `localeconv`.
        .have_langinfo = target.os.tag != .windows,
        // `any-windows-any/sys/types.h` declares no `quad_t`, while
        // `generic-glibc`, `generic-musl` and `any-darwin-any` all do.
        .have_quad_t = target.os.tag != .windows,
        .want_assert = optimize == .Debug,
    };
}

const Macro = struct { name: []const u8, value: []const u8 };

/// Configuration macros that hold the same value on every supported target.
///
/// `NO_ASM` is here because it must be *defined* for `gmp-impl.h`,
/// `longlong.h` and the `mpn/generic` inline assembly helpers to be skipped;
/// the value itself is irrelevant.
const common_macros = [_]Macro{
    .{ .name = "NO_ASM", .value = "1" },

    // Headers and integer types available on every supported C library.
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

    // Functions.
    .{ .name = "HAVE_ALLOCA", .value = "1" },
    .{ .name = "HAVE_LONG_LONG", .value = "1" },
    .{ .name = "HAVE_MEMSET", .value = "1" },
    .{ .name = "HAVE_RAISE", .value = "1" },
    .{ .name = "HAVE_STRCHR", .value = "1" },
    .{ .name = "HAVE_STRNLEN", .value = "1" },
    .{ .name = "HAVE_STRTOL", .value = "1" },
    .{ .name = "HAVE_STRTOUL", .value = "1" },
    .{ .name = "HAVE_VSNPRINTF", .value = "1" },

    // Declarations GMP's `scanf` and `printf` code tests for.
    .{ .name = "HAVE_DECL_FGETC", .value = "1" },
    .{ .name = "HAVE_DECL_FSCANF", .value = "1" },
    .{ .name = "HAVE_DECL_UNGETC", .value = "1" },
    .{ .name = "HAVE_DECL_VFPRINTF", .value = "1" },

    // Compiler attributes. clang implements all three, and `mode` is what
    // `longlong.h` uses for its exact width integer types.
    .{ .name = "HAVE_ATTRIBUTE_CONST", .value = "1" },
    .{ .name = "HAVE_ATTRIBUTE_MALLOC", .value = "1" },
    .{ .name = "HAVE_ATTRIBUTE_MODE", .value = "1" },
    .{ .name = "HAVE_ATTRIBUTE_NORETURN", .value = "1" },

    // Fixed sizes.
    .{ .name = "SIZEOF_UNSIGNED", .value = "4" },
    .{ .name = "SIZEOF_UNSIGNED_SHORT", .value = "2" },

    // GMP's FFT based multiplication stays enabled; `mpn/generic/mul_fft.c`
    // is part of the library.
    .{ .name = "WANT_FFT", .value = "1" },

    // GMP's temporary memory. Exactly one `WANT_TMP_*` has to be selected,
    // because `TMP_DECL`, `TMP_MARK`, `TMP_ALLOC` and `TMP_FREE` are defined
    // only inside those blocks (`gmp-impl.h:373-422`) and 124 of the compiled
    // sources use them. `configure.ac:114` defaults `--enable-alloca` to
    // `reentrant`, `configure:24083-24087` turns that into `WANT_TMP_ALLOCA`
    // whenever `alloca` works, and `gmp-impl.h:196-198` makes `alloca` the
    // clang builtin on every target here, so that is the selection.
    .{ .name = "WANT_TMP_ALLOCA", .value = "1" },

    // `configure:3619` writes the package version here from `AC_INIT`, and
    // `version.c:33` is `const char * const gmp_version = VERSION;`, so the
    // value must be a C string literal, quotes included. It has to stay equal
    // to `gmp-h.in:2338-2340` and to the version in `build.zig.zon`.
    .{ .name = "VERSION", .value = "\"6.3.0\"" },
};

/// Number of entries `targetMacros` returns.
const target_macro_count = 11;

/// Target derived macros, in the order they are looked up.
///
/// The table is returned by value, never as a slice of an anonymous array:
/// `Macro.value` points into the caller's `buf`, and a pointer to a
/// temporary would already be dead when `macroValue` iterates it. Only `buf`
/// has to outlive the call.
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

/// Resolve `name` against the macro tables, formatting dynamic values into
/// `buf`. Returns null when the macro must stay undefined.
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

/// Render `config.h` from the upstream `config.in` template.
///
/// This is autoconf's transformation, spelled out: a `#undef NAME` line becomes
/// `#define NAME value` when the value is known and `/* #undef NAME */`
/// otherwise. Every other byte of the template, including the descriptive
/// comments autoconf keeps, is copied verbatim.
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

/// Write the header comment that marks the generated `config.h`.
fn writeConfigHPrologue(gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.print(gpa,
        \\/* config.h.  Generated from config.in by the Zig build of this GMP fork;
        \\   do not edit.  Upstream input: GMP 6.3.0 (LGPLv3 or later, or GPLv2 or
        \\   later).  Backend: portable C, mpn path "generic", NO_ASM. */
        \\
        \\
    , .{});
}

/// Substitute the `@VAR@` placeholders of `gmp-h.in`.
///
/// GMP's `configure` does this through `AC_CONFIG_FILES(gmp.h:gmp-h.in)`; the
/// value of every placeholder is a build parameter, not a compile time macro.
pub fn renderGmpH(
    gpa: std.mem.Allocator,
    template: []const u8,
    p: Params,
    cflags: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try writeGmpHPrologue(gpa, &out, p);
    var scratch: [16]u8 = undefined;

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

        if (substitution(p, &scratch, name, cflags)) |value| {
            try out.appendSlice(gpa, value);
        } else {
            // Unknown placeholder: keep it verbatim so the mistake is loud
            // instead of silently producing a broken header.
            try out.appendSlice(gpa, template[at .. close + 1]);
        }
    }

    return out.toOwnedSlice(gpa);
}

/// Value of one `@VAR@` placeholder of `gmp-h.in`.
fn substitution(p: Params, scratch: []u8, name: []const u8, cflags: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "GMP_LIMB_BITS")) return p.formatLimbBits(scratch);
    if (std.mem.eql(u8, name, "GMP_NAIL_BITS")) return p.formatNailBits(scratch);
    if (std.mem.eql(u8, name, "DEFN_LONG_LONG_LIMB")) {
        // `gmp.h` typedefs `mp_limb_t` as `unsigned long long` only when this
        // is defined; otherwise as `unsigned long`.
        return if (p.long_long_limb) "#define _LONG_LONG_LIMB 1" else "/* #undef _LONG_LONG_LIMB */";
    }
    // Static linking only, so `__GMP_DECLSPEC` stays empty and the ABI is
    // identical on LP64, LLP64 and wasm32.
    if (std.mem.eql(u8, name, "LIBGMP_DLL")) return "0";
    // No tuned assembly path is selected, so neither Power family macro is set.
    if (std.mem.eql(u8, name, "HAVE_HOST_CPU_FAMILY_power")) return "0";
    if (std.mem.eql(u8, name, "HAVE_HOST_CPU_FAMILY_powerpc")) return "0";
    if (std.mem.eql(u8, name, "CC")) return "zig cc";
    if (std.mem.eql(u8, name, "CFLAGS")) return cflags;
    return null;
}

/// Human readable name of the limb type, as `gmp.h` declares it.
pub fn limbTypeName(p: Params) []const u8 {
    if (p.limb_bits == 32) return "unsigned long int";
    return if (p.long_long_limb) "unsigned long long int" else "unsigned long int";
}

/// Write the header comment that marks the generated `gmp.h`, including the
/// two values that make the header ABI critical: the limb type and the limb
/// size.
fn writeGmpHPrologue(gpa: std.mem.Allocator, out: *std.ArrayList(u8), p: Params) !void {
    try out.print(gpa,
        \\/* gmp.h.  Generated from gmp-h.in by the Zig build of this GMP fork;
        \\   do not edit.  Upstream input: GMP 6.3.0 (LGPLv3 or later, or GPLv2 or
        \\   later).  Backend: portable C, mpn path "generic", NO_ASM.
        \\   mp_limb_t: {s}, GMP_LIMB_BITS {d}. */
        \\
        \\
    , .{ limbTypeName(p), p.limb_bits });
}
