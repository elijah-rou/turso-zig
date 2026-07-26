const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("turso", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(b.path("vendor/turso-sdk-kit-0.7.1"));

    const module_tests = b.addTest(.{ .root_module = module });
    b.getInstallStep().dependOn(&module_tests.step);

    const run_module_tests = b.addRunArtifact(module_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_module_tests.step);
}
