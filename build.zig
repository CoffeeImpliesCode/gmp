//! Build GMP from the bundled sources with Zig.
//! `-Dlinkage`, `-Druntime`, and `-fsys=gmp` select the build and linkage modes.
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");

const config = @import("zig/config_gen.zig");
const sources = @import("zig/sources.zig");
const runtime = @import("runtime/graph.zig");

const checked_targets = [_][]const u8{
    "x86_64-linux-gnu",
    "aarch64-linux-gnu",
    "aarch64-macos-none",
    "x86_64-windows-gnu",
    "riscv64-linux-gnu",
    "wasm32-wasi",
};

/// GMP 6.3.0 libtool version, from `Makefile.am:107-109`.
const shared_version: std.SemanticVersion = .{ .major = 10, .minor = 5, .patch = 0 };

/// Upstream licence texts included in the install.
const licence_files = [_][]const u8{
    "COPYING",
    "COPYINGv2",
    "COPYINGv3",
    "COPYING.LESSERv3",
};

/// Upstream authorship and release metadata included in the install.
const metadata_files = [_][]const u8{
    "AUTHORS",
    "NEWS",
    "README",
};

/// Fork-authored licence and provenance records included in the install.
/// `README.upstream.md` remains upstream's text under its own terms.
const fork_record_files = [_][]const u8{
    "NOTICE.md",
    "FORK-LICENSE.md",
    "UPSTREAM.md",
    "README.upstream.md",
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const use_system_library = b.systemIntegrationOption("gmp", .{});
    const linkage_option = b.option(
        std.lang.LinkMode,
        "linkage",
        "Build libgmp as a static archive or as a shared library. Static is " ++
            "this fork's default and matches a GMP configured --disable-shared. " ++
            "Dynamic is the --enable-shared form: PIC objects, libtool's own " ++
            "soname, and a generated gmp.h whose __GMP_DECLSPEC exports from " ++
            "the library and imports in everything that links it. In -fsys=gmp " ++
            "mode this graph builds no artifact, so there the option names the " ++
            "kind of installed library to bind to instead.",
    );
    const linkage = linkage_option orelse std.lang.LinkMode.static;
    // Linkage used when binding an installed GMP; system mode defaults to dynamic.
    const system_linkage = linkage_option orelse std.lang.LinkMode.dynamic;

    // Runtime dispatch is opt-in.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Build the runtime-loading configuration: the facade's translated C " ++
            "route becomes the generated dispatch from runtime/graph.zig, every " ++
            "GMP symbol arrives through the platform loader when load runs, and " ++
            "nothing in the graph links libgmp. Off by default, which is the " ++
            "linked configuration.",
    ) orelse false;

    const gmp_module = b.addModule("gmp", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = makeLibrary(
        b,
        target,
        optimize,
        gmp_module,
        use_system_library,
        system_linkage,
        linkage,
        runtime_loaded,
        true,
    );

    const both_loaders = needsBothLoaders(library.artifact(), target);
    // Use separate facades only when install and build-cache paths differ.
    const install_facade = if (both_loaders)
        addInstallFacade(b, target, optimize, library).?
    else
        gmp_module;

    const example = addExample(b, target, optimize, install_facade, "gmp-example");
    b.installArtifact(example);

    const smoke_run = b.addRunArtifact(if (both_loaders)
        addExample(b, target, optimize, gmp_module, "gmp-example-run")
    else
        example);
    smoke_run.step.dependOn(b.getInstallStep());
    smoke_run.addPassthruArgs();
    const smoke_step = b.step("smoke", "Run the example and print deterministic results");
    smoke_step.dependOn(&smoke_run.step);

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&smoke_run.step);

    const tests = addTests(b, target, optimize, gmp_module, library, "gmp-test");
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);

    // Compile the facade, example, and tests for the checked targets without running them.
    const check_step = b.step("check", "Compile the public facade, tests and example");
    if (!target.query.isNative()) {
        addTargetCheck(b, check_step, target.query, .debug, linkage, runtime_loaded, "gmp-check");
    } else {
        for (checked_targets) |triple| {
            const query = std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch |err| {
                std.debug.panic("gmp: cannot parse checked target {s}: {s}", .{ triple, @errorName(err) });
            };
            // WASI has neither shared libraries nor a runtime loader.
            if (query.os_tag == .wasi and (linkage == .dynamic or runtime_loaded)) continue;
            addTargetCheck(
                b,
                check_step,
                query,
                .debug,
                linkage,
                runtime_loaded,
                b.fmt("gmp-check-{s}", .{triple}),
            );
        }
    }

    addProvenanceStep(b);
}

