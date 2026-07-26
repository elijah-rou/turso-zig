const std = @import("std");
const turso = @import("turso");

fn openDatabase(path: []const u8) !turso.Database {
    var result = try turso.Database.create(std.testing.allocator, .{ .path = path });
    return switch (result) {
        .success => |database| database,
        .failure => |*failure| {
            defer failure.deinit(std.testing.allocator);
            std.debug.print("database construction failed: {s}\n", .{failure.diagnostic});
            return failure.category;
        },
    };
}

fn exec(connection: *turso.Connection, sql: []const u8) !u64 {
    var statement = try connection.prepareSingle(sql);
    defer statement.deinit();
    return statement.execute();
}

const ScalarContext = struct {
    calls: usize = 0,
    deinits: *usize,
    mode: enum { echo, replacement },
};

fn scalarCall(context: *ScalarContext, args: turso.CallbackArgs) turso.CallbackResult {
    context.calls += 1;
    return switch (context.mode) {
        .replacement => .{ .integer = 99 },
        .echo => if (args.values.len == 0) .null else switch (args.values[0]) {
            .null => .null,
            .integer => |value| .{ .integer = value },
            .float => |value| .{ .float = value },
            .text => |value| .{ .text = value },
            .blob => |value| .{ .blob = value },
            .managed_error => |value| .{ .managed_error = value },
        },
    };
}

fn scalarDeinit(context: *ScalarContext) void {
    context.deinits.* += 1;
}

fn queryValue(connection: *turso.Connection, sql: []const u8) !turso.Value {
    var statement = try connection.prepareSingle(sql);
    defer statement.deinit();
    try std.testing.expectEqual(turso.Step.row, try statement.step());
    return statement.value(0);
}

test "public version accessor reports a compatible Turso SDK Kit version" {
    const runtime_version = try turso.version();
    try std.testing.expect(turso.isAbiCompatibleVersion(runtime_version));
    try std.testing.expect(turso.isAbiCompatibleVersion("0.7.1"));
    try std.testing.expect(turso.isAbiCompatibleVersion("0.7.1-dev"));
    try std.testing.expect(turso.isAbiCompatibleVersion("0.7.1+build"));
    try std.testing.expect(!turso.isAbiCompatibleVersion("0.7"));
    try std.testing.expect(!turso.isAbiCompatibleVersion("0.7.10"));
    try std.testing.expect(!turso.isAbiCompatibleVersion("0.7.1.1"));
    try std.testing.expect(!turso.isAbiCompatibleVersion("0.7.2"));
}

test "public setup types exhaustively model native tracing levels" {
    try std.testing.expectEqual(@as(usize, 5), @typeInfo(turso.LogLevel).@"enum".fields.len);
    try std.testing.expectEqual(@as(c_int, turso.c.TURSO_TRACING_LEVEL_ERROR), @intFromEnum(turso.LogLevel.err));
    try std.testing.expectEqual(@as(c_int, turso.c.TURSO_TRACING_LEVEL_WARN), @intFromEnum(turso.LogLevel.warn));
    try std.testing.expectEqual(@as(c_int, turso.c.TURSO_TRACING_LEVEL_INFO), @intFromEnum(turso.LogLevel.info));
    try std.testing.expectEqual(@as(c_int, turso.c.TURSO_TRACING_LEVEL_DEBUG), @intFromEnum(turso.LogLevel.debug));
    try std.testing.expectEqual(@as(c_int, turso.c.TURSO_TRACING_LEVEL_TRACE), @intFromEnum(turso.LogLevel.trace));

    const config: turso.SetupConfig = .{ .log_level = "info", .logger = null };
    try std.testing.expectEqualStrings("info", config.log_level.?);
}

test "database wrapper creates opens connects and cleans up" {
    var path = [_]u8{ ':', 'm', 'e', 'm', 'o', 'r', 'y', ':' };
    var database = try openDatabase(&path);
    defer database.deinit();
    @memset(&path, 'x');
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    try std.testing.expectEqual(@as(usize, 1), database.activeConnectionCount());
    try std.testing.expect(connection.latestDiagnostic() == null);
}

