const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const mvzr_dep = b.dependency("mvzr", .{});
    const jsonpath_module = b.addModule("jsonpath", .{
        .root_source_file = b.path("jsonpath.zig"),
        .imports = &.{
            .{ .name = "mvzr", .module = mvzr_dep.module("mvzr") },
        },
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zig-jsonpath",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("jsonpath.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mvzr", .module = mvzr_dep.module("mvzr") },
            },
        }),
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const cts_runner_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cts_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "jsonpath", .module = jsonpath_module },
            },
        }),
    });

    const run_cts_runner_unit_tests = b.addRunArtifact(cts_runner_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_cts_runner_unit_tests.step);

    // Run the official JSONPath compliance suite with one isolated process per case.
    const cts_runner = b.addExecutable(.{
        .name = "cts-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cts_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "jsonpath", .module = jsonpath_module },
            },
        }),
    });

    const run_cts = b.addRunArtifact(cts_runner);

    // Pass the pinned suite location as argv[1]. This avoids depending on cwd.
    run_cts.addFileArg(
        b.path("jsonpath-compliance-test-suite/cts.json"),
    );

    // Forward arguments after `--`, primarily for debugging an individual worker.
    if (b.args) |args| {
        run_cts.addArgs(args);
    }

    const cts_step = b.step("cts", "Run the JSONPath compliance test suite");
    cts_step.dependOn(&run_cts.step);
}
