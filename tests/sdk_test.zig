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

fn countScalar(_: *void, args: turso.CallbackArgs) turso.CallbackResult {
    return .{ .integer = @intCast(args.values.len) };
}

fn textSubtypeScalar(_: *void, args: turso.CallbackArgs) turso.CallbackResult {
    const subtype = args.values[0].text.subtype;
    return .{ .integer = @intCast(@intFromEnum(subtype)) };
}

fn jsonResultScalar(_: *void, _: turso.CallbackArgs) turso.CallbackResult {
    return .{ .text = .{ .subtype = .json, .bytes = "{\"managed\":true}" } };
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

test "extension control public signatures distinguish the SQL gate from unsafe direct loading" {
    const set_gate: *const fn (*turso.Connection, bool) turso.Error!void = turso.Connection.setSqlExtensionLoadingEnabledUnsafe;
    const direct_load: *const fn (*turso.Connection, []const u8) turso.Error!void = turso.Connection.loadExtensionUnsafe;
    _ = set_gate;
    _ = direct_load;
}

fn expectSqlExtensionFailure(connection: *turso.Connection, expected: []const u8) !void {
    var statement = try connection.prepareSingle("SELECT load_extension('definitely_missing_extension')");
    defer statement.deinit();
    try std.testing.expectError(turso.Error.SqlError, statement.step());
    try std.testing.expect(std.mem.indexOf(
        u8,
        statement.latestDiagnostic() orelse return error.MissingExtensionDiagnostic,
        expected,
    ) != null);
}

test "SQL extension loading is disabled by default and enabled per connection" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var enabled = try database.connect();
    defer enabled.deinit();
    var disabled = try database.connect();
    defer disabled.deinit();

    try expectSqlExtensionFailure(&enabled, "runtime extension loading is disabled");
    try enabled.setSqlExtensionLoadingEnabledUnsafe(true);
    try expectSqlExtensionFailure(&enabled, "Extension file not found");
    try expectSqlExtensionFailure(&disabled, "runtime extension loading is disabled");
    try enabled.setSqlExtensionLoadingEnabledUnsafe(false);
    try expectSqlExtensionFailure(&enabled, "runtime extension loading is disabled");
}

test "unsafe direct extension loading bypasses the SQL gate for an isolated missing path" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    try std.testing.expectError(turso.Error.SqlError, connection.loadExtensionUnsafe("/definitely/missing/libextension.so"));
    const missing = connection.latestDiagnostic() orelse return error.MissingDirectExtensionDiagnostic;
    try std.testing.expect(std.mem.indexOf(u8, missing, "Extension file not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "runtime extension loading is disabled") == null);
}

test "unsafe direct extension loading validates absolute bounded UTF-8 paths and replaces diagnostics" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    const diagnostic = "extension path must be an absolute 1..4095-byte UTF-8 path without NUL";
    const invalid_paths = [_][]const u8{
        "",
        "relative/path.so",
        "libbare.so",
        "/bad\xffpath.so",
        "/bad\x00path.so",
    };
    for (invalid_paths) |path| {
        try std.testing.expectError(turso.Error.InvalidArgument, connection.loadExtensionUnsafe(path));
        try std.testing.expectEqualStrings(
            diagnostic,
            connection.latestDiagnostic() orelse return error.MissingInvalidExtensionPathDiagnostic,
        );
    }

    const accepted = try std.testing.allocator.alloc(u8, 4095);
    defer std.testing.allocator.free(accepted);
    @memset(accepted, 'x');
    accepted[0] = '/';
    try std.testing.expectError(turso.Error.SqlError, connection.loadExtensionUnsafe(accepted));
    try std.testing.expect(!std.mem.eql(u8, diagnostic, connection.latestDiagnostic() orelse ""));

    const oversized = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    oversized[0] = '/';
    try std.testing.expectError(turso.Error.InvalidArgument, connection.loadExtensionUnsafe(oversized));
    try std.testing.expectEqualStrings(
        diagnostic,
        connection.latestDiagnostic() orelse return error.MissingOversizedExtensionPathDiagnostic,
    );
}

test "extension controls reject active statements and closed connections before native mutation" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    var statement = try connection.prepareSingle("SELECT 1");
    try std.testing.expectError(turso.Error.InvalidState, connection.setSqlExtensionLoadingEnabledUnsafe(true));
    try std.testing.expectEqualStrings(
        "extension controls cannot mutate the schema while statements are active",
        connection.latestDiagnostic() orelse return error.MissingActiveExtensionDiagnostic,
    );
    try std.testing.expectError(turso.Error.InvalidState, connection.loadExtensionUnsafe("/definitely/missing/libextension.so"));
    statement.deinit();

    try connection.close();
    try std.testing.expectError(turso.Error.InvalidState, connection.setSqlExtensionLoadingEnabledUnsafe(true));
    try std.testing.expectEqualStrings("connection is closed", connection.latestDiagnostic().?);
    try std.testing.expectError(turso.Error.InvalidState, connection.loadExtensionUnsafe("/definitely/missing/libextension.so"));
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
        .{ .sql = "SELECT json_type(zig_echo(json('{\"a\":1}')))", .expected = .{ .text = @constCast("object") } },
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

    try std.testing.expectError(turso.Error.SqlError, connection.prepareSingle("SELECT zig_echo()"));

    try connection.registerScalarFunction("zig_variadic", .variadic, false, turso.ScalarFunction(void){
        .context = {},
        .call = countScalar,
    });
    var multi = try queryValue(&connection, "SELECT zig_variadic(1, 2, 3, 4)");
    defer multi.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 4), multi.integer);

    try connection.registerScalarFunction("zig_high", .{ .fixed = 127 }, false, turso.ScalarFunction(void){
        .context = {},
        .call = countScalar,
    });
    var sql_buffer: [512]u8 = undefined;
    var sql_length: usize = 0;
    const prefix = "SELECT zig_high(";
    @memcpy(sql_buffer[0..prefix.len], prefix);
    sql_length += prefix.len;
    for (0..127) |index| {
        if (index != 0) {
            sql_buffer[sql_length] = ',';
            sql_length += 1;
        }
        sql_buffer[sql_length] = '0';
        sql_length += 1;
    }
    sql_buffer[sql_length] = ')';
    sql_length += 1;
    var high = try queryValue(&connection, sql_buffer[0..sql_length]);
    defer high.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 127), high.integer);
}