test "owner movement preserves child bookkeeping" {
    var database = try openDatabase(":memory:");
    try database.open();
    var connection = try database.connect();
    var moved_database = database;
    try std.testing.expectEqual(@as(usize, 1), moved_database.activeConnectionCount());

    var statement = try connection.prepareSingle("SELECT 1");
    var moved_connection = connection;
    statement.deinit();
    try moved_connection.close();
    moved_connection.deinit();
    try std.testing.expectEqual(@as(usize, 0), moved_database.activeConnectionCount());
    moved_database.deinit();
}

test "double open close and finalize return invalid state" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    try std.testing.expectError(turso.Error.InvalidState, database.open());
    try std.testing.expectEqualStrings(
        "database is already open",
        database.latestDiagnostic() orelse return error.MissingDoubleOpenDiagnostic,
    );

    var connection = try database.connect();
    defer connection.deinit();
    var statement = try connection.prepareSingle("SELECT 1");
    try statement.finalize();
    try std.testing.expectError(turso.Error.InvalidState, statement.finalize());
    statement.deinit();
    try connection.close();
    try std.testing.expectError(turso.Error.InvalidState, connection.close());
}

test "prepareFirst handles empty and whitespace SQL deterministically" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    const empty = try connection.prepareFirst("");
    try std.testing.expect(empty.statement == null);
    try std.testing.expectEqual(@as(usize, 0), empty.tail_offset);
    const whitespace = try connection.prepareFirst(" \t\r\n");
    try std.testing.expect(whitespace.statement == null);
    try std.testing.expectEqual(@as(usize, 0), whitespace.tail_offset);
}

test "construction and operation diagnostics are owned and replaced" {
    var result = try turso.Database.create(std.testing.allocator, .{ .path = "invalid\x00path" });
    switch (result) {
        .success => |*database| {
            database.deinit();
            return error.ExpectedConstructionFailure;
        },
        .failure => |*failure| {
            try std.testing.expectEqual(turso.Error.InvalidConfig, failure.category);
            try std.testing.expect(std.mem.indexOf(u8, failure.diagnostic, "NUL") != null);
            failure.deinit(std.testing.allocator);
        },
    }

    var database = try openDatabase("/proc/turso-zig-sdk/forbidden.db");
    defer database.deinit();
    try std.testing.expectError(turso.Error.IoError, database.open());
    try std.testing.expect((database.latestDiagnostic() orelse return error.MissingDiagnostic).len != 0);
    _ = database.connect() catch {};
    try std.testing.expectEqualStrings(
        "database must be opened before connecting",
        database.latestDiagnostic() orelse return error.MissingReplacementDiagnostic,
    );
}

