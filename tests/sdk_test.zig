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