const ErrorContext = struct {
    code: turso.ExtensionResultCode,
    deinits: *usize,
};

fn errorScalar(context: *ErrorContext, _: turso.CallbackArgs) turso.CallbackResult {
    return .{ .managed_error = .{ .code = context.code, .message = "managed failure" } };
}

fn errorContextDeinit(context: *ErrorContext) void {
    context.deinits.* += 1;
}

test "0.7.1 callback inputs lose JSON subtype while managed JSON results retain it" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    try connection.registerScalarFunction("zig_subtype", .{ .fixed = 1 }, false, turso.ScalarFunction(void){
        .context = {},
        .call = textSubtypeScalar,
    });
    var subtype = try queryValue(&connection, "SELECT zig_subtype(json('{\"a\":1}'))");
    defer subtype.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, @intFromEnum(turso.ExtensionTextSubtype.text)), subtype.integer);

    try connection.registerScalarFunction("zig_json_result", .{ .fixed = 0 }, false, turso.ScalarFunction(void){
        .context = {},
        .call = jsonResultScalar,
    });
    var json_kind = try queryValue(&connection, "SELECT json_type(zig_json_result())");
    defer json_kind.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("object", json_kind.text);
}

test "managed scalar returns every extension result code without crossing the ABI" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var deinits: usize = 0;

    inline for (@typeInfo(turso.ExtensionResultCode).@"enum".fields, 0..) |field, index| {
        try connection.registerScalarFunction("zig_error", .{ .fixed = 0 }, false, turso.ScalarFunction(ErrorContext){
            .context = .{ .code = @enumFromInt(field.value), .deinits = &deinits },
            .call = errorScalar,
            .deinit = errorContextDeinit,
        });
        if (index != 0) try std.testing.expectEqual(index, deinits);
        {
            var statement = try connection.prepareSingle("SELECT zig_error()");
            defer statement.deinit();
            try std.testing.expectError(turso.Error.SqlError, statement.step());
            try std.testing.expectEqualStrings(
                "Extension error: managed failure",
                statement.latestDiagnostic() orelse return error.MissingManagedErrorDiagnostic,
            );
        }
    }
    try connection.unregisterFunction("zig_error");
    try std.testing.expectEqual(@as(usize, 22), deinits);
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

const ReentryContext = struct {
    connection: *turso.Connection,
    statement: *?*turso.Statement,
    callback_rejected: *bool,
    deinit_rejected: *bool,
};

fn reentryScalar(context: *ReentryContext, _: turso.CallbackArgs) turso.CallbackResult {
    _ = context.connection.prepareSingle("SELECT 1") catch |err| {
        context.callback_rejected.* = err == turso.Error.InvalidState and
            std.mem.eql(u8, context.connection.latestDiagnostic() orelse "", "managed callback re-entry is not allowed");
    };
    context.connection.setBusyTimeoutMs(0) catch {};
    const gate_rejected = rejected: {
        context.connection.setSqlExtensionLoadingEnabledUnsafe(true) catch |err| break :rejected err == turso.Error.InvalidState;
        break :rejected false;
    };
    const direct_load_rejected = rejected: {
        context.connection.loadExtensionUnsafe("/definitely/missing/libextension.so") catch |err| break :rejected err == turso.Error.InvalidState;
        break :rejected false;
    };
    context.callback_rejected.* = context.callback_rejected.* and gate_rejected and direct_load_rejected;
    _ = context.connection.autocommit();
    _ = context.connection.lastInsertRowid();
    context.connection.close() catch {};
    context.connection.deinit();
    if (context.statement.*) |statement| {
        statement.reset() catch {};
        _ = statement.parameterCount() catch {};
        _ = statement.changes();
        statement.deinit();
    }
    return .{ .integer = 1 };
}

fn reentryDeinit(context: *ReentryContext) void {
    const prepare_rejected = rejected: {
        _ = context.connection.prepareSingle("SELECT 1") catch |err| break :rejected err == turso.Error.InvalidState;
        break :rejected false;
    };
    const gate_rejected = rejected: {
        context.connection.setSqlExtensionLoadingEnabledUnsafe(true) catch |err| break :rejected err == turso.Error.InvalidState;
        break :rejected false;
    };
    const direct_load_rejected = rejected: {
        context.connection.loadExtensionUnsafe("/definitely/missing/libextension.so") catch |err| break :rejected err == turso.Error.InvalidState;
        break :rejected false;
    };
    context.deinit_rejected.* = prepare_rejected and gate_rejected and direct_load_rejected;
}

test "scalar callback and deinitializer reject all owner reentry without native access" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var callback_rejected = false;
    var deinit_rejected = false;
    var active_statement: ?*turso.Statement = null;

    try connection.registerScalarFunction("zig_reentry", .{ .fixed = 0 }, false, turso.ScalarFunction(ReentryContext){
        .context = .{
            .connection = &connection,
            .statement = &active_statement,
            .callback_rejected = &callback_rejected,
            .deinit_rejected = &deinit_rejected,
        },
        .call = reentryScalar,
        .deinit = reentryDeinit,
    });
    var statement = try connection.prepareSingle("SELECT zig_reentry()");
    active_statement = &statement;
    try std.testing.expectError(turso.Error.SqlError, statement.step());
    try std.testing.expect(std.mem.indexOf(
        u8,
        statement.latestDiagnostic() orelse return error.MissingReentryDiagnostic,
        "scalar callback re-entry",
    ) != null);
    try std.testing.expect(callback_rejected);
    statement.deinit();
    active_statement = null;
    try connection.unregisterFunction("zig_reentry");
    try std.testing.expect(deinit_rejected);
    try connection.close();
}