test "DDL binding stepping copied values metadata and reset" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    _ = try exec(
        &connection,
        "CREATE TABLE items(id INTEGER PRIMARY KEY, n INTEGER, r REAL, t TEXT, b BLOB, z TEXT)",
    );
    var insert = try connection.prepareSingle(
        "INSERT INTO items(n,r,t,b,z) VALUES (?1,?2,?3,?4,?5)",
    );
    defer insert.deinit();
    try std.testing.expectEqual(@as(usize, 5), try insert.parameterCount());
    try std.testing.expectError(turso.Error.InvalidIndex, insert.bindNull(0));
    try std.testing.expectError(turso.Error.InvalidIndex, insert.bindNull(6));
    try insert.bindInteger(1, -42);
    try insert.bindReal(2, 1.25);
    try insert.bindText(3, "");
    try insert.bindBlob(4, &.{});
    try insert.bindNull(5);
    try std.testing.expectEqual(@as(u64, 1), try insert.execute());
    try std.testing.expectEqual(@as(i64, 1), insert.changes());
    try std.testing.expectEqual(@as(i64, 1), connection.lastInsertRowid());
    try insert.reset();
    try insert.bindInteger(1, 7);
    try insert.bindReal(2, 2.5);
    try insert.bindText(3, "alpha");
    try insert.bindBlob(4, &.{ 0, 1, 2, 255 });
    try insert.bindNull(5);
    try std.testing.expectEqual(@as(u64, 1), try insert.execute());

    var query = try connection.prepareSingle("SELECT n,r,t,b,z FROM items ORDER BY id");
    try std.testing.expectEqual(@as(usize, 5), try query.columnCount());
    const column_name = try query.columnName(2);
    defer std.testing.allocator.free(column_name);
    try std.testing.expectEqualStrings("t", column_name);
    const declared = (try query.columnDeclaredType(2)) orelse return error.MissingDeclaredType;
    defer std.testing.allocator.free(declared);
    try std.testing.expectEqualStrings("TEXT", declared);
    try std.testing.expect((try query.columnDeclaredName(2)) == null);
    try std.testing.expectEqual(turso.ColumnKind.none, try query.columnKind(2));
    try std.testing.expectEqual(@as(u32, 0), try query.columnArrayDimensions(2));
    try std.testing.expect((try query.columnBaseType(2)) == null);
    try std.testing.expectError(turso.Error.InvalidIndex, query.columnName(5));
    try std.testing.expectError(turso.Error.InvalidState, query.value(0));

    try std.testing.expectEqual(turso.Step.row, try query.step());
    var first_integer = try query.value(0);
    defer first_integer.deinit(std.testing.allocator);
    var first_real = try query.value(1);
    defer first_real.deinit(std.testing.allocator);
    var empty_text = try query.value(2);
    defer empty_text.deinit(std.testing.allocator);
    var empty_blob = try query.value(3);
    defer empty_blob.deinit(std.testing.allocator);
    var null_value = try query.value(4);
    defer null_value.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, -42), first_integer.integer);
    try std.testing.expectEqual(@as(f64, 1.25), first_real.real);
    try std.testing.expectEqual(@as(usize, 0), empty_text.text.len);
    try std.testing.expectEqual(@as(usize, 0), empty_blob.blob.len);
    try std.testing.expect(null_value == .null);

    try std.testing.expectEqual(turso.Step.row, try query.step());
    var copied_text = try query.value(2);
    var copied_blob = try query.value(3);
    try std.testing.expectEqualStrings("alpha", copied_text.text);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 255 }, copied_blob.blob);
    try std.testing.expectEqual(turso.Step.done, try query.step());
    try query.reset();
    try query.finalize();
    query.deinit();
    try std.testing.expectEqualStrings("t", column_name);
    try std.testing.expectEqualStrings("TEXT", declared);
    try std.testing.expectEqualStrings("alpha", copied_text.text);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 255 }, copied_blob.blob);
    copied_text.deinit(std.testing.allocator);
    copied_blob.deinit(std.testing.allocator);
}

test "named parameters prepare tails busy timeout and transaction state" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    try connection.setBusyTimeoutMs(0);
    try connection.setBusyTimeoutMs(@as(u64, std.math.maxInt(i64)));
    try std.testing.expectError(turso.Error.InvalidArgument, connection.setBusyTimeoutMs(@as(u64, std.math.maxInt(i64)) + 1));

    var named = try connection.prepareSingle("SELECT :first, ?2, @third");
    defer named.deinit();
    try std.testing.expectEqual(@as(usize, 3), try named.parameterCount());
    try std.testing.expectEqual(@as(?usize, 1), try named.namedPosition(":first"));
    try std.testing.expectEqual(@as(?usize, 3), try named.namedPosition("@third"));
    try std.testing.expectEqual(@as(?usize, null), try named.namedPosition("$missing"));
    const first_name = (try named.parameterName(1)) orelse return error.MissingParameterName;
    defer std.testing.allocator.free(first_name);
    try std.testing.expectEqualStrings(":first", first_name);
    const second_name = (try named.parameterName(2)) orelse return error.MissingNumberedParameterName;
    defer std.testing.allocator.free(second_name);
    try std.testing.expectEqualStrings("?2", second_name);
    try std.testing.expectError(turso.Error.InvalidIndex, named.parameterName(0));

    var first = try connection.prepareFirst("SELECT 1; SELECT 2");
    defer if (first.statement) |*statement| statement.deinit();
    try std.testing.expect(first.statement != null);
    try std.testing.expectEqual(@as(usize, 10), first.tail_offset);
    try std.testing.expectEqualStrings("SELECT 2", "SELECT 1; SELECT 2"[first.tail_offset..]);
    try std.testing.expectError(turso.Error.TrailingSql, connection.prepareSingle("SELECT 1; SELECT 2"));

    try std.testing.expect(connection.autocommit());
    _ = try exec(&connection, "CREATE TABLE tx(v INTEGER UNIQUE)");
    _ = try exec(&connection, "BEGIN");
    try std.testing.expect(!connection.autocommit());
    _ = try exec(&connection, "INSERT INTO tx VALUES (1)");
    _ = try exec(&connection, "ROLLBACK");
    try std.testing.expect(connection.autocommit());
    _ = try exec(&connection, "BEGIN");
    _ = try exec(&connection, "INSERT INTO tx VALUES (2)");
    _ = try exec(&connection, "COMMIT");
    try std.testing.expect(connection.autocommit());
}

