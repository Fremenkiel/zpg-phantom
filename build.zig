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
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    example_tests.root_module.addImport("phantom", mod);
    const run_example_tests = b.addRunArtifact(example_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_example_tests.step);
}
