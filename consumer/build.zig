//! Exercises GMP through its published dependency module and artifact.
//! Build options cover static, dynamic, runtime-loaded, and system-library configurations.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Read system integration from the build graph shared with the dependency.
    const uses_system_library = b.systemIntegrationOption("gmp", .{});

    // Forward nullable linkage and runtime options so absent values preserve dependency defaults.
    // In system mode, the dependency chooses the installed library's default linkage.
    const linkage = b.option(
        std.lang.LinkMode,
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
    // Link only bundled, linked builds; system modules already link their library.
    // Runtime builds must not link the archive or calls could bypass dispatch.
    if (!uses_system_library and !(runtime orelse false)) {
        module.linkLibrary(gmp_dep.artifact("gmp"));
    }

    const exe = b.addExecutable(.{ .name = "gmp-consumer", .root_module = module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    // Forward provider arguments to the runtime-loaded consumer.
    run.addPassthruArgs();
    const run_step = b.step("run", "Exercise the GMP API and print deterministic results");
    run_step.dependOn(&run.step);

    const test_step = b.step("test", "Run the consumer checks");
    test_step.dependOn(&run.step);
}