test "prepared programs block scalar replacement until deinit" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var deinits: usize = 0;

    try connection.registerScalarFunction("zig_prepared", .{ .fixed = 0 }, true, turso.ScalarFunction(ScalarContext){
        .context = .{ .deinits = &deinits, .mode = .echo },
        .call = scalarCall,
        .deinit = scalarDeinit,
    });
    var prepared = try connection.prepareSingle("SELECT zig_prepared()");
    const replacement = turso.ScalarFunction(ScalarContext){
        .context = .{ .deinits = &deinits, .mode = .replacement },
        .call = scalarCall,
        .deinit = scalarDeinit,
    };
    try std.testing.expectError(turso.Error.InvalidState, connection.registerScalarFunction("zig_prepared", .{ .fixed = 0 }, true, replacement));
    try std.testing.expectEqual(@as(usize, 0), deinits);
    prepared.deinit();
    try connection.registerScalarFunction("zig_prepared", .{ .fixed = 0 }, true, replacement);
    try std.testing.expectEqual(@as(usize, 1), deinits);
    try connection.unregisterFunction("zig_prepared");
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

test "pre-native scalar registration allocation failure leaves context with caller" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var deinits: usize = 0;
    var function = turso.ScalarFunction(ScalarContext){
        .context = .{ .deinits = &deinits, .mode = .echo },
        .call = scalarCall,
        .deinit = scalarDeinit,
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    connection.allocator = failing.allocator();
    try std.testing.expectError(
        turso.Error.OutOfMemory,
        connection.registerScalarFunction("zig_allocation_failure", .{ .fixed = 0 }, false, function),
    );
    connection.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), deinits);
    scalarDeinit(&function.context);
    try std.testing.expectEqual(@as(usize, 1), deinits);
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

const AggregateCounters = struct {
    inits: usize = 0,
    steps: usize = 0,
    finals: usize = 0,
    state_deinits: usize = 0,
    context_deinits: *usize,
};

const SumState = struct { sum: i64 = 0 };

fn aggregateInit(context: *AggregateCounters) ?SumState {
    context.inits += 1;
    return .{};
}

fn aggregateStep(context: *AggregateCounters, state: *SumState, args: turso.CallbackArgs) turso.CallbackResult {
    context.steps += 1;
    for (args.values) |value| switch (value) {
        .integer => |integer| state.sum += integer,
        .null => {},
        else => return .{ .managed_error = .{ .code = .invalid_args, .message = "integer required" } },
    };
    return .null;
}

fn aggregateFinal(context: *AggregateCounters, state: *SumState) turso.CallbackResult {
    context.finals += 1;
    return .{ .integer = state.sum };
}

fn aggregateStateDeinit(context: *AggregateCounters, _: *SumState) void {
    context.state_deinits += 1;
}

fn aggregateContextDeinit(context: *AggregateCounters) void {
    context.context_deinits.* += 1;
}

fn sumAggregate(context_deinits: *usize) turso.AggregateFunction(AggregateCounters, SumState) {
    return .{
        .context = .{ .context_deinits = context_deinits },
        .init = aggregateInit,
        .step = aggregateStep,
        .final = aggregateFinal,
        .state_deinit = aggregateStateDeinit,
        .context_deinit = aggregateContextDeinit,
    };
}

test "managed aggregates cover fixed variadic zero-row groups DISTINCT and FILTER" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var context_deinits: usize = 0;

    try connection.registerAggregateFunction("zig_sum", .{ .fixed = 1 }, sumAggregate(&context_deinits));
    _ = try exec(&connection, "CREATE TABLE aggregate_values(g TEXT, v INTEGER)");
    _ = try exec(&connection, "INSERT INTO aggregate_values VALUES ('a',1),('a',1),('a',2),('b',4),('b',5)");

    var zero = try queryValue(&connection, "SELECT zig_sum(v) FROM aggregate_values WHERE 0");
    defer zero.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), zero.integer);
    var filtered = try queryValue(&connection, "SELECT zig_sum(DISTINCT v) FILTER (WHERE v < 5) FROM aggregate_values");
    defer filtered.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 7), filtered.integer);
    var step_failure = try connection.prepareSingle("SELECT zig_sum('bad')");
    try std.testing.expectError(turso.Error.SqlError, step_failure.step());
    try std.testing.expect(std.mem.indexOf(u8, step_failure.latestDiagnostic() orelse "", "integer required") != null);
    step_failure.deinit();

    var groups = try connection.prepareSingle("SELECT g, zig_sum(v) FROM aggregate_values GROUP BY g ORDER BY g");
    try std.testing.expectEqual(turso.Step.row, try groups.step());
    var first = try groups.value(1);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 4), first.integer);
    try std.testing.expectEqual(turso.Step.row, try groups.step());
    var second = try groups.value(1);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 9), second.integer);
    try std.testing.expectEqual(turso.Step.done, try groups.step());
    groups.deinit();

    try connection.registerAggregateFunction("zig_variadic_sum", .variadic, sumAggregate(&context_deinits));
    var variadic = try queryValue(&connection, "SELECT zig_variadic_sum(v, 1) FROM aggregate_values");
    defer variadic.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 18), variadic.integer);
    try std.testing.expectError(turso.Error.SqlError, connection.prepareSingle("SELECT zig_sum()"));
}

const AggregateResultState = struct { value: turso.CallbackResult };
fn resultInit(context: *AggregateResultState) ?turso.CallbackResult {
    return context.value;
}
fn resultStep(_: *AggregateResultState, state: *turso.CallbackResult, _: turso.CallbackArgs) turso.CallbackResult {
    return switch (state.*) {
        .managed_error => .null,
        else => state.*,
    };
}
fn resultFinal(_: *AggregateResultState, state: *turso.CallbackResult) turso.CallbackResult {
    return state.*;
}

