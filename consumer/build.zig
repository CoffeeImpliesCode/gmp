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

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gmp_dep = b.dependency("gmp", .{
        .target = target,
        .optimize = optimize,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("gmp", gmp_dep.module("gmp"));
    // The artifact carries the generated `gmp.h` in its include tree, so
    // linking it is enough for any C or translate-c consumer as well.
    module.linkLibrary(gmp_dep.artifact("gmp"));

    const exe = b.addExecutable(.{ .name = "gmp-consumer", .root_module = module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Exercise the GMP API and print deterministic results");
    run_step.dependOn(&run.step);

    const test_step = b.step("test", "Run the consumer checks");
    test_step.dependOn(&run.step);
}
