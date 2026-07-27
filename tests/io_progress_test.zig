const std = @import("std");
const turso = @import("turso");

fn createDatabase(config: turso.Database.Config) !turso.Database {
    var result = try turso.Database.create(std.testing.allocator, config);
    return switch (result) {
        .success => |database| database,
        .failure => |*failure| {
            defer failure.deinit(std.testing.allocator);
            return failure.category;
        },
    };
}

test "caller-driven public progress signatures are explicit" {
    comptime if (@hasField(turso.Statement, "progress_state")) {
        @compileError("Statement progress state must not be consumer-accessible");
    };

    const open_progress: *const fn (*turso.Database) turso.Error!turso.OpenProgress = turso.Database.openProgress;
    const step_progress: *const fn (*turso.Statement) turso.Error!turso.StepProgress = turso.Statement.stepProgress;
    const execute_progress: *const fn (*turso.Statement) turso.Error!turso.ExecuteProgress = turso.Statement.executeProgress;
    const finalize_progress: *const fn (*turso.Statement) turso.Error!turso.FinalizeProgress = turso.Statement.finalizeProgress;
    const run_io: *const fn (*turso.Statement) turso.Error!void = turso.Statement.runIo;
    _ = .{ open_progress, step_progress, execute_progress, finalize_progress, run_io };

    try std.testing.expectEqual(@as(usize, 2), @typeInfo(turso.OpenProgress).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(turso.StepProgress).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(turso.ExecuteProgress).@"union".fields.len);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(turso.FinalizeProgress).@"enum".fields.len);
}

test "caller-driven mode rejects unsupported VFS configurations" {
    const rejected = [_]?[]const u8{ "io_uring", "experimental_win_iocp", "extension_vfs", "unknown" };
    for (rejected) |vfs| {
        var result = try turso.Database.create(std.testing.allocator, .{
            .path = ":memory:",
            .io_mode = .caller_driven,
            .vfs = vfs,
        });
        switch (result) {
            .success => |*database| {
                database.deinit();
                return error.ExpectedUnsupportedVfsFailure;
            },
            .failure => |*failure| {
                defer failure.deinit(std.testing.allocator);
                try std.testing.expectEqual(turso.Error.InvalidConfig, failure.category);
                try std.testing.expectEqualStrings(
                    "caller-driven I/O supports only default, memory, or syscall VFS backends",
                    failure.diagnostic,
                );
            },
        }
    }
}

test "mode-specific methods reject the wrong mode with diagnostics" {
    var library_database = try createDatabase(.{ .path = ":memory:" });
    defer library_database.deinit();
    try std.testing.expectError(turso.Error.InvalidState, library_database.openProgress());
    try std.testing.expectEqualStrings("openProgress requires caller-driven I/O mode", library_database.latestDiagnostic().?);
    try library_database.open();
    var library_connection = try library_database.connect();
    defer library_connection.deinit();
    var library_statement = try library_connection.prepareSingle("SELECT 1");
    defer library_statement.deinit();
    try std.testing.expectError(turso.Error.InvalidState, library_statement.stepProgress());
    try std.testing.expectEqualStrings("progress methods require caller-driven I/O mode", library_statement.latestDiagnostic().?);
    try std.testing.expectError(turso.Error.InvalidState, library_statement.runIo());

    var caller_database = try createDatabase(.{ .path = ":memory:", .io_mode = .caller_driven });
    defer caller_database.deinit();
    try std.testing.expectError(turso.Error.InvalidState, caller_database.open());
    try std.testing.expectEqualStrings("open is unavailable in caller-driven I/O mode", caller_database.latestDiagnostic().?);
    try std.testing.expectEqual(turso.OpenProgress.ready, try caller_database.openProgress());
    var caller_connection = try caller_database.connect();
    defer caller_connection.deinit();
    var caller_statement = try caller_connection.prepareSingle("SELECT 1");
    defer caller_statement.deinit();
    try std.testing.expectError(turso.Error.InvalidState, caller_statement.step());
    try std.testing.expectError(turso.Error.InvalidState, caller_statement.execute());
    try std.testing.expectError(turso.Error.InvalidState, caller_statement.finalize());
    try std.testing.expectError(turso.Error.InvalidState, caller_statement.runIo());
    try std.testing.expectEqualStrings("runIo requires a pending statement operation", caller_statement.latestDiagnostic().?);
}

