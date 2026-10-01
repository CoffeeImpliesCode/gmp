//! Build of the GMP 6.3.0 fork as a Zig package.
//!
//! What this does, in order:
//!
//!   1. Derives GMP's configuration from the resolved target (limb size, limb
//!      type, endianness, available headers) in `zig/config_gen.zig` and
//!      renders the two headers GMP's `configure` would have produced:
//!      `config.h` from `config.in` and the public `gmp.h` from `gmp-h.in`.
//!   2. Runs GMP's own host table generators (`gen-fib`, `gen-bases`, `gen-fac`,
//!      `gen-sieve`, `gen-psqr`, `gen-trialdivtab`, `gen-jacobitab`) for the
//!      target's limb size, with the arguments the upstream `Makefile.am`
//!      rules use.
//!   3. Compiles the real libgmp sources for the target: `mpz`, `mpq`, `mpf`,
//!      the portable C `mpn` layer, `printf`, `scanf` and the random state
//!      code, with `NO_ASM` and without autotools, CMake, Make or any download
//!      at build time.
//!   4. Exposes the result as the module `gmp` (facade plus the complete
//!      translated C API) and as the static library artifact `gmp`, whose
//!      include tree carries the generated `gmp.h`, so a dependent needs only
//!      `dep.artifact("gmp")` or `dep.module("gmp")`.
//!
//! Steps: `zig build` installs the library, `zig build test` runs the tests in
//! the current optimize mode, `zig build smoke` and `zig build run` run the
//! example, `zig build check` compiles the whole public surface for all six
//! supported targets without running anything, and `zig build provenance`
//! re-checks the licence and provenance records.

const std = @import("std");

const config = @import("zig/config_gen.zig");
const sources = @import("zig/sources.zig");

/// Targets the cross compilation check covers. Six triples including the two
/// ABIs that matter for GMP's limb type, LP64 and LLP64 (Windows), plus a
/// 32-bit pointer target.
const checked_targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "aarch64-macos-none",
    "x86_64-windows-gnu",
    "riscv64-linux-gnu",
    "wasm32-wasi",
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const use_system_library = b.systemIntegrationOption("gmp", .{});

    // Registered up front so `dep.module("gmp")` resolves for dependents.
    const gmp_module = b.addModule("gmp", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = makeLibrary(b, target, optimize, gmp_module, use_system_library, true);

    const example = addExample(b, target, optimize, gmp_module, library, "gmp-example");
    b.installArtifact(example);

    const smoke_run = b.addRunArtifact(example);
    smoke_run.step.dependOn(b.getInstallStep());
    const smoke_step = b.step("smoke", "Run the example and print deterministic results");
    smoke_step.dependOn(&smoke_run.step);

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&smoke_run.step);

    const tests = addTests(b, target, optimize, gmp_module, library, "gmp-test");
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);

    // Cross compilation check: compile the whole public surface, run nothing.
    // The example and the test binary reference every public facade method, so
    // their bodies are instantiated.
    //
    // With no `-Dtarget=` this covers all six checked targets. With one, it
    // covers only that target, which is what lets CI name the target that
    // failed instead of reporting one aggregate result for the matrix.
    const check_step = b.step("check", "Compile the public facade, tests and example");
    if (!target.query.isNative()) {
        addTargetCheck(b, check_step, target.query, .Debug, "gmp-check");
    } else {
        for (checked_targets) |triple| {
            // Zig 0.16's `Target.Query` has no `arch_os_abi` field: a triple is
            // parsed by `std.Build.parseTargetQuery`, which is what
            // `standardTargetOptions` itself uses for `-Dtarget`.
            const query = std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch |err| {
                std.debug.panic("gmp: cannot parse checked target {s}: {s}", .{ triple, @errorName(err) });
            };
            addTargetCheck(b, check_step, query, .Debug, b.fmt("gmp-check-{s}", .{triple}));
        }
    }

    addProvenanceStep(b);
}

/// Compiles the library, the facade module, the example and the test binary
/// for one target and attaches them to `check_step`. Nothing is run: a
/// cross-compiled binary cannot run on the host.
fn addTargetCheck(
    b: *std.Build,
    check_step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
) void {
    const resolved = b.resolveTargetQuery(query);
    const checked_module = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = resolved,
        .optimize = optimize,
    });
    const checked_library = makeLibrary(b, resolved, optimize, checked_module, false, false);

    const checked_example = addExample(
        b,
        resolved,
        optimize,
        checked_module,
        checked_library,
        name,
    );
    check_step.dependOn(&checked_example.step);

    const checked_tests = addTests(b, resolved, optimize, checked_module, checked_library, name);
    check_step.dependOn(&checked_tests.step);
}

