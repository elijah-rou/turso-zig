const std = @import("std");

const TursoLinkage = enum {
    dynamic,
    static,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const turso_lib_dir = b.option(
        std.Build.LazyPath,
        "turso-lib-dir",
        "Directory containing the matching Turso SDK Kit 0.7.1 native library (required)",
    ) orelse std.process.fatal(
        "missing required -Dturso-lib-dir=<path> for Turso SDK Kit 0.7.1",
        .{},
    );
    const turso_linkage = b.option(
        TursoLinkage,
        "turso-linkage",
        "Native Turso SDK Kit linkage: dynamic or static",
    ) orelse .dynamic;

    const module = b.addModule("turso", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(b.path("vendor/turso-sdk-kit-0.7.1"));
    module.link_libc = true;
    module.addLibraryPath(turso_lib_dir);
    module.linkSystemLibrary("turso_sdk_kit", .{
        .use_pkg_config = .no,
        .preferred_link_mode = switch (turso_linkage) {
            .dynamic => .dynamic,
            .static => .static,
        },
        .search_strategy = .no_fallback,
    });
    if (turso_linkage == .dynamic) module.addRPath(turso_lib_dir);

    const tests_module = b.createModule(.{
        .root_source_file = b.path("tests/sdk_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_module.addImport("turso", module);

    const sdk_tests = b.addTest(.{ .root_module = tests_module });
    const run_sdk_tests = b.addRunArtifact(sdk_tests);
    const test_step = b.step("test", "Run SDK tests");
    test_step.dependOn(&run_sdk_tests.step);
}