test "statement progress sidecar OOM leaves native ownership and connection counts intact" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing_allocator.allocator();
    var create_result = try turso.Database.create(allocator, .{ .path = ":memory:" });
    var database = switch (create_result) {
        .success => |value| value,
        .failure => |*failure| {
            defer failure.deinit(allocator);
            return failure.category;
        },
    };
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    failing_allocator.fail_index = failing_allocator.alloc_index + 1;
    try std.testing.expectError(turso.Error.OutOfMemory, connection.prepareSingle("SELECT 1"));
    try std.testing.expect(connection.latestDiagnostic() == null);

    failing_allocator.fail_index = std.math.maxInt(usize);
    var statement = try connection.prepareSingle("SELECT 1");
    statement.deinit();
    try connection.close();
}

test "caller-driven memory backend progresses without invented IO transitions" {
    var database = try createDatabase(.{ .path = ":memory:", .io_mode = .caller_driven, .vfs = "memory" });
    defer database.deinit();
    try std.testing.expectEqual(turso.OpenProgress.ready, try database.openProgress());
    var connection = try database.connect();
    defer connection.deinit();

    var query = try connection.prepareSingle("SELECT 1");
    defer query.deinit();
    try std.testing.expectEqual(turso.StepProgress.row, try query.stepProgress());
    var value = try query.value(0);
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), value.integer);
    try std.testing.expectError(turso.Error.InvalidState, query.runIo());
    try std.testing.expectError(turso.Error.InvalidState, query.value(0));
    try std.testing.expectEqual(turso.StepProgress.done, try query.stepProgress());
    try query.reset();
    try std.testing.expectEqual(turso.FinalizeProgress.done, try query.finalizeProgress());

    var execute = try connection.prepareSingle("CREATE TABLE progress(v INTEGER)");
    defer execute.deinit();
    const result = try execute.executeProgress();
    switch (result) {
        .done => |changes| try std.testing.expectEqual(@as(u64, 0), changes),
        .needs_io => return error.UnexpectedMemoryIo,
    }
}

test "caller-driven syscall open reports only the observed native status" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &temp.sub_path,
        "caller-open.db",
    });
    defer std.testing.allocator.free(path);

    var database = try createDatabase(.{ .path = path, .io_mode = .caller_driven, .vfs = "syscall" });
    defer database.deinit();
    switch (try database.openProgress()) {
        .ready => {
            try std.testing.expect(database.latestDiagnostic() == null);
            var connection = try database.connect();
            defer connection.deinit();
        },
        .needs_io_without_driver => {
            try std.testing.expectEqualStrings(
                "database open needs I/O, but Turso SDK Kit 0.7.1 exposes no database run_io driver",
                database.latestDiagnostic().?,
            );
            try std.testing.expectEqual(turso.OpenProgress.needs_io_without_driver, try database.openProgress());
            try std.testing.expectError(turso.Error.InvalidState, database.connect());
        },
    }
}

test "raw caller-driven memory statuses regress without claiming TURSO_IO" {
    var config = std.mem.zeroes(turso.c.turso_database_config_t);
    config.async_io = 1;
    config.path = ":memory:";
    config.vfs = "memory";
    var diagnostic: [*c]const u8 = null;
    var database: ?*const turso.c.turso_database_t = null;
    try std.testing.expectEqual(@as(turso.c.turso_status_code_t, turso.c.TURSO_OK), turso.c.turso_database_new(&config, &database, &diagnostic));
    defer turso.c.turso_database_deinit(database);
    try std.testing.expectEqual(@as(turso.c.turso_status_code_t, turso.c.TURSO_OK), turso.c.turso_database_open(database, &diagnostic));
    var connection: ?*turso.c.turso_connection_t = null;
    try std.testing.expectEqual(@as(turso.c.turso_status_code_t, turso.c.TURSO_OK), turso.c.turso_database_connect(database, &connection, &diagnostic));
    defer turso.c.turso_connection_deinit(connection);
    var statement: ?*turso.c.turso_statement_t = null;
    try std.testing.expectEqual(@as(turso.c.turso_status_code_t, turso.c.TURSO_OK), turso.c.turso_connection_prepare_single(connection, "SELECT 1", &statement, &diagnostic));
    defer turso.c.turso_statement_deinit(statement);
    try std.testing.expectEqual(@as(turso.c.turso_status_code_t, turso.c.TURSO_ROW), turso.c.turso_statement_step(statement, &diagnostic));
    try std.testing.expectEqual(@as(turso.c.turso_status_code_t, turso.c.TURSO_DONE), turso.c.turso_statement_step(statement, &diagnostic));
    try std.testing.expect(diagnostic == null);
}
