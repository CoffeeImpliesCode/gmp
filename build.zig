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
//!      at build time. `-Dlinkage` chooses the shape of that artifact. On a
//!      WASI target the same step additionally selects the toolchain's own
//!      signal emulation - the `_WASI_EMULATED_SIGNAL` its `signal.h`
//!      demands and its `libwasi-emulated-signal.a` - because GMP's
//!      `invalid.c` and `errno.c` include `<signal.h>` and raise `SIGFPE`.
//!      That is the only thing WASI changes, and it changes no source.
//!   4. Exposes the result as the module `gmp` (facade plus the complete
//!      translated C API) and as the library artifact `gmp`, whose
//!      include tree carries the generated `gmp.h`, so a dependent needs only
//!      `dep.artifact("gmp")` or `dep.module("gmp")`. Under `-fsys=gmp` the
//!      module is published and the artifact is not: that graph compiles and
//!      installs no library of ours, and it puts the installed `libgmp` on
//!      the translated `c` module itself, so `dep.module("gmp")` links it
//!      and `dep.artifact("gmp")` does not resolve. A dependent tells the two
//!      apart with `b.systemIntegrationOption("gmp", .{})`, which reads the
//!      one shared answer this graph reads. Installing also lays down the
//!      four upstream licence texts, the upstream authorship and release
//!      records, and the `gmp.pc` that `configure` would have written.
//!
//!      Nothing is filtered out of that translation, and it is Aro's except on
//!      NetBSD and OpenBSD: there the target's own compiler preprocesses the
//!      same aggregate first, because those two families ship headers Aro
//!      cannot read (`aggregateRoute`).
//!
//! Steps: `zig build` installs the library, `zig build test` runs the tests in
//! the current optimize mode, `zig build smoke` and `zig build run` run the
//! example, `zig build check` compiles the whole public surface for all six
//! supported targets without running anything, and `zig build provenance`
//! re-checks the licence and provenance records.
//!
//! Delivery options. None of them is required for a default build.
//!
//!   * `-Dlinkage=static|dynamic` picks the artifact this graph compiles. The
//!     default is `static`, which is what this fork has always built and what
//!     a GMP configured `--disable-shared` produces. `dynamic` is upstream's
//!     `--enable-shared` form: every object is compiled PIC, the shared
//!     object carries libtool's own version and soname, and the generated
//!     `gmp.h` sets `__GMP_LIBGMP_DLL` to 1 so `__GMP_DECLSPEC` exports from
//!     the library and imports in everything that links it. In `-fsys=gmp`
//!     mode this graph compiles no artifact at all, so there the same option
//!     names the kind of installed library to bind to instead.
//!   * `-Druntime=true|false` picks how the facade's C route reaches GMP. The
//!     default is `false`, the linked configuration this fork has always
//!     built, where the translated module calls into the archive directly.
//!     `true` replaces that module with the generated dispatch from
//!     `runtime/graph.zig`: every GMP symbol then arrives through the platform
//!     loader at run time, and nothing in the graph links libgmp, so `load`
//!     is what resolves them. The library is still compiled and installed -
//!     the loader has to find something to open - and the two options are
//!     independent, because `-Druntime=true -Dlinkage=static` is the external
//!     provider route: nothing in this build can be opened, so the caller
//!     names a GMP elsewhere by path or system name.
//!   * `-Dtarget=`, `-Doptimize=`, `-Dcpu=` and the other standard options,
//!     and `-fsys=gmp` to bind an installed GMP instead of compiling this
//!     tree. That one is the toolchain's own system library integration and is
//!     answered from the build graph every package in the process shares, so
//!     a dependent reads it rather than forwarding it. `-fsys=gmp` and
//!     `-Druntime=true` are refused together by name, at configure time and
//!     before any source is generated: one of them links a library and the
//!     other resolves the same symbols through the platform loader, and
//!     neither is ever substituted for the other.
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");

const config = @import("zig/config_gen.zig");
const sources = @import("zig/sources.zig");
const runtime = @import("runtime/graph.zig");

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

/// GMP's own libtool version numbers, read from `Makefile.am:107-109`:
/// `LIBGMP_LT_CURRENT 15`, `LIBGMP_LT_REVISION 0`, `LIBGMP_LT_AGE 5`.
/// Libtool names the file `libNAME.so.CURRENT-AGE.AGE.REVISION` and gives it
/// the soname `libNAME.so.CURRENT-AGE`, which for GMP 6.3.0 is
/// `libgmp.so.10.5.0` carrying `libgmp.so.10` - the names a system GMP
/// installs, and the ones a runtime loader can ask for by basename. Zig
/// spells those same three numbers as a `SemanticVersion`, and installs the
/// `libgmp.so.10` and `libgmp.so` symlinks beside the file itself.
const shared_version: std.SemanticVersion = .{ .major = 10, .minor = 5, .patch = 0 };

/// The upstream licence texts this release ships. `COPYING` is GPLv3,
/// `COPYINGv3` the same text and `COPYINGv2` and `COPYING.LESSERv3` the
/// other two grants GMP is available under; all four travel with the
/// library, which is what `AGENTS.md` §8 requires of a redistribution.
const licence_files = [_][]const u8{
    "COPYING",
    "COPYINGv2",
    "COPYINGv3",
    "COPYING.LESSERv3",
};