/// Compile the library, facade, example, and tests for one target without running them.
fn addTargetCheck(
    b: *std.Build,
    check_step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
    name: []const u8,
) void {
    const resolved = b.resolveTargetQuery(query);
    const checked_module = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = resolved,
        .optimize = optimize,
    });
    // Check the in-tree library with the same linkage as the main graph.
    const checked_library = makeLibrary(
        b,
        resolved,
        optimize,
        checked_module,
        false,
        linkage,
        linkage,
        runtime_loaded,
        false,
    );

    // Check only the published facade; these binaries are neither run nor installed.
    const checked_example = addExample(
        b,
        resolved,
        optimize,
        checked_module,
        name,
    );
    check_step.dependOn(&checked_example.step);

    const checked_tests = addTests(b, resolved, optimize, checked_module, checked_library, name);
    check_step.dependOn(&checked_tests.step);
}

const Library = union(enum) {
    bundled: Bundled,
    /// System mode links the installed library through the translated module.
    system: void,

    const Bundled = struct {
        step: *std.Build.Step.Compile,
        /// Include directory containing the generated public headers.
        include_dir: std.Build.LazyPath,
        /// False in runtime mode, which must not link the bundled artifact.
        link_artifact: bool,
        /// Translation shared by the published facade and its private variants.
        translate: *std.Build.Step.TranslateC,
        /// One loader core preserves `LoadSource` and `LoadError` identity.
        rt_core: ?*std.Build.Module,

        /// Link this library with the search path required by its loader.
        fn link(
            self: Bundled,
            module: *std.Build.Module,
            target: std.Build.ResolvedTarget,
            loader: Loader,
        ) void {
            if (!self.link_artifact) return;
            linkForLoader(module, self.step, target, loader);
        }
    };

    fn artifact(self: Library) ?*std.Build.Step.Compile {
        return switch (self) {
            .bundled => |bundled| if (bundled.link_artifact) bundled.step else null,
            .system => null,
        };
    }

    /// Generated C include directory, or null in system mode.
    fn cIncludeDir(self: Library) ?std.Build.LazyPath {
        return switch (self) {
            .bundled => |bundled| bundled.include_dir,
            .system => null,
        };
    }
};

/// ELF/Mach-O use prefix-relative paths; Windows loads beside the executable.
/// WASI/UEFI have no runtime search path.
fn installedProgramRPath(target: std.Build.ResolvedTarget) ?[]const u8 {
    return switch (target.result.os.tag) {
        .windows, .wasi, .uefi => null,
        else => if (target.result.os.tag.isDarwin()) "@loader_path/../lib" else "$ORIGIN/../lib",
    };
}

/// Select the install-tree or build-cache loader strategy.
const Loader = enum {
    /// Installed program: use only the prefix-relative library path.
    install_tree,
    /// Build-cache programs and consumers: use the emitted library path.
    build_cache,
};

fn linkForLoader(
    module: *std.Build.Module,
    library: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    loader: Loader,
) void {
    // Static archives need linkLibrary; Windows uses an import library and no rpath.
    if (library.linkage != .dynamic or target.result.os.tag == .windows) {
        module.linkLibrary(library);
        return;
    }
    switch (loader) {
        .build_cache => module.linkLibrary(library),
        .install_tree => {
            module.addObjectFile(library.getEmittedBin());
            if (installedProgramRPath(target)) |rpath| module.addRPathSpecial(rpath);
        },
    }
}

fn needsBothLoaders(
    linked: ?*std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) bool {
    const library = linked orelse return false;
    return library.linkage == .dynamic and target.result.os.tag != .windows;
}