test "connection rejects close while a statement is active" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    var statement = try connection.prepareSingle("SELECT 1");
    try std.testing.expectError(turso.Error.InvalidState, connection.close());
    try std.testing.expectEqualStrings(
        "connection still owns active statements",
        connection.latestDiagnostic() orelse return error.MissingActiveStatementDiagnostic,
    );
    statement.deinit();
    try connection.close();
}

test "parse and constraint diagnostics are retained then replaced" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    try std.testing.expectError(turso.Error.SqlError, connection.prepareSingle("SELECT FROM"));
    const parse = connection.latestDiagnostic() orelse return error.MissingParseDiagnostic;
    try std.testing.expect(parse.len != 0);
    var create = try connection.prepareSingle("CREATE TABLE unique_values(v INTEGER UNIQUE)");
    defer create.deinit();
    try std.testing.expect(connection.latestDiagnostic() == null);
    _ = try create.execute();
    _ = try exec(&connection, "INSERT INTO unique_values VALUES (1)");
    var duplicate = try connection.prepareSingle("INSERT INTO unique_values VALUES (1)");
    defer duplicate.deinit();
    try std.testing.expectError(turso.Error.Constraint, duplicate.execute());
    try std.testing.expect((duplicate.latestDiagnostic() orelse return error.MissingConstraintDiagnostic).len != 0);
    try duplicate.reset();
    try std.testing.expect(duplicate.latestDiagnostic() == null);
}

test "file persistence and early row-loop cleanup" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &temp.sub_path,
        "persistent.db",
    });
    defer std.testing.allocator.free(path);

    {
        var database = try openDatabase(path);
        defer database.deinit();
        try database.open();
        var connection = try database.connect();
        defer connection.deinit();
        _ = try exec(&connection, "CREATE TABLE persisted(v TEXT)");
        _ = try exec(&connection, "INSERT INTO persisted VALUES ('kept'), ('second')");
        var rows = try connection.prepareSingle("SELECT v FROM persisted ORDER BY rowid");
        while (try rows.step() == .row) {
            var value = try rows.value(0);
            defer value.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("kept", value.text);
            break;
        }
        try rows.finalize();
        rows.deinit();
        try connection.close();
    }
    {
        var database = try openDatabase(path);
        defer database.deinit();
        try database.open();
        var connection = try database.connect();
        defer connection.deinit();
        var rows = try connection.prepareSingle("SELECT count(*) FROM persisted");
        defer rows.deinit();
        try std.testing.expectEqual(turso.Step.row, try rows.step());
        var count = try rows.value(0);
        defer count.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(i64, 2), count.integer);
    }
}

test "managed scalar callbacks cover arity options and every SQL value kind" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    var deinits: usize = 0;
    try connection.registerScalarFunction(
        "zig_echo",
        .{ .fixed = 1 },
        true,
        turso.ScalarFunction(ScalarContext){
            .context = .{ .deinits = &deinits, .mode = .echo },
            .call = scalarCall,
            .deinit = scalarDeinit,
        },
    );

    const cases = [_]struct { sql: []const u8, expected: turso.Value }{
        .{ .sql = "SELECT zig_echo(NULL)", .expected = .null },
        .{ .sql = "SELECT zig_echo(-42)", .expected = .{ .integer = -42 } },
        .{ .sql = "SELECT zig_echo(1.25)", .expected = .{ .real = 1.25 } },
        .{ .sql = "SELECT zig_echo('a' || char(0) || 'b')", .expected = .{ .text = @constCast("a\x00b") } },
        .{ .sql = "SELECT zig_echo(json('{\"a\":1}'))", .expected = .{ .text = @constCast("{\"a\":1}") } },
        .{ .sql = "SELECT zig_echo(x'0001ff')", .expected = .{ .blob = @constCast(&[_]u8{ 0, 1, 255 }) } },
        .{ .sql = "SELECT zig_echo('')", .expected = .{ .text = @constCast("") } },
        .{ .sql = "SELECT zig_echo(x'')", .expected = .{ .blob = @constCast(&[_]u8{}) } },
    };
    for (cases) |case| {
        var actual = try queryValue(&connection, case.sql);
        defer actual.deinit(std.testing.allocator);
        switch (case.expected) {
            .null => try std.testing.expect(actual == .null),
            .integer => |expected| try std.testing.expectEqual(expected, actual.integer),
            .real => |expected| try std.testing.expectEqual(expected, actual.real),
            .text => |expected| try std.testing.expectEqualStrings(expected, actual.text),
            .blob => |expected| try std.testing.expectEqualSlices(u8, expected, actual.blob),
        }
    }

    try connection.registerScalarFunction(
        "zig_count",
        .variadic,
        false,
        turso.ScalarFunction(ScalarContext){
            .context = .{ .deinits = &deinits, .mode = .echo },
            .call = scalarCall,
            .deinit = scalarDeinit,
        },
    );
    var zero = try queryValue(&connection, "SELECT zig_count()");
    defer zero.deinit(std.testing.allocator);
    try std.testing.expect(zero == .null);
    try connection.unregisterFunction("zig_count");
    try std.testing.expectEqual(@as(usize, 1), deinits);
}