/// Upstream metadata a redistributor needs beside the library. `AUTHORS` is
/// the GPL §1 authorship record, and `NEWS` and `README` are the release
/// notes upstream ships. They go to automake's own `$(datadir)/doc/gmp`
/// rather than to the licence directory, because they are not licence texts.
const metadata_files = [_][]const u8{
    "AUTHORS",
    "NEWS",
    "README",
};

/// The records this fork authors. They install beside the upstream grants
/// because they are terms of the same redistribution: `NOTICE.md` is the
/// per-file inventory, `FORK-LICENSE.md` the authorization and grant that
/// covers them, `UPSTREAM.md` where the imported bytes came from, and
/// `README.upstream.md` upstream's own `README`, kept under a name this fork's
/// `README.md` does not overwrite (`FORK-NOTES.md` 33). `README.upstream.md`
/// is upstream's text, so it travels as a copy of it and not under the fork's
/// grant, which is what `NOTICE.md` and `FORK-LICENSE.md` each say.
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
        std.builtin.LinkMode,
        "linkage",
        "Build libgmp as a static archive or as a shared library. Static is " ++
            "this fork's default and matches a GMP configured --disable-shared. " ++
            "Dynamic is the --enable-shared form: PIC objects, libtool's own " ++
            "soname, and a generated gmp.h whose __GMP_DECLSPEC exports from " ++
            "the library and imports in everything that links it. In -fsys=gmp " ++
            "mode this graph builds no artifact, so there the option names the " ++
            "kind of installed library to bind to instead.",
    );
    const linkage = linkage_option orelse std.builtin.LinkMode.static;
    // The kind of installed library `-fsys=gmp` binds to, kept apart from
    // `linkage` because that one describes what this graph compiles and system
    // mode compiles none. Only the main graph sets it; a cross-target check
    // always builds from the in-tree sources and reads nothing. Without an
    // explicit `-Dlinkage` this stays at `Module.linkSystemLibrary`'s own
    // dynamic default, which is what this fork has always linked in that mode.
    const system_linkage = linkage_option orelse std.builtin.LinkMode.dynamic;

    // Which of the two C routes the facade is built against. Off by default,
    // so every existing gate keeps compiling the linked configuration.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Build the runtime-loading configuration: the facade's translated C " ++
            "route becomes the generated dispatch from runtime/graph.zig, every " ++
            "GMP symbol arrives through the platform loader when load runs, and " ++
            "nothing in the graph links libgmp. Off by default, which is the " ++
            "linked configuration.",
    ) orelse false;

    // Registered up front so `dep.module("gmp")` resolves for dependents.
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

    // The example, built once for the install tree and once for the build
    // cache.
    //
    // The published `gmp` module carries the build cache's own entry, and
    // that is what it has to carry. `linkLibrary` records the directory the
    // shared object was emitted into, and `Step.Compile` puts an `-rpath` for
    // it on every compilation that imports the module -- a dependent's
    // executable among them, which is itself built out of a build cache, and
    // so has the shared object's real directory to look in. Everything of this
    // build that never leaves the build cache is the same case: the test
    // binary, and the copy of the example `smoke` and `run` execute.
    //
    // `bin/gmp-example` is installed, so it is the exception and wants the
    // install tree's `$ORIGIN/../lib` and nothing else: the entry that names
    // the build cache is a directory that is gone once the file is installed
    // and is something Nix refuses to package at all. It is therefore
    // compiled from a second, *private* facade, which puts the same shared
    // object on the link line with `addObjectFile` and adds the install tree's
    // entry and nothing else. One binary cannot carry both search paths, so
    // the two are compiled separately from one source file and one set of
    // options, and the only thing that differs is the facade each one imports.
    //
    // Under `-Dlinkage=static`, under `-fsys=gmp` and under `-Druntime=true`
    // the two flavours are the same file, and `needsBothLoaders` says so:
    // nothing is compiled twice and the example below is the copy that runs.
    const both_loaders = needsBothLoaders(library.artifact(), target);
    // `both_loaders` is only true for a bundled shared library on a platform
    // with a runpath, which is exactly the case `addInstallFacade` answers for.
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
    if (b.args) |args| smoke_run.addArgs(args);
    const smoke_step = b.step("smoke", "Run the example and print deterministic results");
    smoke_step.dependOn(&smoke_run.step);

    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&smoke_run.step);

    // A test binary is never installed, so the published module is already the
    // flavour it wants.
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
        addTargetCheck(b, check_step, target.query, .Debug, linkage, runtime_loaded, "gmp-check");
    } else {
        for (checked_targets) |triple| {
            // Zig 0.16's `Target.Query` has no `arch_os_abi` field: a triple is
            // parsed by `std.Build.parseTargetQuery`, which is what
            // `standardTargetOptions` itself uses for `-Dtarget`.
            const query = std.Build.parseTargetQuery(.{ .arch_os_abi = triple }) catch |err| {
                std.debug.panic("gmp: cannot parse checked target {s}: {s}", .{ triple, @errorName(err) });
            };
            addTargetCheck(
                b,
                check_step,
                query,
                .Debug,
                linkage,
                runtime_loaded,
                b.fmt("gmp-check-{s}", .{triple}),
            );
        }
    }

    addProvenanceStep(b);
}

