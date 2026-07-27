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
    const turso_extension_path = b.option(
        []const u8,
        "turso-extension-path",
        "Absolute path to the pinned Linux limbo_regexp test fixture",
    );

    const module = b.addModule("turso", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(b.path("vendor/turso-sdk-kit-0.7.1"));
    module.link_libc = true;
    module.addObjectFile(tursoLibraryPath(b, target.result, turso_lib_dir, turso_linkage));
    if (turso_linkage == .dynamic) module.addRPath(turso_lib_dir);

    const abi_parity_module = b.createModule(.{
        .root_source_file = b.path("src/abi_parity.zig"),
        .target = target,
        .optimize = optimize,
    });
    abi_parity_module.addIncludePath(b.path("vendor/turso-sdk-kit-0.7.1"));
    abi_parity_module.addAnonymousImport("abi-parity-doc", .{
        .root_source_file = b.path("docs/abi-parity.md"),
    });
    abi_parity_module.link_libc = true;
    abi_parity_module.addLibraryPath(turso_lib_dir);
    abi_parity_module.linkSystemLibrary("turso_sdk_kit", .{
        .use_pkg_config = .no,
        .preferred_link_mode = switch (turso_linkage) {
            .dynamic => .dynamic,
            .static => .static,
        },
        .search_strategy = .no_fallback,
    });
    if (turso_linkage == .dynamic) abi_parity_module.addRPath(turso_lib_dir);
    const abi_parity_tests = b.addTest(.{ .root_module = abi_parity_module });
    const run_abi_parity_tests = b.addRunArtifact(abi_parity_tests);
    const abi_parity_step = b.step("abi-parity", "Audit complete Turso SDK Kit 0.7.1 ABI parity");
    abi_parity_step.dependOn(&run_abi_parity_tests.step);

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

    const internal_tests_module = b.createModule(.{
        .root_source_file = b.path("src/internal_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    internal_tests_module.addIncludePath(b.path("vendor/turso-sdk-kit-0.7.1"));
    internal_tests_module.link_libc = true;
    internal_tests_module.addObjectFile(tursoLibraryPath(b, target.result, turso_lib_dir, turso_linkage));
    if (turso_linkage == .dynamic) internal_tests_module.addRPath(turso_lib_dir);
    const internal_tests = b.addTest(.{ .root_module = internal_tests_module });
    if (missing_turso_lib_dir) |failure| internal_tests.step.dependOn(&failure.step);
    const run_internal_tests = b.addRunArtifact(internal_tests);
    test_step.dependOn(&run_internal_tests.step);

    const io_progress_module = b.createModule(.{
        .root_source_file = b.path("tests/io_progress_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    io_progress_module.addImport("turso", module);
    const io_progress_tests = b.addTest(.{ .root_module = io_progress_module });
    const run_io_progress_tests = b.addRunArtifact(io_progress_tests);
    test_step.dependOn(&run_io_progress_tests.step);

    const isolated_tests = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "turso-setup-invalid-test", .path = "tests/setup_invalid.zig" },
        .{ .name = "turso-setup-logger-test", .path = "tests/setup_logger.zig" },
        .{ .name = "turso-setup-first-level-test", .path = "tests/setup_first_level.zig" },
        .{ .name = "turso-setup-reentry-test", .path = "tests/setup_reentry.zig" },
    };
    for (isolated_tests) |isolated_test| {
        const isolated_module = b.createModule(.{
            .root_source_file = b.path(isolated_test.path),
            .target = target,
            .optimize = optimize,
        });
        isolated_module.addImport("turso", module);
        const executable = b.addExecutable(.{
            .name = isolated_test.name,
            .root_module = isolated_module,
        });
        const run = b.addRunArtifact(executable);
        test_step.dependOn(&run.step);
    }

    if (turso_extension_path) |extension_path| {
        if (target.result.os.tag != .linux or turso_linkage != .dynamic) {
            std.process.fatal("-Dturso-extension-path requires a Linux dynamic build", .{});
        }
        if (!std.fs.path.isAbsolute(extension_path)) {
            std.process.fatal("-Dturso-extension-path must be absolute", .{});
        }
        const extension_options = b.addOptions();
        extension_options.addOption([]const u8, "path", extension_path);
        const extension_module = b.createModule(.{
            .root_source_file = b.path("tests/extension_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        extension_module.addImport("turso", module);
        extension_module.addOptions("extension_fixture", extension_options);
        const extension_executable = b.addExecutable(.{
            .name = "turso-extension-test",
            .root_module = extension_module,
        });
        const run_extension = b.addRunArtifact(extension_executable);
        test_step.dependOn(&run_extension.step);
    }

    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/basic.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_module.addImport("turso", module);

    const example = b.addExecutable(.{
        .name = "turso-basic-example",
        .root_module = example_module,
    });
    const run_example = b.addRunArtifact(example);
    const parity_example_module = b.createModule(.{
        .root_source_file = b.path("examples/parity.zig"),
        .target = target,
        .optimize = optimize,
    });
    parity_example_module.addImport("turso", module);
    const parity_example = b.addExecutable(.{
        .name = "turso-parity-example",
        .root_module = parity_example_module,
    });
    const run_parity_example = b.addRunArtifact(parity_example);

    const example_step = b.step("run-example", "Run synchronous, managed-callback, and progress examples");
    example_step.dependOn(&run_example.step);
    example_step.dependOn(&run_parity_example.step);
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