test "managed scalar replacement unregister and connection teardown destroy contexts exactly once" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var deinits: usize = 0;
    {
        var connection = try database.connect();
        defer connection.deinit();
        try connection.registerScalarFunction("zig_life", .{ .fixed = 0 }, true, turso.ScalarFunction(ScalarContext){
            .context = .{ .deinits = &deinits, .mode = .echo },
            .call = scalarCall,
            .deinit = scalarDeinit,
        });
        try connection.registerScalarFunction("zig_life", .{ .fixed = 0 }, true, turso.ScalarFunction(ScalarContext){
            .context = .{ .deinits = &deinits, .mode = .replacement },
            .call = scalarCall,
            .deinit = scalarDeinit,
        });
        try std.testing.expectEqual(@as(usize, 1), deinits);
        var value = try queryValue(&connection, "SELECT zig_life()");
        defer value.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(i64, 99), value.integer);
    }
    try std.testing.expectEqual(@as(usize, 2), deinits);
}

test "managed scalar validates names and arities before taking ownership" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var deinits: usize = 0;
    const function = turso.ScalarFunction(ScalarContext){
        .context = .{ .deinits = &deinits, .mode = .echo },
        .call = scalarCall,
        .deinit = scalarDeinit,
    };
    try std.testing.expectError(turso.Error.InvalidArgument, connection.registerScalarFunction("", .variadic, false, function));
    try std.testing.expectError(turso.Error.InvalidArgument, connection.registerScalarFunction("bad\x00name", .variadic, false, function));
    try std.testing.expectError(turso.Error.InvalidArgument, connection.registerScalarFunction("bad\xff", .variadic, false, function));
    try std.testing.expectError(turso.Error.InvalidArgument, connection.registerScalarFunction("too_many", .{ .fixed = 128 }, false, function));
    try std.testing.expectEqual(@as(usize, 0), deinits);
}

test "extension result codes and text subtypes are exhaustive" {
    try std.testing.expectEqual(@as(usize, 22), @typeInfo(turso.ExtensionResultCode).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(turso.ExtensionTextSubtype).@"enum".fields.len);
    inline for (@typeInfo(turso.ExtensionResultCode).@"enum".fields, 0..) |field, expected| {
        try std.testing.expectEqual(expected, field.value);
    }
}

test "unstable raw namespace exposes pinned ABI" {
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

    try expectStatus(turso.c.TURSO_OK, turso.c.turso_database_open(database, &error_message), &error_message);

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

    try expectStatus(turso.c.TURSO_ROW, turso.c.turso_statement_step(statement, &error_message), &error_message);
    try std.testing.expectEqual(@as(i64, 1), turso.c.turso_statement_column_count(statement));
    try std.testing.expectEqual(
        @as(turso.c.turso_type_t, turso.c.TURSO_TYPE_INTEGER),
        turso.c.turso_statement_row_value_kind(statement, 0),
    );
    try std.testing.expectEqual(@as(i64, 1), turso.c.turso_statement_row_value_int(statement, 0));

    try expectStatus(turso.c.TURSO_DONE, turso.c.turso_statement_step(statement, &error_message), &error_message);
    try expectStatus(turso.c.TURSO_DONE, turso.c.turso_statement_finalize(statement, &error_message), &error_message);
    try expectStatus(turso.c.TURSO_OK, turso.c.turso_connection_close(connection, &error_message), &error_message);
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