/// How consumers link GMP: the artifact this build produces, or an installed
/// system library.
const Library = union(enum) {
    bundled: Bundled,
    system,

    const Bundled = struct {
        step: *std.Build.Step.Compile,
        /// Directory holding the generated `gmp.h`. It lives in the build
        /// cache, not in the source tree, so any C source of this build that
        /// includes the public header by name needs it on its own compile
        /// line; linking the artifact does not add include paths.
        include_dir: std.Build.LazyPath,
    };

    fn link(self: Library, module: *std.Build.Module) void {
        switch (self) {
            .bundled => |bundled| module.linkLibrary(bundled.step),
            .system => module.linkSystemLibrary("gmp", .{}),
        }
    }

    /// Extra include path a C source of this build needs. In system library
    /// mode the installed header is found through the default search path, so
    /// nothing is added there.
    fn cIncludeDir(self: Library) ?std.Build.LazyPath {
        return switch (self) {
            .bundled => |bundled| bundled.include_dir,
            .system => null,
        };
    }
};

fn makeLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gmp_module: *std.Build.Module,
    use_system_library: bool,
    install: bool,
) Library {
    if (use_system_library) return makeSystemLibrary(b, target, optimize, gmp_module);
    return .{ .bundled = makeBundledLibrary(b, target, optimize, gmp_module, install) };
}

