const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("phantom", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });

    const lib = b.addLibrary(.{
        .name = "phantom",
        .root_module = mod,
        .linkage = .static,
    });

    // 3. Install the artifact so it shows up in zig-out/lib/
    b.installArtifact(lib);

    const lib_tests = b.addTest(.{
        .root_module = lib.root_module,
    });

    // Create a run step for the tests
    const run_tests = b.addRunArtifact(lib_tests);

    // Attach it to the `zig build test` command
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);
}