test "managed aggregate final copies every SQL result kind and reports managed errors" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    const cases = [_]struct { result: turso.CallbackResult, sql: []const u8 }{
        .{ .result = .null, .sql = "SELECT zig_result(1) IS NULL" },
        .{ .result = .{ .integer = 42 }, .sql = "SELECT zig_result(1) = 42" },
        .{ .result = .{ .float = 1.5 }, .sql = "SELECT zig_result(1) = 1.5" },
        .{ .result = .{ .text = .{ .subtype = .text, .bytes = "text" } }, .sql = "SELECT zig_result(1) = 'text'" },
        .{ .result = .{ .text = .{ .subtype = .json, .bytes = "{\"a\":1}" } }, .sql = "SELECT json_type(zig_result(1)) = 'object'" },
        .{ .result = .{ .blob = &.{ 0, 1, 255 } }, .sql = "SELECT zig_result(1) = x'0001ff'" },
    };
    for (cases) |case| {
        try connection.registerAggregateFunction("zig_result", .{ .fixed = 1 }, turso.AggregateFunction(AggregateResultState, turso.CallbackResult){
            .context = .{ .value = case.result },
            .init = resultInit,
            .step = resultStep,
            .final = resultFinal,
        });
        var value = try queryValue(&connection, case.sql);
        defer value.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(i64, 1), value.integer);
    }

    inline for (@typeInfo(turso.ExtensionResultCode).@"enum".fields) |field| {
        try connection.registerAggregateFunction("zig_result_error", .{ .fixed = 0 }, turso.AggregateFunction(AggregateResultState, turso.CallbackResult){
            .context = .{ .value = .{ .managed_error = .{ .code = @enumFromInt(field.value), .message = "aggregate failure" } } },
            .init = resultInit,
            .step = resultStep,
            .final = resultFinal,
        });
        var statement = try connection.prepareSingle("SELECT zig_result_error()");
        defer statement.deinit();
        try std.testing.expectError(turso.Error.SqlError, statement.step());
    }
}

const ReentryAggregateState = struct {};
fn reentryAggregateInit(_: *ReentryContext) ?ReentryAggregateState {
    return .{};
}
fn reentryAggregateStep(context: *ReentryContext, _: *ReentryAggregateState, _: turso.CallbackArgs) turso.CallbackResult {
    return reentryScalar(context, .{ .values = &.{} });
}
fn reentryAggregateFinal(context: *ReentryContext, _: *ReentryAggregateState) turso.CallbackResult {
    return reentryScalar(context, .{ .values = &.{} });
}

test "aggregate callbacks and destructors reject connection and statement reentry" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var callback_rejected = false;
    var deinit_rejected = false;
    var active_statement: ?*turso.Statement = null;
    try connection.registerAggregateFunction("zig_aggregate_reentry", .{ .fixed = 1 }, turso.AggregateFunction(ReentryContext, ReentryAggregateState){
        .context = .{ .connection = &connection, .statement = &active_statement, .callback_rejected = &callback_rejected, .deinit_rejected = &deinit_rejected },
        .init = reentryAggregateInit,
        .step = reentryAggregateStep,
        .final = reentryAggregateFinal,
        .context_deinit = reentryDeinit,
    });
    var statement = try connection.prepareSingle("SELECT zig_aggregate_reentry(v) FROM (SELECT 1 AS v)");
    active_statement = &statement;
    try std.testing.expectError(turso.Error.SqlError, statement.step());
    try std.testing.expect(callback_rejected);
    statement.deinit();
    active_statement = null;
    try connection.unregisterFunction("zig_aggregate_reentry");
    try std.testing.expect(deinit_rejected);
}

const ExternalAggregateCounters = struct {
    inits: usize = 0,
    steps: usize = 0,
    finals: usize = 0,
    state_deinits: usize = 0,
    context_deinits: usize = 0,
};
const ExternalAggregateContext = struct { counters: *ExternalAggregateCounters };
fn externalInit(context: *ExternalAggregateContext) ?i64 {
    context.counters.inits += 1;
    return 0;
}
fn externalStep(context: *ExternalAggregateContext, state: *i64, args: turso.CallbackArgs) turso.CallbackResult {
    context.counters.steps += 1;
    for (args.values) |value| if (value == .integer) {
        state.* += value.integer;
    };
    return .null;
}
fn externalFinal(context: *ExternalAggregateContext, state: *i64) turso.CallbackResult {
    context.counters.finals += 1;
    return .{ .integer = state.* };
}
fn externalStateDeinit(context: *ExternalAggregateContext, _: *i64) void {
    context.counters.state_deinits += 1;
}
fn externalContextDeinit(context: *ExternalAggregateContext) void {
    context.counters.context_deinits += 1;
}
fn externalAggregate(counters: *ExternalAggregateCounters) turso.AggregateFunction(ExternalAggregateContext, i64) {
    return .{
        .context = .{ .counters = counters },
        .init = externalInit,
        .step = externalStep,
        .final = externalFinal,
        .state_deinit = externalStateDeinit,
        .context_deinit = externalContextDeinit,
    };
}

test "window peers reuse aggregate state through repeated native release" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var counters: ExternalAggregateCounters = .{};
    try connection.registerAggregateFunction("zig_window_sum", .{ .fixed = 1 }, externalAggregate(&counters));

    var statement = try connection.prepareSingle(
        "SELECT zig_window_sum(v) OVER (ORDER BY v RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) " ++
            "FROM (SELECT 1 AS v UNION ALL SELECT 1 UNION ALL SELECT 2) ORDER BY v",
    );
    errdefer statement.deinit();
    try std.testing.expectEqual(turso.Step.row, try statement.step());
    var first = try statement.value(0);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 2), first.integer);
    try std.testing.expectEqual(turso.Step.row, try statement.step());
    var peer = try statement.value(0);
    defer peer.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 2), peer.integer);
    try std.testing.expectEqual(turso.Step.row, try statement.step());
    var cumulative = try statement.value(0);
    defer cumulative.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 4), cumulative.integer);
    try std.testing.expectEqual(turso.Step.done, try statement.step());
    statement.deinit();
    try std.testing.expectEqual(counters.inits, counters.state_deinits);
    try std.testing.expectEqual(@as(usize, 2), counters.finals);
    try connection.unregisterFunction("zig_window_sum");
    try std.testing.expectEqual(@as(usize, 1), counters.context_deinits);
}

