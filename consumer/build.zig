//! A separate package that consumes the GMP package the way a real dependent
//! would: through `b.dependency`, then the public module and the artifact.
//!
//! It deliberately does not reach into the GMP source tree. Everything it uses
//! is what the package publishes: `dep.module("gmp")` for the facade and the
//! translated C API, `dep.artifact("gmp")` for the compiled library, and the
//! include tree that artifact carries.
//!
//! `zig build run` from this directory exercises the API and prints
//! deterministic results, checking each one against a value that can be
//! verified by hand.
//!
//! It builds in every configuration the package offers. `-Dlinkage=static`
//! and `-Dlinkage=dynamic` choose the libgmp the dependency compiles,
//! `-Druntime=true` switches the facade onto the runtime-loading route, where
//! `src/main.zig` names a provider — `zig build run -- --provider <path>`, or
//! `GMP_TEST_PROVIDER` — and loads it before it calls anything, and `-fsys=gmp`
//! binds an installed GMP instead of compiling this tree at all.
//! Both options are forwarded exactly as given, or not at all, so a plain
//! `zig build run` leaves the dependency on its own defaults and is still the
//! linked static consumer it has always been.
//!
//! `dep.artifact("gmp")` is one of those configurations' output and not
//! another's: a bundled build installs an artifact under that name and a
//! system build installs none, so asking for it in the wrong one is a panic
//! rather than a link. See `uses_system_library` below.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Whether this build binds an installed GMP instead of compiling the tree.
    // That is a property of the *shared* dependency graph, not of anything
    // this package forwards.
    //
    // The build runner records `-fsys=gmp`, `-fno-sys=gmp` and `--system` in
    // `b.graph.system_library_options` before any package's `build` runs
    // (`lib/compiler/build_runner.zig:169-175,319-322`), and every
    // `std.Build` in one process shares that one `Graph`:
    // `createChildOnly` sets `.graph = parent.graph` (`lib/std/Build.zig:352`).
    // So asking the same question through the same function the dependency
    // asks reads the same entry and gets the same answer. There is no
    // separate flag to forward here and none is invented: `-Dfsys` would be
    // a second spelling of a setting this toolchain already resolves, and it
    // would disagree with the dependency's own answer whenever the two were
    // told different things.
    //
    // This package has to know the answer itself, before the link, because
    // the two configurations do not publish the same things. It asks for
    // this dependency under its own name; the dependency is reached only
    // through `b.dependency`.
    const uses_system_library = b.systemIntegrationOption("gmp", .{});

    // Both delivery options are declared here as well, so a dependent can
    // forward them. An option the parent does not declare is rejected when it
    // is passed, which would make `-Dlinkage` and `-Druntime` unusable from
    // this package even though the dependency accepts both.
    //
    // Both stay *nullable* and are forwarded exactly as given, with no
    // default of this package's own. A pinned default would arrive at the
    // dependency as an explicit request it cannot tell from the user's own:
    // `std.Build.dependency` records a null forwarded option as no entry at
    // all (`userInputOptionsFromArgs`, `lib/std/Build.zig:421-428`, and
    // `b.option` returns null for an absent one, `lib/std/Build.zig:1167`),
    // which is what lets the dependency apply its own default.
    //
    // That distinction decides real builds. Under `-fsys=gmp` this graph
    // compiles no artifact, so `-Dlinkage` there names the kind of
    // *installed* library to bind to, and the dependency's own default for
    // that is dynamic -- `Module.linkSystemLibrary`'s
    // (`lib/std/Build/Module.zig:359`). A consumer that defaulted this to
    // `static` would forward a static request and then fail to link on a host
    // that ships only `libgmp.so`, which is the common case and would read as
    // a broken system library rather than as a wrong default here.
    // `-Druntime` defaults to `false` on both sides, and forwarding a pinned
    // `false` would override the dependency's own reading of the same option
    // just as silently.
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Build libgmp as a static archive or as a shared library. Forwarded " ++
            "to the gmp dependency unchanged; with no option here the " ++
            "dependency applies its own default, static for the library it " ++
            "compiles and dynamic for an installed one under -fsys=gmp.",
    );
    const runtime = b.option(
        bool,
        "runtime",
        "Consume GMP through the runtime-loading route, where the provider is " ++
            "named and loaded at run time instead of linked. Forwarded to the " ++
            "gmp dependency unchanged; with no option here the dependency " ++
            "applies its own default, the linked route. Refused together with " ++
            "-fsys=gmp, which is one of the dependency's own rules.",
    );

    const gmp_dep = b.dependency("gmp", .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime = runtime,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("gmp", gmp_dep.module("gmp"));
    // The artifact carries the generated `gmp.h` in its include tree, so
    // linking it is enough for any C or translate-c consumer as well.
    //
    // It is asked for in the configurations that compile one, and
    // `Dependency.artifact` resolves a name only against the dependency's
    // install steps (`lib/std/Build.zig:1943-1959`). Under `-fsys=gmp` there
    // is no artifact of ours under that name -- that graph installs only its
    // example -- so naming it there is a panic listing the names that do
    // exist, not a link. Nothing is lost by skipping it there:
    // `gmp_dep.module("gmp")` already carries the installed library, because
    // the dependency adds it to the translated `c` module it imports, and
    // `Step.Compile` puts every module in a compilation's graph on its link
    // line (`lib/std/Build/Step/Compile.zig:1080-1088`).
    //
    // Also not in a runtime-loading build. `gmp_dep.module("gmp")` already
    // routes every call through the dispatch there, and linking the archive
    // as well would let the linker satisfy those symbols statically, so
    // `load` would never be reached and the run would prove nothing about
    // the route it was asked to exercise.
    //
    // `runtime` is read through its resolved value because this package needs
    // the answer twice and must resolve it the one way the dependency would:
    // absent means the linked route, which is the dependency's own default
    // and therefore the one it applied to the forwarded value too.
    if (!uses_system_library and !(runtime orelse false)) {
        module.linkLibrary(gmp_dep.artifact("gmp"));
    }

    const exe = b.addExecutable(.{ .name = "gmp-consumer", .root_module = module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    // Forwarded like `build.zig:239` does for the example: under `-Druntime=true`
    // this program has no library on its link line and is given the provider it
    // must load by an explicit argument, which only reaches it through `b.args`.
    // Without this the flag is dropped and the program reports that it was told
    // nothing about the provider it was just handed.
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Exercise the GMP API and print deterministic results");
    run_step.dependOn(&run.step);

    const test_step = b.step("test", "Run the consumer checks");
    test_step.dependOn(&run.step);
}
