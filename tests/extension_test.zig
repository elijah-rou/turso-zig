const std = @import("std");
const turso = @import("turso");
const fixture = @import("extension_fixture");

fn openConnection() !struct { database: turso.Database, connection: turso.Connection } {
    var result = try turso.Database.create(std.heap.page_allocator, .{ .path = ":memory:" });
    var database = switch (result) {
        .success => |value| value,
        .failure => |*failure| {
            defer failure.deinit(std.heap.page_allocator);
            std.debug.print("database construction failed: {s}\n", .{failure.diagnostic});
            return failure.category;
        },
    };
    errdefer database.deinit();
    try database.open();
    const connection = try database.connect();
    return .{ .database = database, .connection = connection };
}

fn expectInteger(connection: *turso.Connection, sql: []const u8, expected: i64) !void {
    var statement = try connection.prepareSingle(sql);
    defer statement.deinit();
    try std.testing.expectEqual(turso.Step.row, try statement.step());
    var value = try statement.value(0);
    defer value.deinit(std.heap.page_allocator);
    try std.testing.expectEqual(expected, value.integer);
}

pub fn main() !void {
    if (comptime @import("builtin").os.tag != .linux) @compileError("extension integration is Linux-only");
    if (!std.fs.path.isAbsolute(fixture.path)) return error.ExtensionFixturePathMustBeAbsolute;

    var direct = try openConnection();
    defer direct.database.deinit();
    defer direct.connection.deinit();
    try direct.connection.loadExtensionUnsafe(fixture.path);
    try expectInteger(&direct.connection, "SELECT regexp_like('abc123', '[0-9]+')", 1);

    var sql = try openConnection();
    defer sql.database.deinit();
    defer sql.connection.deinit();
    try sql.connection.setSqlExtensionLoadingEnabled(true);
    var load = try sql.connection.prepareSingle("SELECT load_extension(?1)");
    defer load.deinit();
    try load.bindText(1, fixture.path);
    try std.testing.expectEqual(turso.Step.row, try load.step());
    try expectInteger(&sql.connection, "SELECT regexp_like('zig', '^z')", 1);
}