fn managedErrorStep(context: *ExternalAggregateContext, _: *i64, _: turso.CallbackArgs) turso.CallbackResult {
    context.counters.steps += 1;
    return .{ .managed_error = .{ .code = .custom_error, .message = "step counter error" } };
}
fn managedErrorFinal(context: *ExternalAggregateContext, _: *i64) turso.CallbackResult {
    context.counters.finals += 1;
    return .{ .managed_error = .{ .code = .custom_error, .message = "final counter error" } };
}

test "aggregate step and final managed errors reclaim state with exact counters" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    var step_counters: ExternalAggregateCounters = .{};
    try connection.registerAggregateFunction("zig_step_error", .{ .fixed = 1 }, turso.AggregateFunction(ExternalAggregateContext, i64){
        .context = .{ .counters = &step_counters },
        .init = externalInit,
        .step = managedErrorStep,
        .final = externalFinal,
        .state_deinit = externalStateDeinit,
        .context_deinit = externalContextDeinit,
    });
    var step_statement = try connection.prepareSingle("SELECT zig_step_error(1)");
    try std.testing.expectError(turso.Error.SqlError, step_statement.step());
    step_statement.deinit();
    try std.testing.expectEqual(@as(usize, 1), step_counters.inits);
    try std.testing.expectEqual(@as(usize, 1), step_counters.steps);
    try std.testing.expectEqual(@as(usize, 1), step_counters.state_deinits);
    try connection.unregisterFunction("zig_step_error");
    try std.testing.expectEqual(@as(usize, 1), step_counters.context_deinits);

    var final_counters: ExternalAggregateCounters = .{};
    try connection.registerAggregateFunction("zig_final_error", .{ .fixed = 1 }, turso.AggregateFunction(ExternalAggregateContext, i64){
        .context = .{ .counters = &final_counters },
        .init = externalInit,
        .step = externalStep,
        .final = managedErrorFinal,
        .state_deinit = externalStateDeinit,
        .context_deinit = externalContextDeinit,
    });
    var final_statement = try connection.prepareSingle("SELECT zig_final_error(1)");
    try std.testing.expectError(turso.Error.SqlError, final_statement.step());
    final_statement.deinit();
    try std.testing.expectEqual(@as(usize, 1), final_counters.inits);
    try std.testing.expectEqual(@as(usize, 1), final_counters.finals);
    try std.testing.expectEqual(@as(usize, 1), final_counters.state_deinits);
    try connection.unregisterFunction("zig_final_error");
    try std.testing.expectEqual(@as(usize, 1), final_counters.context_deinits);
}

test "aggregate reset abandonment is reclaimed when the final statement deinitializes" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var counters: ExternalAggregateCounters = .{};
    try connection.registerAggregateFunction("zig_abandoned", .{ .fixed = 1 }, externalAggregate(&counters));

    var aggregate_statement = try connection.prepareSingle(
        "SELECT g, zig_abandoned(v) FROM (SELECT 1 AS g, 1 AS v UNION ALL SELECT 2, 2 UNION ALL SELECT 3, 3) GROUP BY g ORDER BY g",
    );
    var keeper = try connection.prepareSingle("SELECT 1");
    try std.testing.expectEqual(turso.Step.row, try aggregate_statement.step());
    try aggregate_statement.reset();
    aggregate_statement.deinit();
    try std.testing.expect(counters.inits >= counters.state_deinits);
    keeper.deinit();
    try std.testing.expectEqual(counters.inits, counters.state_deinits);
    try connection.unregisterFunction("zig_abandoned");
    try std.testing.expectEqual(@as(usize, 1), counters.context_deinits);
}

const ReentryPhase = enum { init, step, final, state_deinit, context_deinit };
const AggregatePhaseContext = struct {
    connection: *turso.Connection,
    phase: ReentryPhase,
    rejected: *bool,
};
fn attemptAggregateReentry(context: *AggregatePhaseContext) void {
    var unexpected = context.connection.prepareSingle("SELECT 1") catch |err| {
        context.rejected.* = err == turso.Error.InvalidState;
        return;
    };
    unexpected.deinit();
}
fn phaseInit(context: *AggregatePhaseContext) ?u8 {
    if (context.phase == .init) attemptAggregateReentry(context);
    return 0;
}
fn phaseStep(context: *AggregatePhaseContext, _: *u8, _: turso.CallbackArgs) turso.CallbackResult {
    if (context.phase == .step) attemptAggregateReentry(context);
    return .null;
}
fn phaseFinal(context: *AggregatePhaseContext, _: *u8) turso.CallbackResult {
    if (context.phase == .final) attemptAggregateReentry(context);
    return .{ .integer = 1 };
}
fn phaseStateDeinit(context: *AggregatePhaseContext, _: *u8) void {
    if (context.phase == .state_deinit) attemptAggregateReentry(context);
}
fn phaseContextDeinit(context: *AggregatePhaseContext) void {
    if (context.phase == .context_deinit) attemptAggregateReentry(context);
}