fn makeLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    gmp_module: *std.Build.Module,
    use_system_library: bool,
    system_linkage: std.lang.LinkMode,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
    install: bool,
) Library {
    if (use_system_library) {
        // System linkage and runtime loading are incompatible; reject rather than drop either option.
        if (runtime_loaded) @panic(
            "-fsys=gmp and -Druntime=true cannot be combined: system-library " ++
                "mode links an installed libgmp, and the runtime route reaches " ++
                "the same symbols through the platform loader instead. Drop one " ++
                "of the two options.",
        );
        return makeSystemLibrary(b, target, optimize, gmp_module, system_linkage);
    }
    return .{
        .bundled = makeBundledLibrary(
            b,
            target,
            optimize,
            gmp_module,
            linkage,
            runtime_loaded,
            install,
        ),
    };
}

fn makeBundledLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    gmp_module: *std.Build.Module,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
    install: bool,
) Library.Bundled {
    const params = config.paramsFor(target.result, optimize, linkage == .dynamic);
    const generated = generate(b, optimize, params);

    const library = b.addLibrary(.{
        .name = "gmp",
        .linkage = linkage,
        // Preserve upstream's libtool version on shared objects only.
        .version = if (linkage == .dynamic) shared_version else null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Dynamic artifacts need PIC; static builds retain Zig's default selection.
            .pic = if (linkage == .dynamic) true else null,
        }),
    });

    // GMP's invalid.c and errno.c call raise(SIGFPE); WASI's signal.h requires emulation.
    // Add the toolchain's signal macro and library only for WASI targets.
    if (target.result.os.tag == .wasi) {
        library.root_module.addCMacro("_WASI_EMULATED_SIGNAL", "1");
        // Keep the emulation library dependency on the module that references raise.
        library.root_module.linkSystemLibrary("wasi-emulated-signal", .{});
    }

    // GMP's printf dispatch uses incompatible callback casts (`printf/printffuns.c:76`).
    // Disable the function sanitizer for non-Debug library C builds.
    const c_source_flags: []const []const u8 = if (optimize == .debug)
        &.{"-D__GMP_WITHIN_GMP"}
    else
        &.{ "-D__GMP_WITHIN_GMP", "-fno-sanitize=function" };

    library.root_module.addCSourceFiles(.{
        .files = sources.all,
        .flags = c_source_flags,
    });
    library.root_module.addCSourceFiles(.{
        .root = generated.directory,
        .files = &sources.generated,
        .flags = c_source_flags,
    });
    // Give each mpn template operation a source file with its `OPERATION_*` macro set.
    library.root_module.addCSourceFiles(.{
        .root = generated.directory,
        .files = generated.operation_sources,
        .flags = c_source_flags,
    });
    // Generated headers used by GMP's internal C sources.
    library.root_module.addIncludePath(generated.directory);
    // Source root for private GMP headers.
    library.root_module.addIncludePath(b.path("."));

    // Install generated public headers and the fork's aggregate translation header.
    // Keep private `config.h` out of the install to avoid shadowing consumers' configuration.
    library.installHeader(generated.gmp_header, "gmp.h");
    library.installHeader(generated.mparam_header, "gmp-mparam.h");
    library.installHeader(b.path("include/gmp_all.h"), "gmp_all.h");

    // Runtime mode replaces the linked C import with the generated dispatch.
    const translate = translateC(b, target, optimize, generated);
    var rt_core: ?*std.Build.Module = null;
    if (runtime_loaded) {
        gmp_module.addImport("c", runtime.createModule(b, translate, target, optimize));
    } else {
        addTranslatedApi(gmp_module, translate);
        // The public and installed facades share translation and loader core.
        linkForLoader(gmp_module, library, target, .build_cache);
        rt_core = runtime.createCoreModule(b, target, optimize);
        gmp_module.addImport("rt", rt_core.?);
    }

    if (install) {
        b.installArtifact(library);
        // Install relocatable pkg-config metadata beside the library.
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            generated.pkgconfig,
            .lib,
            "pkgconfig/gmp.pc",
        ).step);
        addInstalledRecords(b);
    }
    return .{
        .step = library,
        .include_dir = generated.directory,
        .link_artifact = !runtime_loaded,
        .translate = translate,
        .rt_core = rt_core,
    };
}