/// Compiles the library, the facade module, the example and the test binary
/// for one target and attaches them to `check_step`. Nothing is run: a
/// cross-compiled binary cannot run on the host. `linkage` is the linkage the
/// main graph was asked for, so `check` compiles the artifact that graph would
/// really deliver rather than a static one nobody asked for. `runtime_loaded`
/// is carried the same way, so `check -Druntime=true` compiles the dispatch
/// and its loader core rather than quietly checking the linked route instead.
fn addTargetCheck(
    b: *std.Build,
    check_step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    name: []const u8,
) void {
    const resolved = b.resolveTargetQuery(query);
    const checked_module = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = resolved,
        .optimize = optimize,
    });
    // The C route is the one the main graph was asked for; a cross-target
    // check never binds an installed library, so the system linkage it passes
    // is the one this graph would have built.
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

    // Compile-only: nothing in this matrix runs and nothing in it is
    // installed, so the published module's own flavour is the one worth
    // compiling and a second facade would prove nothing.
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

/// How consumers link GMP: the artifact this build produces, or an installed
/// system library.
const Library = union(enum) {
    bundled: Bundled,
    /// System-library mode, which carries nothing and that is the whole of
    /// what a dependent has to tell apart: this graph compiles no artifact
    /// and installs none under that name, so `dep.artifact("gmp")` does not
    /// resolve here, and it reaches GMP through the `linkSystemLibrary`
    /// entry `makeSystemLibrary` puts on the translated `c` module. Every
    /// module in a compilation's graph is on that compilation's link line
    /// (`lib/std/Build/Step/Compile.zig:1080-1088`), so importing
    /// `dep.module("gmp")` links the installed library on its own.
    system: void,

    const Bundled = struct {
        step: *std.Build.Step.Compile,
        /// Directory holding the generated `gmp.h`. It lives in the build
        /// cache, not in the source tree, so any C source of this build that
        /// includes the public header by name needs it on its own compile
        /// line; linking the artifact does not add include paths.
        include_dir: std.Build.LazyPath,
        /// False in a runtime-loading configuration. The archive is still
        /// built and installed there, because the loader has to have something
        /// to open, but nothing in the graph may link it: a module that
        /// imports the generated dispatch and also links libgmp lets the
        /// linker resolve every symbol statically, and the runtime route
        /// quietly becomes a linked one that never calls `load`.
        link_artifact: bool,
        /// The translation step the facade's `c` import was made from. A second
        /// facade for the same target reads this one, so both declare the same
        /// GMP rather than two translations of the same header.
        translate: *std.Build.Step.TranslateC,
        /// The loader core the facade was given its `rt` import from, or null
        /// in a runtime-loading configuration. One core per build and not one
        /// per facade: `LoadSource` and `LoadError` are published by name, and
        /// two cores would be two sets of those two types.
        rt_core: ?*std.Build.Module,

        /// Put this library on `module`'s link line, with the search path a
        /// program of this `Loader` needs and nothing else.
        fn link(
            self: Bundled,
            module: *std.Build.Module,
            target: std.Build.ResolvedTarget,
            loader: Loader,
        ) void {
            if (!self.link_artifact) return;
            // The library goes on this module's own link line, and the
            // search path that comes with it is `Loader`'s decision: a
            // module's entry lands on every compilation that imports it,
            // so one module cannot serve both an installed program and
            // everything else. See `linkForLoader`, and
            // `addInstallFacade` for the module an installed program is
            // built from.
            linkForLoader(module, self.step, target, loader);
        }
    };

    /// The shared object of a bundled build, when the graph links it at all.
    fn artifact(self: Library) ?*std.Build.Step.Compile {
        return switch (self) {
            .bundled => |bundled| if (bundled.link_artifact) bundled.step else null,
            .system => null,
        };
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

/// The runtime search path an installed program needs so that its loader
/// finds the library this same prefix installed beside it.
///
/// `bin/gmp-example` and `lib/libgmp.so` are siblings under one prefix, so
/// `$ORIGIN/../lib` is the ELF spelling and `@loader_path/../lib` the Mach-O
/// one, and both name this install tree and no other.  COFF has neither:
/// `installArtifact` puts `libgmp-10.dll` into `bin/` beside the program,
/// which is where its loader looks first.  A target with no dynamic loader
/// has nothing to name either.
fn installedProgramRPath(target: std.Build.ResolvedTarget) ?[]const u8 {
    return switch (target.result.os.tag) {
        .windows, .wasi, .uefi => null,
        else => if (target.result.os.tag.isDarwin()) "@loader_path/../lib" else "$ORIGIN/../lib",
    };
}

/// Where a program built against this SDK's shared library must find it.
///
/// The two are not two spellings of one answer, and one program cannot carry
/// both: `Module.linkLibrary` records the directory the shared object was emitted
/// into, because `Step.Compile` appends `-rpath <dir>` for every dynamic
/// artifact a compilation links (`lib/std/Build/Step/Compile.zig:1290-1297`,
/// the block reached from `.other_step`).  That directory is the build cache.
/// It does not exist once the file is installed, and Nix refuses an installed
/// file that names its own build directory at all, so an installed program
/// that carried it could never be packaged.  `Module.addObjectFile` puts the
/// very same file on the link line and records no search path at all, which
/// leaves the relocatable entry `installedProgramRPath` returns as the only
/// one an installed artifact carries.
///
/// Which of the two a facade gets is a property of the *program* that imports
/// it, and a published facade has dependents of both kinds. The entry a module
/// contributes lands on every compilation whose graph imports that module, so
/// the published `gmp` module is `build_cache`: a dependent's executable is
/// built out of a build cache and finds the shared object in the one Zig baked
/// in. Only `bin/gmp-example` is built from an `install_tree` facade, and it
/// is built from a private one for that purpose.
const Loader = enum {
    /// A program `zig build install` writes into `bin/`.  It carries
    /// `$ORIGIN/../lib` -- `@loader_path/../lib` on Mach-O -- and nothing else,
    /// so it finds the library this prefix installed beside it and still finds
    /// it after the tree is moved.
    install_tree,
    /// Everything that is not installed, the published facade included: a
    /// dependent's executable, the test binary, and the copy of the example
    /// `smoke` and `run` execute.  It keeps the ordinary `linkLibrary` call, so
    /// Zig bakes in the directory the library really is in and the loader
    /// looks there.  The entry never reaches a store, because nothing built
    /// this way is ever installed.
    build_cache,
};

/// Put `library` on `module`'s link line, with the search path a program of
/// this `Loader` needs and nothing else.
fn linkForLoader(
    module: *std.Build.Module,
    library: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    loader: Loader,
) void {
    // Windows links through the import library and has no rpath, so the
    // ordinary call is the right one there for both loaders and is kept. A
    // static archive has no runtime search path either: `linkLibrary` is what
    // puts a static library's own link objects on every dependent's line
    // (`lib/std/Build/Step/Compile.zig:1162-1180` chases a static library but
    // not a shared one), and this graph has always been checked that way.
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

/// Whether a target's programs have to be compiled twice to have both loaders.
///
/// A static archive, an import-library link on COFF and a facade that links no
/// library at all all produce the same file for both `Loader` values, so a
/// second module would be a second copy of a binary that is already right.  A
/// shared library on a platform with a runpath is the one case where they
/// differ, and it is the only case that pays for the second compilation.
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
    optimize: std.builtin.OptimizeMode,
    gmp_module: *std.Build.Module,
    use_system_library: bool,
    system_linkage: std.builtin.LinkMode,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    install: bool,
) Library {
    if (use_system_library) {
        // `-Druntime=true` must not reach this branch quietly. It is not
        // forwarded to `makeSystemLibrary`, which links an installed library,
        // so the build would link it, exit 0, and leave the caller believing
        // it had exercised the loaded route. There is no fallback from one
        // configuration to the other and no automatic load, so the pair is
        // refused by name at configure time.
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

/// Build the real libgmp from this repository.
fn makeBundledLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gmp_module: *std.Build.Module,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    install: bool,
) Library.Bundled {
    const params = config.paramsFor(target.result, optimize, linkage == .dynamic);
    const generated = generate(b, optimize, params);

    const library = b.addLibrary(.{
        .name = "gmp",
        .linkage = linkage,
        // Upstream's own libtool numbers, so a shared libgmp installs under
        // the file name and soname a system GMP has. A static archive has no
        // version, so this stays null there and `libgmp.a` is unchanged.
        .version = if (linkage == .dynamic) shared_version else null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // A shared object has to be relocatable, so every object in it -
            // every core translation unit, both generated tables and each
            // generated mpn template wrapper - is compiled `-fPIC`.
            //
            // The static route passes `null`, not `false`. `Module.pic` is a
            // `?bool` and `appendZigProcessFlags` emits `-fPIC`, `-fno-PIC`
            // or nothing for true, false and null respectively
            // (`std/Build/Module.zig:252,554`), so `false` would add a flag
            // the static archive has never been compiled with and would make
            // `-Dlinkage=static` a change rather than the no-op it has to be.
            // Null leaves the driver to choose, exactly as before.
            //
            // This build's external link closure is libc and nothing else:
            // no compiled source includes `<math.h>`, so no libm symbol is
            // referenced. The three table generators that do need libm are
            // host build-time programs and are never part of the artifact.
            .pic = if (linkage == .dynamic) true else null,
        }),
    });

    // WASI signal emulation, and only for WASI.
    //
    // GMP asks for a signal in two compiled translation units: `invalid.c:37`
    // and `errno.c:37` include `<signal.h>` unconditionally, and
    // `__gmp_invalid_operation` and `__gmp_exception` call `raise (SIGFPE)`
    // (`invalid.c:80`, `errno.c:52`). This toolchain's
    // `wasm-wasi-musl/signal.h:1-3` is a bare `#error` unless
    // `_WASI_EMULATED_SIGNAL` is defined, so on `wasm32-wasi` those two files
    // are not parseable at all without it. That is the whole of the
    // `wasm32-wasi` failure of `check`, recorded in `FORK-NOTES.md` under
    // "`invalid.c` and a libc without signals". `configure.ac` has no wasm
    // branch, so nothing upstream would set this; the configuration has to
    // come from the target's libc, and it is therefore a property of this
    // build rather than a fact about `config.h`.
    //
    // The provider is the one this toolchain's own WASI sysroot ships:
    // `lib/libc/wasi/libc-bottom-half/signal/signal.c` is compiled into the
    // target's `libwasi-emulated-signal.a`, and `lib/std/zig/target.zig:384`
    // lists `wasi-emulated-signal` among the library names a WASI+musl target
    // is known to have, so the linker resolves that name to that archive with
    // no search path of its own. It delivers a signal synchronously and ends
    // the module through its own exit; it is an emulation over what WASI has,
    // not a POSIX signal namespace.
    //
    // Nothing is surrendered to get there: no source is omitted, no
    // substitute for `raise` is written, no macro is invented, and
    // `HAVE_RAISE` stays 1, which is what keeps `invalid.c:49-51` off its
    // `kill (getpid (), sig)` fallback. Both statements sit inside the
    // `os.tag == .wasi` test, so the other five checked targets are given
    // nothing they did not have before.
    if (target.result.os.tag == .wasi) {
        library.root_module.addCMacro("_WASI_EMULATED_SIGNAL", "1");
        // Linked on the module that holds the reference to `raise`. A
        // dependent that links this archive inherits it, because
        // `Step.Compile.getCompileDependencies(false)` walks a static
        // library's `link_objects` and puts every `system_lib` it finds on
        // the dependee's linker line
        // (`lib/std/Build/Step/Compile.zig:1064-1088`); under
        // `-Dlinkage=dynamic` the same entry is on the shared object's own
        // link line, which is where a dependent would look for it anyway.
        library.root_module.linkSystemLibrary("wasi-emulated-signal", .{});
    }

    // One compiler check is excepted from Zig's C undefined-behaviour
    // detection, and only for GMP's own native C, and only where Zig's
    // default turns that detection on.
    //
    // Zig leaves `Module.sanitize_c` null unless a module says otherwise, and
    // null emits no `-fsanitize-c` flag at all
    // (`std/Build/Module.zig:558-562`), so the compiler's own default stands.
    // That default instruments the C sources of a release-safe build with
    // clang's undefined-behaviour detection, whose `function` member writes an
    // eight byte `0xc105cafe` signature plus a hash of the function type in
    // front of every function entry and verifies it at every indirect call. A
    // debug build carries no such signature, so only the release-safe modes
    // could reach it.
    //
    // GMP's `printf` dispatch cannot satisfy that check. Each of the four slots
    // of `struct doprnt_funs_t` is declared with a `void *` first parameter
    // (`gmp-impl.h:4540-4543`) and is filled by casting a function whose first
    // parameter is a concrete struct pointer. All five initializers do that:
    // `printf/snprntffuns.c:152-158`, `printf/sprintffuns.c:89-94`,
    // `printf/vasprintf.c:103-108`, `printf/printffuns.c:75-79` and
    // `printf/obprntffuns.c:65-69`; `printf/printffuns.c:76` casts libc's own
    // `vfprintf`. That cast is undefined behaviour upstream and is the only
    // thing the check can see, so the first indirect call through the table -
    // `DOPRNT_FORMAT (last_fmt, last_ap)` at `printf/doprnt.c:612` - traps on
    // it before a character is formatted.
    //
    // Upstream source stays byte-for-byte, so the exception is the flag and
    // nothing else: every other C undefined-behaviour check, every Zig safety
    // check and the optimize mode are untouched, `Module.sanitize_c` is still
    // null so Zig emits no `-fsanitize-c` flag for this module, and the flag
    // lands after the module's own options on the C command line.
    //
    // Three other C translation units of this build keep the check, and each is
    // a case where adding the flag would buy nothing.
    //
    // `generatorProgram` compiles `gen-fib`, `gen-bases`, `gen-fac`,
    // `gen-sieve`, `gen-psqr`, `gen-trialdivtab` and `gen-jacobitab` for
    // `b.graph.host` at a fixed `ReleaseSafe`, and they are build-time programs
    // that never enter the artifact. None of the seven, nor the `bootstrap.c`
    // they include, converts a function pointer: the only casts in them are
    // object-pointer casts, which this check does not instrument. The host
    // generators are not GMP native code for the target and are not given the
    // target's flags, so they are not given the target's exception either.
    // `runtime/sync.c` (`runtime/graph.zig`) and `zig/test/alloc_probe.c`
    // (`addTests`) are fork-authored, and between them declare no function
    // pointer at all: `sync.c` is five weak wrappers around one lock and one
    // condition variable per prefix, and the probe is called by name from
    // `alloc_probe.zig`.
    const c_source_flags: []const []const u8 = if (optimize == .Debug)
        &.{"-D__GMP_WITHIN_GMP"}
    else
        &.{ "-D__GMP_WITHIN_GMP", "-fno-sanitize=function" };

    // The library sources. `__GMP_WITHIN_GMP` is what upstream's `Makefile.am`
    // passes on `AM_CPPFLAGS`. Nothing else is needed on the command line:
    // `gmp-impl.h` includes the generated `config.h`, so every configuration
    // macro, `NO_ASM` and `HAVE_ALLOCA` included, is already in effect.
    library.root_module.addCSourceFiles(.{
        .files = sources.all,
        .flags = c_source_flags,
    });
    // The two tables GMP generates at build time live in the generated
    // directory, not in the source tree.
    library.root_module.addCSourceFiles(.{
        .root = generated.directory,
        .files = &sources.generated,
        .flags = c_source_flags,
    });
    // One translation unit per operation of every multi-function mpn
    // template. A template cannot be compiled on its own, so none of them is
    // in `sources.all`; each operation is a wrapper that selects one.
    library.root_module.addCSourceFiles(.{
        .root = generated.directory,
        .files = generated.operation_sources,
        .flags = c_source_flags,
    });
    // Generated `gmp.h`, `config.h`, `gmp-mparam.h` and the table headers,
    // which `gmp-impl.h` and a few `mpn` files include by bare name.
    library.root_module.addIncludePath(generated.directory);
    // `gmp-impl.h` and `longlong.h` from the top of the tree.
    library.root_module.addIncludePath(b.path("."));

    // GMP's installed public header set, which is what upstream ships:
    // `nodist_includeexec_HEADERS = gmp.h` (`Makefile.am:144`), generated per
    // target, and the `gmp-mparam.h` that `configure` links to the selected
    // mpn path. Installing them into the artifact's include tree is what puts
    // `gmp.h` on a dependent's compile line, so a dependent needs only
    // `dep.artifact("gmp")` and never the source tree. `gmp_all.h` is this
    // fork's aggregate translation unit; it is what pulls in the stdio and
    // `va_list` declarations `gmp.h` hides behind `FILE`, so an installed C
    // consumer can reach the whole public API through one header as well.
    //
    // GMP's internal `config.h` is deliberately not installed. It is private
    // to building this tree, and publishing it would shadow the `config.h` of
    // any autotools-configured dependent, which is the same failure mode as
    // linking new headers against an older installed library.
    library.installHeader(generated.gmp_header, "gmp.h");
    library.installHeader(generated.mparam_header, "gmp-mparam.h");
    library.installHeader(b.path("include/gmp_all.h"), "gmp_all.h");

    // The facade's C route. Linked, it is the translation step's own module
    // and the archive is linked beside it. Runtime-loaded, the same
    // translation step feeds `runtime/graph.zig`, which generates a dispatch
    // that reaches every symbol through the loader, and the archive is not
    // linked - see `Library.Bundled.link_artifact`.
    const translate = translateC(b, target, optimize, generated);
    var rt_core: ?*std.Build.Module = null;
    if (runtime_loaded) {
        gmp_module.addImport("c", runtime.createModule(b, translate, target, optimize));
    } else {
        addTranslatedApi(gmp_module, translate);
        // The facade module is the one every program of this build imports,
        // and every module in a compilation's graph contributes its own
        // runtime search path, so this is where the library's entry belongs:
        // once, for the test binary, for `smoke` and `run`, and for every
        // dependent that reaches `dep.module("gmp")`. A dependent's executable
        // is built out of a build cache, where the shared object really is, so
        // the published facade is the `build_cache` flavour.
        // `bin/gmp-example` is the one program of this build that is
        // installed and therefore cannot use that entry, and
        // `addInstallFacade` builds the private module it is compiled from.
        linkForLoader(gmp_module, library, target, .build_cache);
        rt_core = runtime.createCoreModule(b, target, optimize);
        gmp_module.addImport("rt", rt_core.?);
    }

    if (install) {
        b.installArtifact(library);
        // `gmp.pc` is generated in the build cache, so it needs the
        // LazyPath-taking install step, and it belongs in the same `lib`
        // directory the artifact lands in, which is where upstream's
        // `pkgconfigdir = $(libdir)/pkgconfig` (`Makefile.am:121-122`) puts it.
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

/// Link an installed GMP instead of building this one.
///
/// The translated declarations come from the *system* `gmp.h`, because the
/// generated include directory is deliberately not added to the include line
/// here. The declarations therefore always describe the library that is linked,
/// never the header this source tree would have generated. The facade uses only
/// long standing public GMP API, so it works against any GMP 5 or later
/// installation; the limb size then comes from the installed library, which is
/// exactly what its own header describes.
///
/// `aggregateRoute` still applies here, and it changes nothing about which
/// `gmp.h` is read: on NetBSD and OpenBSD the same aggregate is preprocessed
/// first, with no `-I` added here, so `<gmp.h>` still resolves through the
/// target's own search path and still describes the library that is linked.
///
/// `system_linkage` selects which installed library the search prefers, which
/// is `-Dlinkage` when the caller gave one and otherwise the dynamic default
/// this fork has always used in this mode. It is consumed here and nowhere
/// else: `linkSystemLibrary` puts it on the translated `c` module, and every
/// module in a compilation's graph is on that compilation's link line, so the
/// choice reaches every dependent without being recorded a second time.
///
/// This is one of the two linked configurations, so it is the same shape the
/// bundled linked branch builds and owes the facade the same loader core. It is
/// not a runtime-loading configuration and cannot become one: `-Druntime=true`
/// with `-fsys=gmp` is refused in `makeLibrary` rather than dropped here.
fn makeSystemLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gmp_module: *std.Build.Module,
    system_linkage: std.builtin.LinkMode,
) Library {
    const translate = translateC(b, target, optimize, null);
    translate.linkSystemLibrary("gmp", .{ .preferred_link_mode = system_linkage });

    addTranslatedApi(gmp_module, translate);
    // This mode links the installed library, so it is one of the two linked
    // configurations and owes the facade the same loader core the bundled
    // linked branch builds. `root.zig` names `rt` at container scope, where
    // `LoadSource` and `LoadError` come from, so a module without this import
    // cannot answer a consumer that names either type. Nothing else is
    // referenced from it in a linked build, and `-Druntime=true` cannot reach
    // this function: `makeLibrary` refuses that pair.
    gmp_module.addImport("rt", runtime.createCoreModule(b, target, optimize));
    return .{ .system = {} };
}

/// Which front end reads the aggregate translation unit.
const AggregateRoute = enum { aro, preprocessed };

/// Whether Aro may preprocess this repository's `include/gmp_all.h` for this
/// target, or the target's own compiler has to do that first.
///
/// The aggregate reaches the target's own `<stdio.h>`, `<stdarg.h>` and
/// `<gmp.h>`, and the two bundled BSD families ship headers Aro cannot read:
///
///   * NetBSD. `generic-netbsd/sys/cdefs.h:408-424` builds
///     `__BEGIN_PUBLIC_DECLS` out of `_Pragma("GCC visibility push(default)")`
///     and `__END_PUBLIC_DECLS` out of `_Pragma("GCC visibility pop")`, and
///     `:431-432` makes `__BEGIN_DECLS` and `__END_DECLS` those. `stdio.h`
///     opens a declaration block with `__BEGIN_DECLS` on sixteen lines.
///   * OpenBSD, two arch-dependent shapes, both reached through
///     `stdio.h:41-47`. On the 32-bit targets the only difference from the
///     64-bit ones, which translate today, is the width of `long`: the
///     per-arch `_types.h:123` of `x86-openbsd-none/machine`,
///     `arm-openbsd-eabi/arm` and `powerpc-openbsd-eabihf/powerpc` each make
///     `__size_t` an `unsigned long`, where Aro's own `size` is an
///     `unsigned int` for every 32-bit target and an `unsigned long` for every
///     64-bit one (`compiler/aro/aro/TypeStore.zig:2148-2157`), which is why
///     the three 32-bit targets fail on this and the 64-bit ones do not. Each
///     of `stdio.h:49-52`, `sys/types.h:171-174` and `stddef.h:47-50` opens its
///     own `typedef __size_t size_t;` behind `_SIZE_T_DEFINED_`. On mips64
///     `machine/endian.h` is
///     `<mips64/endian.h>`, which hard-`#error`s unless `__MIPSEL__` or
///     `__MIPSEB__` is predefined
///     (`generic-openbsd/mips64/endian.h:32-41`) and Aro's MIPS branch defines
///     only `__mips__` and `_mips` (`compiler/aro/aro/Compilation.zig:635-642`).
///
/// The condition is the OS tag rather than a list of triples: each family
/// shares the one header and the one cause, and a list would quietly stop
/// covering the next architecture in it. FreeBSD keeps `__BEGIN_DECLS` as plain
/// tokens (`generic-freebsd/sys/cdefs.h:64-70`) and stays on `.aro`, so nothing
/// it had before is given to it here.
///
/// Hexagon is in neither branch and cannot be: `zig/config_gen.zig:121-170`
/// has no pointer width for it and panics while the configuration is derived,
/// which is before this step is reached. That boundary is unchanged.
fn aggregateRoute(target: std.Build.ResolvedTarget) AggregateRoute {
    return switch (target.result.os.tag) {
        .netbsd, .openbsd => .preprocessed,
        else => .aro,
    };
}

/// `include/gmp_all.h`, preprocessed for the target being translated.
///
/// This is the extra front end `aggregateRoute` selects for the two BSD
/// families. What this writes is the aggregate header with every `#include`
/// resolved, every conditional settled and every macro definition kept, for
/// the target the facade is compiled for. Nothing is stubbed, narrowed,
/// renamed or substituted: the file the translator reads is still this
/// repository's own `include/gmp_all.h`.
///
/// ## Why this preprocessor may run at all
///
/// It is the compiler running this build script -- `b.graph.zig_exe` -- so the
/// target, the include path and the widths are the ones the C core is
/// compiled with.
///
/// ## Why `-dD`
///
/// GMP's public surface is a macro header, and a dump of used macros only
/// would take it with it. `gmp.h` publishes `GMP_LIMB_BITS`, `GMP_NUMB_BITS`,
/// `GMP_NAIL_BITS` and the `GMP_VERSION_*` triple as macros, and `gmp_all.h`
/// gates the whole stdio and `va_list` family on `FILE` being defined and on
/// `va_start` being a macro. `-dD` keeps the `#define` lines beside the
/// expanded text, so a macro a C caller reads as a macro still reaches Zig as
/// a constant.
///
/// ## Why `-MD`
///
/// The aggregate is reached only through `#include`, and a `-I` directory
/// argument contributes nothing but its own resolved path and its step
/// dependency to a run step (`std/Build/Step/Run.zig:465-471`). Without a
/// depfile this step's declared inputs would be `include/gmp_all.h` and one
/// path string, and a later revision of the generated `gmp.h` would be served
/// from the run cache with the translation still describing the previous one.
/// `-MD` with `-MF`, through `addPrefixedDepFileOutputArg`, hands every header
/// this run actually opened to the build system as this step's own inputs.
///
/// ## What is deliberately not on this line
///
/// No `-std=`, and no `-D` at all. A macro put here would decide a conditional
/// in a file whose job is not to decide it, and the translation has to
/// describe the same `gmp.h` a consumer reads: `__GMP_WITHIN_GMP` belongs to
/// the library, not to this line.
fn preprocessedAggregate(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    generated: ?Generated,
) std.Build.LazyPath {
    // `b.graph.zig_exe` is the compiler running this build script, so the
    // preprocessor is the same pinned one the C core is compiled by.
    const run = b.addSystemCommand(&[_][]const u8{ b.graph.zig_exe, "cc", "-E", "-dD" });
    run.setName("preprocess gmp gmp_all.h");
    if (!target.query.isNative()) {
        const triple = target.query.zigTriple(b.allocator) catch @panic("gmp: unspellable target");
        run.addArg("-target");
        run.addArg(triple);
    }
    if (generated) |tree| {
        // The same include root the translation step is given, so `<gmp.h>`
        // is this repository's freshly generated header, or the installed one
        // when there is no generated tree at all.
        run.addPrefixedDirectoryArg("-I", tree.directory);
        // Named as a dependency in its own right as well, so the edge exists in
        // the graph and not only in the manifest the depfile feeds.
        tree.gmp_header.addStepDependencies(&run.step);
    }
    run.addArg("-o");
    const preprocessed = run.addOutputFileArg("gmp-translate.c");
    run.addArg("-MD");
    _ = run.addPrefixedDepFileOutputArg("-MF", "gmp-translate.d");
    run.addFileArg(b.path("include/gmp_all.h"));
    return preprocessed;
}

/// Translate the public header with `gmp.h` resolved from `generated`.
///
/// When `generated` is null, the system `gmp.h` is used. The step is returned
/// rather than a finished module so that `addTranslatedApi` is the only place
/// that turns one into the public `c` import.
///
/// Which front end reads the aggregate is `aggregateRoute`'s call. The two
/// routes differ in exactly one respect: the `.aro` one hands the translator
/// this repository's `include/gmp_all.h` to preprocess for itself, and the
/// `.preprocessed` one hands it what `zig cc -E -dD` already wrote for the same
/// target, on the same include path. The include path is added either way, so
/// both routes resolve `<gmp.h>` to the same header.
fn translateC(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
    if (generated) |tree| translate.addIncludePath(tree.directory);
    return translate;
}

/// The public `c` import: the complete translated GMP API, from the target's
/// own `gmp.h`, stdio and `va_list` functions included.
///
/// This single call is the whole seam a generated runtime-loading dispatch
/// would take over, in bundled and in system mode alike. No such helper exists
/// in this tree yet, so nothing here refers to one.
fn addTranslatedApi(gmp_module: *std.Build.Module, translate: *std.Build.Step.TranslateC) void {
    gmp_module.addImport("c", translate.createModule());
}

/// The licence texts and the upstream records that travel with an installed
/// libgmp, in the two places each belongs: the four upstream grants and this
/// fork's own four records under `share/licenses/gmp`, the authorship and
/// release records under automake's own `share/doc/gmp`. Nothing is installed
/// that this tree does not already carry, and nothing that carries a licence is
/// left out.
fn addInstalledRecords(b: *std.Build) void {
    for (licence_files ++ fork_record_files) |name| {
        b.installFile(name, b.pathJoin(&.{ "share", "licenses", "gmp", name }));
    }
    for (metadata_files) |name| {
        b.installFile(name, b.pathJoin(&.{ "share", "doc", "gmp", name }));
    }
}

const Generated = struct {
    /// Directory holding every generated file: both headers, the two
    /// generated translation units and the template operation wrappers.
    directory: std.Build.LazyPath,
    /// The public headers installed into the artifact's include tree. GMP's
    /// internal `config.h` is generated into `directory` for this build only.
    gmp_header: std.Build.LazyPath,
    mparam_header: std.Build.LazyPath,
    /// The generated `gmp.pc`, installed as link metadata.
    pkgconfig: std.Build.LazyPath,
    /// Names inside `directory` of the generated mpn template wrappers, one
    /// per operation, each compiled as a translation unit in its own right.
    operation_sources: []const []const u8,
};

/// Render `gmp.h`, `config.h` and `gmp.pc` the way GMP's `configure` would, run
/// the table generators and write the mpn template wrappers, all into one
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

    // `gmp.pc` is metadata about where the library is installed, so it is
    // rendered from upstream's own `gmp.pc.in` like the two headers rather than
    // copied, and it takes no install path from here: its `prefix` is
    // `${pcfiledir}/../..`, which `pkg-config` resolves against the installed
    // file's own location, so the metadata describes the tree it sits in
    // wherever that tree is placed. See `config.renderPkgConfig`.
    const pkgconfig = output.add(
        "gmp.pc",
        config.renderPkgConfig(
            b.allocator,
            readPackageFile(b, "gmp.pc.in"),
        ) catch @panic("OOM"),
    );

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
        .pkgconfig = pkgconfig,
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
///
/// It links nothing itself: `gmp_module` is the module that carries the
/// library, and `Step.Compile` puts every module in a compilation's graph on
/// its link line (`lib/std/Build/Step/Compile.zig:1082-1087` for a module's
/// link objects, `:1162-1197` for a library).  Naming the library here as
/// well would put the same shared object on the line twice.
fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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

/// A second facade for the same target, carrying the install tree's search
/// path instead of the build cache's.
///
/// This is the facade `bin/gmp-example` is compiled from, and the only reason
/// it exists: the published module has to serve every dependent, so it carries
/// the entry a dependent's build cache needs, and an installed program cannot
/// use that one. Apart from the link this is the published module in every
/// respect: the same root source file, target and optimise mode, the same `c`
/// import from the same translation step, and the same loader core --
/// `LoadSource` and `LoadError` are published by name, and two cores would be
/// two sets of those two types. It is private, because `b.addModule` is keyed
/// by name against the whole build and the published `gmp` must stay the one a
/// dependent reaches.
fn addInstallFacade(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: Library,
) ?*std.Build.Module {
    const bundled = switch (library) {
        .bundled => |value| value,
        // `-fsys=gmp` links an installed library through the translated
        // module, and there is no shared object of ours whose search path
        // could differ between the two flavours.
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

/// The test binary: behaviour tests plus the allocation probe.
///
/// Like `addExample`, it links no library of its own: the facade it imports
/// is what carries one.
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