test "aggregate init step final state and context reentry guards restore independently" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();

    inline for (std.enums.values(ReentryPhase)) |phase| {
        var rejected = false;
        try connection.registerAggregateFunction("zig_phase", .{ .fixed = 1 }, turso.AggregateFunction(AggregatePhaseContext, u8){
            .context = .{ .connection = &connection, .phase = phase, .rejected = &rejected },
            .init = phaseInit,
            .step = phaseStep,
            .final = phaseFinal,
            .state_deinit = phaseStateDeinit,
            .context_deinit = phaseContextDeinit,
        });
        var statement = try connection.prepareSingle("SELECT zig_phase(1)");
        switch (phase) {
            .init, .step, .final => try std.testing.expectError(turso.Error.SqlError, statement.step()),
            .state_deinit, .context_deinit => try std.testing.expectEqual(turso.Step.row, try statement.step()),
        }
        statement.deinit();
        try connection.unregisterFunction("zig_phase");
        try std.testing.expect(rejected);
    }
}

const AggregateLifetimeContext = struct {
    state_deinits: *usize,
    context_deinits: *usize,
};
fn lifetimeInit(_: *AggregateLifetimeContext) ?u8 {
    return 0;
}
fn lifetimeStep(_: *AggregateLifetimeContext, state: *u8, _: turso.CallbackArgs) turso.CallbackResult {
    state.* +%= 1;
    return .null;
}
fn lifetimeFinal(_: *AggregateLifetimeContext, state: *u8) turso.CallbackResult {
    return .{ .integer = state.* };
}
fn lifetimeStateDeinit(context: *AggregateLifetimeContext, _: *u8) void {
    context.state_deinits.* += 1;
}
fn lifetimeContextDeinit(context: *AggregateLifetimeContext) void {
    context.context_deinits.* += 1;
}
fn lifetimeAggregate(state_deinits: *usize, context_deinits: *usize) turso.AggregateFunction(AggregateLifetimeContext, u8) {
    return .{
        .context = .{ .state_deinits = state_deinits, .context_deinits = context_deinits },
        .init = lifetimeInit,
        .step = lifetimeStep,
        .final = lifetimeFinal,
        .state_deinit = lifetimeStateDeinit,
        .context_deinit = lifetimeContextDeinit,
    };
}

test "function table mutations wait for every aggregate statement to deinit" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var state_deinits: usize = 0;
    var context_deinits: usize = 0;

    try connection.registerAggregateFunction("zig_lifetime", .{ .fixed = 1 }, lifetimeAggregate(&state_deinits, &context_deinits));
    var first = try connection.prepareSingle("SELECT g, zig_lifetime(v) FROM (SELECT 1 AS g, 1 AS v UNION ALL SELECT 1, 2 UNION ALL SELECT 2, 3) GROUP BY g ORDER BY g");
    var second = try connection.prepareSingle("SELECT zig_lifetime(v) FROM (SELECT 4 AS v UNION ALL SELECT 5)");
    try std.testing.expectEqual(turso.Step.row, try first.step());

    try std.testing.expectError(turso.Error.InvalidState, connection.registerAggregateFunction("zig_lifetime", .{ .fixed = 1 }, lifetimeAggregate(&state_deinits, &context_deinits)));
    try std.testing.expectEqualStrings("function table cannot be mutated while statements are active", connection.latestDiagnostic().?);
    try std.testing.expectError(turso.Error.InvalidState, connection.registerScalarFunction("zig_lifetime", .{ .fixed = 0 }, false, turso.ScalarFunction(void){ .context = {}, .call = countScalar }));
    try std.testing.expectError(turso.Error.InvalidState, connection.unregisterFunction("zig_lifetime"));

    first.deinit();
    try std.testing.expectError(turso.Error.InvalidState, connection.unregisterFunction("zig_lifetime"));
    second.deinit();
    try connection.registerAggregateFunction("zig_lifetime", .{ .fixed = 1 }, lifetimeAggregate(&state_deinits, &context_deinits));
    try connection.unregisterFunction("zig_lifetime");
}

test "aggregate replacement unregister failures and connection teardown own lifetimes exactly once" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var state_deinits: usize = 0;
    var context_deinits: usize = 0;
    {
        var connection = try database.connect();
        defer connection.deinit();
        try connection.registerAggregateFunction("zig_lifetime", .{ .fixed = 1 }, lifetimeAggregate(&state_deinits, &context_deinits));
        var value = try queryValue(&connection, "SELECT zig_lifetime(v) FROM (SELECT 1 AS v UNION ALL SELECT 2)");
        value.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), state_deinits);

        var retired = try connection.prepareSingle("SELECT zig_lifetime(v) FROM (SELECT 1 AS v)");
        try std.testing.expectError(turso.Error.InvalidState, connection.registerAggregateFunction("zig_lifetime", .{ .fixed = 1 }, lifetimeAggregate(&state_deinits, &context_deinits)));
        try std.testing.expectEqual(@as(usize, 0), context_deinits);
        retired.deinit();
        try connection.registerAggregateFunction("zig_lifetime", .{ .fixed = 1 }, lifetimeAggregate(&state_deinits, &context_deinits));
        try std.testing.expectEqual(@as(usize, 1), context_deinits);

        var failure = try connection.prepareSingle("SELECT zig_lifetime('bad')");
        try std.testing.expectError(turso.Error.InvalidState, connection.unregisterFunction("zig_lifetime"));
        failure.deinit();
        try connection.unregisterFunction("zig_lifetime");
        try std.testing.expectEqual(@as(usize, 2), context_deinits);
        try std.testing.expectError(turso.Error.SqlError, connection.prepareSingle("SELECT zig_lifetime(1)"));

        try connection.registerAggregateFunction("zig_teardown", .{ .fixed = 1 }, lifetimeAggregate(&state_deinits, &context_deinits));
    }
    try std.testing.expectEqual(@as(usize, 3), context_deinits);
}

test "pre-native aggregate registration allocation failure leaves context caller-owned" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var state_deinits: usize = 0;
    var context_deinits: usize = 0;
    var function = lifetimeAggregate(&state_deinits, &context_deinits);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    connection.allocator = failing.allocator();
    try std.testing.expectError(
        turso.Error.OutOfMemory,
        connection.registerAggregateFunction("zig_aggregate_allocation_failure", .{ .fixed = 1 }, function),
    );
    connection.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), context_deinits);
    lifetimeContextDeinit(&function.context);
    try std.testing.expectEqual(@as(usize, 1), context_deinits);
}