/// Use the target's installed header and library so their declarations match.
/// System mode is linked and cannot combine with runtime loading.
fn makeSystemLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    gmp_module: *std.Build.Module,
    system_linkage: std.lang.LinkMode,
) Library {
    const translate = translateC(b, target, optimize, null);
    translate.linkSystemLibrary("gmp", .{ .preferred_link_mode = system_linkage });

    addTranslatedApi(gmp_module, translate);
    gmp_module.addImport("rt", runtime.createCoreModule(b, target, optimize));
    return .{ .system = {} };
}

/// Preprocessing route for the target's aggregate header.
const AggregateRoute = enum { aro, preprocessed };

/// Non-Linux cross targets need preprocessing to exclude translator host headers.
/// Clang-preprocessed glibc float typedefs conflict with Aro's type specifiers.
fn aggregateRoute(target: std.Build.ResolvedTarget) AggregateRoute {
    if (!target.query.isNative() and target.result.os.tag != .linux) return .preprocessed;
    return switch (target.result.os.tag) {
        .netbsd, .openbsd => .preprocessed,
        else => .aro,
    };
}

/// Preprocess the aggregate header with the target compiler.
/// `-dD` preserves public macros; the depfile tracks the headers opened by this step.
fn preprocessedAggregate(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    generated: ?Generated,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&[_][]const u8{ b.graph.zig_exe, "cc", "-E", "-dD" });
    run.setName("preprocess gmp gmp_all.h");
    run.addArgs(&.{
        "-DGMP_ZIG_TRANSLATE=1",
        b.fmt("-DGMP_ZIG_HAVE_OBSTACK={s}", .{if (target.result.isGnuLibC()) "1" else "0"}),
    });
    if (!target.query.isNative()) {
        const triple = target.query.zigTriple(b.allocator) catch @panic("gmp: unspellable target");
        run.addArg("-target");
        run.addArg(triple);
    }
    if (generated) |tree| {
        // Match the translation step's include root so both read the same `gmp.h`.
        run.addDirectoryArg2(tree.directory, .{ .prefix = "-I" });
        // Declare the generated header as a direct graph dependency.
        tree.gmp_header.addStepDependencies(&run.step);
    }
    run.addArg("-o");
    const preprocessed = run.addOutputFileArg2("gmp-translate.c", .{});
    run.addArg("-MD");
    _ = run.addDepFileOutputArg2("gmp-translate.d", .{ .prefix = "-MF" });
    run.addFileArg2(b.path("include/gmp_all.h"), .{});
    return preprocessed;
}