/// Build the real libgmp from this repository.
fn makeBundledLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gmp_module: *std.Build.Module,
    install: bool,
) Library.Bundled {
    const params = config.paramsFor(target.result, optimize);
    const generated = generate(b, optimize, params);

    const library = b.addLibrary(.{
        .name = "gmp",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // The library sources. `__GMP_WITHIN_GMP` is what upstream's `Makefile.am`
    // passes on `AM_CPPFLAGS`. Nothing else is needed on the command line:
    // `gmp-impl.h` includes the generated `config.h`, so every configuration
    // macro, `NO_ASM` and `HAVE_ALLOCA` included, is already in effect.
    library.root_module.addCSourceFiles(.{
        .files = sources.all,
        .flags = &.{"-D__GMP_WITHIN_GMP"},
    });
    // The two tables GMP generates at build time live in the generated
    // directory, not in the source tree.
    library.root_module.addCSourceFiles(.{
        .root = generated.directory,
        .files = &sources.generated,
        .flags = &.{"-D__GMP_WITHIN_GMP"},
    });
    // One translation unit per operation of every multi-function mpn
    // template. A template cannot be compiled on its own, so none of them is
    // in `sources.all`; each operation is a wrapper that selects one.
    library.root_module.addCSourceFiles(.{
        .root = generated.directory,
        .files = generated.operation_sources,
        .flags = &.{"-D__GMP_WITHIN_GMP"},
    });
    // Generated `gmp.h`, `config.h`, `gmp-mparam.h` and the table headers,
    // which `gmp-impl.h` and a few `mpn` files include by bare name.
    library.root_module.addIncludePath(generated.directory);
    // `gmp-impl.h` and `longlong.h` from the top of the tree.
    library.root_module.addIncludePath(b.path("."));

    // GMP's installed public header set, which is what upstream ships from
    // `gmp_include_HEADERS`: `gmp.h`, generated per target, and
    // `gmp-mparam.h`. Installing them into the artifact's include tree is what
    // puts `gmp.h` on a dependent's compile line, so a dependent needs only
    // `dep.artifact("gmp")` and never the source tree.
    //
    // GMP's internal `config.h` is deliberately not installed. It is private
    // to building this tree, and publishing it would shadow the `config.h` of
    // any autotools-configured dependent, which is the same failure mode as
    // linking new headers against an older installed library.
    library.installHeader(generated.gmp_header, "gmp.h");
    library.installHeader(generated.mparam_header, "gmp-mparam.h");
    library.installHeader(b.path("include/gmp_all.h"), "gmp_all.h");

    gmp_module.addImport("c", translateC(b, target, optimize, generated.directory));
    gmp_module.linkLibrary(library);

    if (install) b.installArtifact(library);
    return .{ .step = library, .include_dir = generated.directory };
}

/// Link an installed GMP instead of building this one.
///
/// The translated declarations come from the *system* `gmp.h`, because the
/// generated include directory is deliberately not added to the include line
/// here. The declarations therefore always describe the library that is linked,
/// never the header this source tree would have generated. The facade uses only
/// long standing public GMP API, so it works against any GMP 5 or later
/// installation; the limb size then comes from the installed library, which is
/// exactly what its own header describes.
fn makeSystemLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gmp_module: *std.Build.Module,
) Library {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("include/gmp_all.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate.linkSystemLibrary("gmp", .{});

    gmp_module.addImport("c", translate.createModule());
    return .system;
}

/// Translate the public header with `gmp.h` resolved from `include_dir`.
///
/// When `include_dir` is null, the system `gmp.h` is used.
fn translateC(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    include_dir: ?std.Build.LazyPath,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("include/gmp_all.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (include_dir) |dir| translate.addIncludePath(dir);
    return translate.createModule();
}

const Generated = struct {
    /// Directory holding every generated file: both headers, the two
    /// generated translation units and the template operation wrappers.
    directory: std.Build.LazyPath,
    /// The public headers installed into the artifact's include tree. GMP's
    /// internal `config.h` is generated into `directory` for this build only.
    gmp_header: std.Build.LazyPath,
    mparam_header: std.Build.LazyPath,
    /// Names inside `directory` of the generated mpn template wrappers, one
    /// per operation, each compiled as a translation unit in its own right.
    operation_sources: []const []const u8,
};

/// Render `gmp.h` and `config.h` the way GMP's `configure` would, run the
/// table generators and write the mpn template wrappers, all into one
/// directory.
fn generate(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    params: config.Params,
) Generated {
    const output = b.addWriteFiles();

    const gmp_h_in = readPackageFile(b, "gmp-h.in");
    const config_in = readPackageFile(b, "config.in");

    const cflags = b.fmt("zig cc -O{s} -DNO_ASM", .{@tagName(optimize)});
    // Each renderer emits the fork's prologue and the substituted template, so
    // a generated header is one buffer and never a runtime `++`.
    const gmp_header = output.add(
        "gmp.h",
        config.renderGmpH(b.allocator, gmp_h_in, params, cflags) catch @panic("OOM"),
    );
    _ = output.add(
        "config.h",
        config.renderConfigH(b.allocator, config_in, params) catch @panic("OOM"),
    );
    // GMP's `configure` links `gmp-mparam.h` to the chosen mpn path directory.
    const mparam_header = output.addCopyFile(b.path("mpn/generic/gmp-mparam.h"), "gmp-mparam.h");

    const limb_bits = b.fmt("{d}", .{params.limb_bits});
    const nail_bits = b.fmt("{d}", .{params.nail_bits});

    // Table generators, built and invoked exactly as upstream's `Makefile.am`
    // does: one host executable per generator, carrying `LIBM_FOR_BUILD` only
    // where the upstream rule passes it, and run with the *target's* limb size
    // and nail count as arguments. The host runs them because they only compute
    // tables; the target chooses their layout.
    const gen_fib = generatorProgram(b, "gen-fib", false);
    const gen_bases = generatorProgram(b, "gen-bases", true);
    const gen_fac = generatorProgram(b, "gen-fac", false);
    const gen_sieve = generatorProgram(b, "gen-sieve", false);
    const gen_psqr = generatorProgram(b, "gen-psqr", true);
    const gen_trialdivtab = generatorProgram(b, "gen-trialdivtab", true);
    const gen_jacobitab = generatorProgram(b, "gen-jacobitab", false);

    _ = output.addCopyFile(runGenerator(b, gen_fib, &.{ "table", limb_bits, nail_bits }), "fib_table.c");
    _ = output.addCopyFile(runGenerator(b, gen_fib, &.{ "header", limb_bits, nail_bits }), "fib_table.h");
    _ = output.addCopyFile(runGenerator(b, gen_bases, &.{ "table", limb_bits, nail_bits }), "mp_bases.c");
    _ = output.addCopyFile(runGenerator(b, gen_bases, &.{ "header", limb_bits, nail_bits }), "mp_bases.h");
    _ = output.addCopyFile(runGenerator(b, gen_fac, &.{ limb_bits, nail_bits }), "fac_table.h");
    _ = output.addCopyFile(runGenerator(b, gen_sieve, &.{limb_bits}), "sieve_table.h");
    _ = output.addCopyFile(runGenerator(b, gen_psqr, &.{ limb_bits, nail_bits }), "perfsqr.h");
    _ = output.addCopyFile(runGenerator(b, gen_trialdivtab, &.{ limb_bits, "8000" }), "trialdivtab.h");
    _ = output.addCopyFile(runGenerator(b, gen_jacobitab, &.{}), "jacobitab.h");

    // One wrapper per operation of every multi-function mpn template. Each
    // wrapper names the operation and includes the template, which is what
    // upstream gets from the symlink `configure` creates at `configure:25553`,
    // with the `-DOPERATION_<name>` that `mpn/Makefile.am:33` derives from the
    // object name.  A bare `-D` names `1`, so each wrapper defines its operation
    // to 1: the templates test `#if OPERATION_<name>`, and an object-like
    // macro with no value leaves that expression empty. Giving each operation
    // its own file also keeps each one its own object file, which a repeated
    // `-D` on a shared source would not.
    var operation_sources: std.ArrayList([]const u8) = .empty;
    for (sources.operations) |operation| {
        const name = b.fmt("{s}.c", .{operation.name});
        _ = output.add(name, b.fmt(
            \\/* Generated by the Zig build: one operation of an mpn/generic
            \\   template, selected as upstream's configure selects it. */
            \\#define OPERATION_{s} 1
            \\#include "{s}"
            \\
        , .{ operation.name, operation.template }));
        operation_sources.append(b.allocator, name) catch @panic("OOM");
    }

    return .{
        .directory = output.getDirectory(),
        .gmp_header = gmp_header,
        .mparam_header = mparam_header,
        .operation_sources = operation_sources.items,
    };
}

/// Read a file from the package root, which is the GMP release tree.
fn readPackageFile(b: *std.Build, name: []const u8) []u8 {
    return b.build_root.handle.readFileAlloc(b.graph.io, name, b.allocator, .limited(8 << 20)) catch |err| {
        std.debug.panic("cannot read GMP template {s}: {s}", .{ name, @errorName(err) });
    };
}

/// Build one of GMP's table generators for the host.
///
/// The programs are built for the host because they only compute tables. What
/// decides the target's layout is their argument list, the limb size and the
/// nail count, which `runGenerator` supplies. Upstream builds each generator
/// once and runs it in more than one mode, so `needs_libm` follows that rule
/// and not the individual invocation.
fn generatorProgram(
    b: *std.Build,
    name: []const u8,
    needs_libm: bool,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    // `gen-*.c` include `bootstrap.c` from the top of the GMP tree.
    module.addIncludePath(b.path("."));
    module.addCSourceFiles(.{ .files = &.{b.fmt("{s}.c", .{name})} });
    if (needs_libm) module.linkSystemLibrary("m", .{});
    return b.addExecutable(.{
        .name = b.fmt("{s}-host", .{name}),
        .root_module = module,
    });
}

/// Run a table generator with the target's parameters, returning its standard
/// output as a generated file.
///
/// Each call is its own run step, so the same generator can be run in several
/// modes without one invocation's output colliding with another's.
fn runGenerator(
    b: *std.Build,
    program: *std.Build.Step.Compile,
    args: []const []const u8,
) std.Build.LazyPath {
    const run = b.addRunArtifact(program);
    run.addArgs(args);
    return run.captureStdOut(.{ .basename = b.fmt("{s}.out", .{program.name}) });
}

/// The example program, shared by `smoke`, `run` and `check`.
fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gmp_module: *std.Build.Module,
    library: Library,
    name: []const u8,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("zig/example/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("gmp", gmp_module);
    library.link(module);
    return b.addExecutable(.{ .name = name, .root_module = module });
}

/// The test binary: behaviour tests plus the allocation probe.
fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gmp_module: *std.Build.Module,
    library: Library,
    name: []const u8,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("zig/test/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("gmp", gmp_module);
    library.link(module);
    // The probe exists only to observe GMP's allocator; it is never part of
    // the library. It includes the public header by name, so it needs the
    // generated include directory on its own compile line.
    if (library.cIncludeDir()) |dir| module.addIncludePath(dir);
    module.addCSourceFiles(.{ .files = &.{"zig/test/alloc_probe.c"} });
    module.addIncludePath(b.path("."));
    return b.addTest(.{ .name = name, .root_module = module });
}

/// Source licence and provenance integrity gate.
///
/// Checks that the upstream licence texts are present and unmodified and that
/// the provenance record still carries the archive digest. It needs no Zig
/// build, so CI can run it first.
fn addProvenanceStep(b: *std.Build) void {
    const run = b.addSystemCommand(&.{"sh"});
    run.addFileArg(b.path("tools/provenance_gate.sh"));
    run.addFileArg(b.path("."));
    run.setName("provenance gate");

    const step = b.step("provenance", "Verify the upstream licence texts and provenance record");
    step.dependOn(&run.step);
}