test "managed aggregate validates names and arities before taking ownership" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var state_deinits: usize = 0;
    var context_deinits: usize = 0;
    const function = lifetimeAggregate(&state_deinits, &context_deinits);
    try std.testing.expectError(turso.Error.InvalidArgument, connection.registerAggregateFunction("", .variadic, function));
    try std.testing.expectError(turso.Error.InvalidArgument, connection.registerAggregateFunction("bad\x00name", .variadic, function));
    try std.testing.expectError(turso.Error.InvalidArgument, connection.registerAggregateFunction("bad\xff", .variadic, function));
    try std.testing.expectError(turso.Error.InvalidArgument, connection.registerAggregateFunction("too_many", .{ .fixed = 128 }, function));
    try std.testing.expectEqual(@as(usize, 0), context_deinits);
}

const CollationContext = struct {
    comparisons: usize = 0,
    deinits: *usize,
    reverse: bool = false,
};

fn compareCollation(context: *CollationContext, left: []const u8, right: []const u8) std.math.Order {
    context.comparisons += 1;
    const order = std.mem.order(u8, left, right);
    return if (context.reverse) order.invert() else order;
}

fn deinitCollation(context: *CollationContext) void {
    context.deinits.* += 1;
}

fn managedCollation(deinits: *usize, reverse: bool) turso.Collation(CollationContext) {
    return .{
        .context = .{ .deinits = deinits, .reverse = reverse },
        .compare = compareCollation,
        .deinit = deinitCollation,
    };
}

fn expectText(connection: *turso.Connection, sql: []const u8, expected: []const u8) !void {
    var value = try queryValue(connection, sql);
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, value.text);
}

test "managed collations order and equate ASCII UTF-8 and empty text per connection" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var first = try database.connect();
    defer first.deinit();
    var second = try database.connect();
    defer second.deinit();
    var deinits: usize = 0;

    try first.registerCollation("zig_bytes", managedCollation(&deinits, false));
    try expectText(&first, "SELECT v FROM (SELECT '' v UNION ALL SELECT 'z' UNION ALL SELECT 'é' UNION ALL SELECT 'a') ORDER BY v COLLATE zig_bytes LIMIT 1", "");
    try expectText(&first, "SELECT v FROM (SELECT 'é' v UNION ALL SELECT 'z') ORDER BY v COLLATE zig_bytes LIMIT 1", "z");
    var equality = try queryValue(&first, "SELECT 'same' = 'same' COLLATE zig_bytes");
    defer equality.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), equality.integer);
    try std.testing.expectError(turso.Error.SqlError, second.prepareSingle("SELECT 'a' COLLATE zig_bytes"));
}

test "managed collation replacement unregister absence and teardown destroy exactly once" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var deinits: usize = 0;
    {
        var connection = try database.connect();
        defer connection.deinit();
        try connection.registerCollation("zig_life", managedCollation(&deinits, false));
        try connection.registerCollation("zig_life", managedCollation(&deinits, true));
        try std.testing.expectEqual(@as(usize, 1), deinits);
        try expectText(&connection, "SELECT v FROM (SELECT 'a' v UNION ALL SELECT 'z') ORDER BY v COLLATE zig_life LIMIT 1", "z");
        try connection.unregisterCollation("zig_life");
        try std.testing.expectEqual(@as(usize, 2), deinits);
        try connection.unregisterCollation("zig_life");
        try std.testing.expectEqual(@as(usize, 2), deinits);
        try connection.registerCollation("zig_teardown", managedCollation(&deinits, false));
    }
    try std.testing.expectEqual(@as(usize, 3), deinits);
}

test "managed collation validates names and preserves caller ownership on allocation failure" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var deinits: usize = 0;
    var collation = managedCollation(&deinits, false);

    try std.testing.expectError(turso.Error.InvalidArgument, connection.registerCollation("", collation));
    try std.testing.expectError(turso.Error.InvalidArgument, connection.registerCollation("bad\x00name", collation));
    try std.testing.expectError(turso.Error.InvalidArgument, connection.registerCollation("bad\xff", collation));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    connection.allocator = failing.allocator();
    try std.testing.expectError(turso.Error.OutOfMemory, connection.registerCollation("zig_oom", collation));
    connection.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), deinits);
    deinitCollation(&collation.context);
    try std.testing.expectEqual(@as(usize, 1), deinits);
}

const CollationReentryPhase = enum { compare, context_deinit };
const CollationReentryOperation = enum {
    connection_prepare,
    connection_latest_diagnostic,
    connection_busy_timeout,
    connection_autocommit,
    connection_last_insert_rowid,
    connection_close,
    connection_deinit,
    statement_latest_diagnostic,
    statement_reset,
    statement_parameter_count,
    statement_changes,
    statement_deinit,
};
const retained_connection_diagnostic = "retained connection diagnostic";
const retained_statement_diagnostic = "retained statement diagnostic";

const CollationReentryContext = struct {
    connection: *turso.Connection,
    statement: *turso.Statement,
    phase: CollationReentryPhase,
    operation: CollationReentryOperation,
    native_last_insert_rowid: *i64,
    native_statement_changes: *i64,
    rejected: *bool,
};