/// Translate the aggregate header with generated or system `gmp.h`.
fn translateC(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    generated: ?Generated,
) *std.Build.Step.TranslateC {
    const translate = b.addTranslateC(.{
        .root_source_file = switch (aggregateRoute(target)) {
            .aro => b.path("include/gmp_all.h"),
            .preprocessed => preprocessedAggregate(b, target, generated),
        },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate.defineCMacro("GMP_ZIG_TRANSLATE", "1");
    translate.defineCMacro("GMP_ZIG_HAVE_OBSTACK", if (target.result.isGnuLibC()) "1" else "0");
    if (generated) |tree| translate.addIncludePath(tree.directory);
    return translate;
}

fn addTranslatedApi(gmp_module: *std.Build.Module, translate: *std.Build.Step.TranslateC) void {
    gmp_module.addImport("c", translate.createModule());
}

fn addInstalledRecords(b: *std.Build) void {
    for (licence_files ++ fork_record_files) |name| {
        b.installFile(name, b.pathJoin(&.{ "share", "licenses", "gmp", name }));
    }
    for (metadata_files) |name| {
        b.installFile(name, b.pathJoin(&.{ "share", "doc", "gmp", name }));
    }
}

const Generated = struct {
    directory: std.Build.LazyPath,
    gmp_header: std.Build.LazyPath,
    mparam_header: std.Build.LazyPath,
    pkgconfig: std.Build.LazyPath,
    operation_sources: []const []const u8,
};

fn generate(
    b: *std.Build,
    optimize: std.lang.Optimize,
    params: config.Params,
) Generated {
    const output = b.addWriteFiles();

    const gmp_h_in = readPackageFile(b, "gmp-h.in");
    const config_in = readPackageFile(b, "config.in");

    const cflags = b.fmt("zig cc -O{s} -DNO_ASM", .{@tagName(optimize)});
    const gmp_header = output.add(
        "gmp.h",
        config.renderGmpH(b.allocator, gmp_h_in, params, cflags) catch @panic("OOM"),
    );
    _ = output.add(
        "config.h",
        config.renderConfigH(b.allocator, config_in, params) catch @panic("OOM"),
    );
    // Match configure's gmp-mparam selection to mpn/generic.
    const mparam_header = output.addCopyFile(b.path("mpn/generic/gmp-mparam.h"), "gmp-mparam.h");

    const pkgconfig = output.add(
        "gmp.pc",
        config.renderPkgConfig(
            b.allocator,
            readPackageFile(b, "gmp.pc.in"),
        ) catch @panic("OOM"),
    );

    const limb_bits = b.fmt("{d}", .{params.limb_bits});
    const nail_bits = b.fmt("{d}", .{params.nail_bits});

    // Host generators produce tables parameterized by the target limb and nail sizes.
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

    // Each mpn template operation needs its own generated source and object.
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
        .pkgconfig = pkgconfig,
        .operation_sources = operation_sources.items,
    };
}

fn readPackageFile(b: *std.Build, name: []const u8) []u8 {
    b.dependOnFileContents(b.path(name));
    const root_relative_path = if (b.root.sub_path.len == 0) name else std.fs.path.join(b.allocator, &.{ b.root.sub_path, name }) catch @panic("OOM");
    return b.root.root_dir.handle.readFileAlloc(b.graph.io, root_relative_path, b.allocator, .limited(8 << 20)) catch |err| {
        std.debug.panic("cannot read GMP template {s}: {s}", .{ name, @errorName(err) });
    };
}

/// Build a host table generator; `needs_libm` follows the corresponding upstream rule.
fn generatorProgram(
    b: *std.Build,
    name: []const u8,
    needs_libm: bool,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = b.graph.host,
        .optimize = .safe,
        .link_libc = true,
    });
    // gen-*.c includes bootstrap.c from the package root.
    module.addIncludePath(b.path("."));
    module.addCSourceFiles(.{ .files = &.{b.fmt("{s}.c", .{name})} });
    if (needs_libm) module.linkSystemLibrary("m", .{});
    return b.addExecutable(.{
        .name = b.fmt("{s}-host", .{name}),
        .root_module = module,
    });
}

fn runGenerator(
    b: *std.Build,
    program: *std.Build.Step.Compile,
    args: []const []const u8,
) std.Build.LazyPath {
    const run = b.addRunArtifact(program);
    run.addArgs(args);
    return run.captureStdOut(.{ .basename = b.fmt("{s}.out", .{program.name}) });
}

fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    gmp_module: *std.Build.Module,
    name: []const u8,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("zig/example/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("gmp", gmp_module);
    return b.addExecutable(.{ .name = name, .root_module = module });
}

/// Create the installed example's facade while reusing shared translation and loader state.
fn addInstallFacade(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    library: Library,
) ?*std.Build.Module {
    const bundled = switch (library) {
        .bundled => |value| value,
        // System mode has no bundled shared object or install-tree path.
        .system => return null,
    };
    const module = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
    addTranslatedApi(module, bundled.translate);
    if (bundled.rt_core) |core| module.addImport("rt", core);
    bundled.link(module, target, .install_tree);
    return module;
}

/// Build behavior tests and the allocator probe against the facade.
fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
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
    // The C probe includes `gmp.h` directly and needs the generated include path.
    if (library.cIncludeDir()) |dir| module.addIncludePath(dir);
    module.addCSourceFiles(.{ .files = &.{"zig/test/alloc_probe.c"} });
    module.addIncludePath(b.path("."));
    return b.addTest(.{ .name = name, .root_module = module });
}

fn addProvenanceStep(b: *std.Build) void {
    const run = b.addSystemCommand(&.{"sh"});
    run.addFileArg2(b.path("tools/provenance_gate.sh"), .{});
    run.addDirectoryArg2(b.path("."), .{});
    run.setName("provenance gate");

    const step = b.step("provenance", "Verify the upstream licence texts and provenance record");
    step.dependOn(&run.step);
}
