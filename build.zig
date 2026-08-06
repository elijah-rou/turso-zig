const std = @import("std");

const TursoLinkage = enum {
    dynamic,
    static,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const turso_lib_dir_option = b.option(
        std.Build.LazyPath,
        "turso-lib-dir",
        "Directory containing the matching Turso SDK Kit 0.7.1 native library (required by compile and run steps)",
    );
    const turso_lib_dir = turso_lib_dir_option orelse std.Build.LazyPath{
        .cwd_relative = "turso-lib-dir-option-was-not-provided",
    };
    const missing_turso_lib_dir = if (turso_lib_dir_option == null)
        b.addFail("missing required -Dturso-lib-dir=<path> for Turso SDK Kit 0.7.1")
    else
        null;
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
    module.addObjectFile(tursoLibraryPath(b, target.result, turso_lib_dir, turso_linkage));
    if (turso_linkage == .dynamic) module.addRPath(turso_lib_dir);

    const tests_module = b.createModule(.{
        .root_source_file = b.path("tests/sdk_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_module.addImport("turso", module);

    const sdk_tests = b.addTest(.{ .root_module = tests_module });
    if (missing_turso_lib_dir) |failure| sdk_tests.step.dependOn(&failure.step);
    const run_sdk_tests = b.addRunArtifact(sdk_tests);
    const test_step = b.step("test", "Run SDK tests");
    test_step.dependOn(&run_sdk_tests.step);
}

fn tursoLibraryPath(
    b: *std.Build,
    target: std.Target,
    directory: std.Build.LazyPath,
    linkage: TursoLinkage,
) std.Build.LazyPath {
    const suffix = switch (linkage) {
        .static => target.staticLibSuffix(),
        .dynamic => if (target.os.tag == .windows) target.staticLibSuffix() else target.dynamicLibSuffix(),
    };
    const filename = b.fmt("{s}turso_sdk_kit{s}", .{ target.libPrefix(), suffix });
    return directory.path(b, filename);
}