fn expectCollationReentryRejected(context: *CollationReentryContext) !void {
    switch (context.operation) {
        .connection_prepare => try std.testing.expectError(
            turso.Error.InvalidState,
            context.connection.prepareSingle("SELECT 1"),
        ),
        .connection_latest_diagnostic => switch (context.phase) {
            .compare => try std.testing.expectEqualStrings(
                retained_connection_diagnostic,
                context.connection.latestDiagnostic() orelse return error.MissingRetainedConnectionDiagnostic,
            ),
            .context_deinit => try std.testing.expect(context.connection.latestDiagnostic() == null),
        },
        .connection_busy_timeout => try std.testing.expectError(
            turso.Error.InvalidState,
            context.connection.setBusyTimeoutMs(0),
        ),
        .connection_autocommit => try std.testing.expect(!context.connection.autocommit()),
        .connection_last_insert_rowid => {
            try std.testing.expect(context.native_last_insert_rowid.* != 0);
            const guarded = context.connection.lastInsertRowid();
            try std.testing.expectEqual(@as(i64, 0), guarded);
            try std.testing.expect(guarded != context.native_last_insert_rowid.*);
        },
        .connection_close => try std.testing.expectError(
            turso.Error.InvalidState,
            context.connection.close(),
        ),
        .connection_deinit => {
            const handle = context.connection.handle;
            context.connection.deinit();
            try std.testing.expectEqual(handle, context.connection.handle);
        },
        .statement_latest_diagnostic => try std.testing.expectEqualStrings(
            retained_statement_diagnostic,
            context.statement.latestDiagnostic() orelse return error.MissingRetainedStatementDiagnostic,
        ),
        .statement_reset => try std.testing.expectError(
            turso.Error.InvalidState,
            context.statement.reset(),
        ),
        .statement_parameter_count => try std.testing.expectError(
            turso.Error.InvalidState,
            context.statement.parameterCount(),
        ),
        .statement_changes => {
            try std.testing.expect(context.native_statement_changes.* != 0);
            const guarded = context.statement.changes();
            try std.testing.expectEqual(@as(i64, 0), guarded);
            try std.testing.expect(guarded != context.native_statement_changes.*);
        },
        .statement_deinit => {
            const handle = context.statement.handle;
            context.statement.deinit();
            try std.testing.expectEqual(handle, context.statement.handle);
        },
    }
}

fn attemptCollationReentry(context: *CollationReentryContext) void {
    expectCollationReentryRejected(context) catch return;
    if (!context.connection.owner_state.callback_violation) return;
    context.rejected.* = true;
}

fn compareWithReentry(context: *CollationReentryContext, left: []const u8, right: []const u8) std.math.Order {
    if (context.phase == .compare) attemptCollationReentry(context);
    return std.mem.order(u8, left, right);
}

fn deinitWithReentry(context: *CollationReentryContext) void {
    if (context.phase == .context_deinit) attemptCollationReentry(context);
}

test "collation comparator and destructor isolate every owner reentry guard" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    _ = try exec(&connection, "CREATE TABLE collation_reentry_values(id INTEGER PRIMARY KEY)");

    inline for (std.enums.values(CollationReentryPhase)) |phase| {
        inline for (std.enums.values(CollationReentryOperation)) |operation| {
            var rejected = false;
            var native_last_insert_rowid: i64 = 0;
            var native_statement_changes: i64 = 0;
            var target: turso.Statement = undefined;
            try connection.registerCollation("zig_reentry", turso.Collation(CollationReentryContext){
                .context = .{
                    .connection = &connection,
                    .statement = &target,
                    .phase = phase,
                    .operation = operation,
                    .native_last_insert_rowid = &native_last_insert_rowid,
                    .native_statement_changes = &native_statement_changes,
                    .rejected = &rejected,
                },
                .compare = compareWithReentry,
                .deinit = deinitWithReentry,
            });
            target = try connection.prepareSingle("INSERT INTO collation_reentry_values DEFAULT VALUES");
            try std.testing.expectEqual(@as(u64, 1), try target.execute());
            native_last_insert_rowid = connection.lastInsertRowid();
            native_statement_changes = target.changes();
            try std.testing.expect(native_last_insert_rowid != 0);
            try std.testing.expect(native_statement_changes != 0);

            if (phase == .compare) {
                var statement = try connection.prepareSingle("SELECT 'a' = 'b' COLLATE zig_reentry");
                if (operation == .connection_latest_diagnostic) {
                    connection.diagnostic = try connection.allocator.dupe(u8, retained_connection_diagnostic);
                }
                if (operation == .statement_latest_diagnostic) {
                    target.diagnostic = try target.allocator.dupe(u8, retained_statement_diagnostic);
                }
                try std.testing.expectEqual(turso.Step.row, try statement.step());
                var neutralized = try statement.value(0);
                defer neutralized.deinit(std.testing.allocator);
                try std.testing.expectEqual(@as(i64, 1), neutralized.integer);
                try std.testing.expect(rejected);
                statement.deinit();
                target.deinit();
            } else {
                target.deinit();
                if (operation == .statement_latest_diagnostic) {
                    target.diagnostic = try target.allocator.dupe(u8, retained_statement_diagnostic);
                }
            }
            try connection.unregisterCollation("zig_reentry");
            if (target.diagnostic) |diagnostic| {
                target.allocator.free(diagnostic);
                target.diagnostic = null;
            }

            try std.testing.expect(rejected);
            try std.testing.expect(!connection.owner_state.callback_active);
            try connection.setBusyTimeoutMs(0);
        }
    }
}

test "collation table mutations wait for prepared and partially executed statements" {
    var database = try openDatabase(":memory:");
    defer database.deinit();
    try database.open();
    var connection = try database.connect();
    defer connection.deinit();
    var deinits: usize = 0;
    try connection.registerCollation("zig_stable", managedCollation(&deinits, false));
    var statement = try connection.prepareSingle("SELECT v FROM (SELECT 'b' v UNION ALL SELECT 'a') ORDER BY v COLLATE zig_stable");
    try std.testing.expectError(turso.Error.InvalidState, connection.registerCollation("zig_stable", managedCollation(&deinits, true)));
    try std.testing.expectError(turso.Error.InvalidState, connection.unregisterCollation("zig_stable"));
    try std.testing.expectEqual(turso.Step.row, try statement.step());
    try std.testing.expectError(turso.Error.InvalidState, connection.unregisterCollation("zig_stable"));
    statement.deinit();
    try connection.unregisterCollation("zig_stable");
    try std.testing.expectEqual(@as(usize, 1), deinits);
}
