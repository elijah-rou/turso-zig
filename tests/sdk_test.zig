const std = @import("std");
const turso = @import("turso");

test "public ABI reports a compatible Turso SDK Kit version" {
    const version_ptr = turso.c.turso_version() orelse return error.MissingTursoVersion;
    const version = std.mem.span(version_ptr);

    try std.testing.expect(turso.isAbiCompatibleVersion(version));
    try std.testing.expect(turso.isAbiCompatibleVersion("0.7.1"));
    try std.testing.expect(turso.isAbiCompatibleVersion("0.7.1-dev"));
    try std.testing.expect(turso.isAbiCompatibleVersion("0.7.1+build"));

    try std.testing.expect(!turso.isAbiCompatibleVersion("0.7"));
    try std.testing.expect(!turso.isAbiCompatibleVersion("0.7.10"));
    try std.testing.expect(!turso.isAbiCompatibleVersion("0.7.1.1"));
    try std.testing.expect(!turso.isAbiCompatibleVersion("0.7.2"));
}

test "database wrapper creates, opens, connects, and cleans up in reverse order" {
    var path = [_]u8{ ':', 'm', 'e', 'm', 'o', 'r', 'y', ':' };
    var result = try turso.Database.create(std.testing.allocator, .{ .path = &path });
    var database = switch (result) {
        .success => |database| database,
        .failure => |*failure| {
            defer failure.deinit(std.testing.allocator);
            std.debug.print("database construction failed: {s}\n", .{failure.diagnostic});
            return failure.category;
        },
    };
    defer database.deinit();

    try std.testing.expectEqual(@as(usize, 0), database.activeConnectionCount());
    try std.testing.expect(database.latestDiagnostic() == null);
    @memset(&path, 'x');
    try database.open();
    try std.testing.expect(database.latestDiagnostic() == null);

    {
        var connection = try database.connect();
        defer connection.deinit();
        try std.testing.expectEqual(@as(usize, 1), database.activeConnectionCount());
        try std.testing.expect(connection.latestDiagnostic() == null);
    }
    try std.testing.expectEqual(@as(usize, 0), database.activeConnectionCount());
}

test "construction failure owns its category and diagnostic" {
    var result = try turso.Database.create(std.testing.allocator, .{ .path = "invalid\x00path" });
    switch (result) {
        .success => |*database| {
            database.deinit();
            return error.ExpectedConstructionFailure;
        },
        .failure => |*failure| {
            try std.testing.expectEqual(turso.Error.InvalidConfig, failure.category);
            try std.testing.expect(failure.diagnostic.len != 0);
            const owned_message = failure.diagnostic;
            try std.testing.expect(std.mem.indexOf(u8, owned_message, "NUL") != null);
            failure.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 0), failure.diagnostic.len);
        },
    }
}

test "latest database diagnostic is cleared by the next fallible operation" {
    var result = try turso.Database.create(std.testing.allocator, .{ .path = "/proc/turso-zig-sdk/forbidden.db" });
    var database = switch (result) {
        .success => |database| database,
        .failure => |*failure| {
            defer failure.deinit(std.testing.allocator);
            std.debug.print("database construction failed: {s}\n", .{failure.diagnostic});
            return failure.category;
        },
    };
    defer database.deinit();

    try std.testing.expectError(turso.Error.IoError, database.open());
    const first_diagnostic = database.latestDiagnostic() orelse return error.MissingDiagnostic;
    try std.testing.expect(first_diagnostic.len != 0);

    _ = database.connect() catch {};
    const replacement = database.latestDiagnostic() orelse return error.MissingReplacementDiagnostic;
    try std.testing.expectEqualStrings("database must be opened before connecting", replacement);
}

test "value ownership is explicit for copied text and blob" {
    var text = turso.Value{ .text = try std.testing.allocator.dupe(u8, "owned") };
    defer text.deinit(std.testing.allocator);
    var blob = turso.Value{ .blob = try std.testing.allocator.dupe(u8, &.{ 0, 1, 2 }) };
    defer blob.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("owned", text.text);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, blob.blob);
}

test "unstable raw namespace exposes the pinned status and value ABI" {
    try std.testing.expectEqual(@as(c_int, 0), turso.c.TURSO_OK);
    try std.testing.expectEqual(@as(c_int, 134), turso.c.TURSO_IOERR);
    try std.testing.expectEqual(@as(c_int, 1), turso.c.TURSO_TYPE_INTEGER);
    try std.testing.expectEqual(@as(c_int, 5), turso.c.TURSO_TYPE_NULL);
}

test "raw ABI creates, opens, connects, and executes a query" {
    var config = std.mem.zeroes(turso.c.turso_database_config_t);
    config.async_io = 0;
    config.path = ":memory:";

    var error_message: [*c]const u8 = null;
    var database: ?*const turso.c.turso_database_t = null;
    try expectStatus(turso.c.TURSO_OK, turso.c.turso_database_new(
        &config,
        &database,
        &error_message,
    ), &error_message);
    try std.testing.expect(database != null);
    defer turso.c.turso_database_deinit(database);

    try expectStatus(
        turso.c.TURSO_OK,
        turso.c.turso_database_open(database, &error_message),
        &error_message,
    );

    var connection: ?*turso.c.turso_connection_t = null;
    try expectStatus(turso.c.TURSO_OK, turso.c.turso_database_connect(
        database,
        &connection,
        &error_message,
    ), &error_message);
    try std.testing.expect(connection != null);
    defer turso.c.turso_connection_deinit(connection);

    var statement: ?*turso.c.turso_statement_t = null;
    try expectStatus(turso.c.TURSO_OK, turso.c.turso_connection_prepare_single(
        connection,
        "SELECT 1",
        &statement,
        &error_message,
    ), &error_message);
    try std.testing.expect(statement != null);
    defer turso.c.turso_statement_deinit(statement);

    try expectStatus(
        turso.c.TURSO_ROW,
        turso.c.turso_statement_step(statement, &error_message),
        &error_message,
    );
    try std.testing.expectEqual(@as(i64, 1), turso.c.turso_statement_column_count(statement));
    try std.testing.expectEqual(
        @as(turso.c.turso_type_t, turso.c.TURSO_TYPE_INTEGER),
        turso.c.turso_statement_row_value_kind(statement, 0),
    );
    try std.testing.expectEqual(@as(i64, 1), turso.c.turso_statement_row_value_int(statement, 0));

    try expectStatus(
        turso.c.TURSO_DONE,
        turso.c.turso_statement_step(statement, &error_message),
        &error_message,
    );
    try expectStatus(
        turso.c.TURSO_DONE,
        turso.c.turso_statement_finalize(statement, &error_message),
        &error_message,
    );
    try expectStatus(
        turso.c.TURSO_OK,
        turso.c.turso_connection_close(connection, &error_message),
        &error_message,
    );
}

fn expectStatus(
    expected: turso.c.turso_status_code_t,
    actual: turso.c.turso_status_code_t,
    error_message: *[*c]const u8,
) !void {
    defer if (error_message.* != null) {
        turso.c.turso_str_deinit(error_message.*);
        error_message.* = null;
    };

    if (error_message.* != null) {
        std.debug.print("Turso diagnostic: {s}\n", .{std.mem.span(error_message.*)});
    }
    try std.testing.expectEqual(expected, actual);
    try std.testing.expect(error_message.* == null);
}
