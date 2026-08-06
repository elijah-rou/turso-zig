const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    const version = try turso.version();
    if (!turso.isAbiCompatibleVersion(version)) {
        std.debug.print("incompatible Turso runtime: expected 0.7.1, loaded {s}\n", .{version});
        return error.IncompatibleTursoVersion;
    }
    std.debug.print("Turso runtime {s}\n", .{version});

    var construction = try turso.Database.create(allocator, .{ .path = ":memory:" });
    var database = switch (construction) {
        .success => |value| value,
        .failure => |*failure| {
            defer failure.deinit(allocator);
            std.debug.print("database create failed ({s}): {s}\n", .{
                @errorName(failure.category),
                failure.diagnostic,
            });
            return failure.category;
        },
    };
    defer database.deinit();

    database.open() catch |err| {
        printDiagnostic("database open", err, database.latestDiagnostic());
        return err;
    };
    var connection = database.connect() catch |err| {
        printDiagnostic("database connect", err, database.latestDiagnostic());
        return err;
    };
    defer connection.deinit();

    try createSchema(&connection);
    try insertPerson(&connection, "Ada", 36);
    try insertPerson(&connection, "Linus", 55);
    try printPeople(allocator, &connection);

    connection.close() catch |err| {
        printDiagnostic("connection close", err, connection.latestDiagnostic());
        return err;
    };
}

fn createSchema(connection: *turso.Connection) !void {
    var statement = connection.prepareSingle(
        "CREATE TABLE people(name TEXT NOT NULL, age INTEGER NOT NULL)",
    ) catch |err| {
        printDiagnostic("prepare schema", err, connection.latestDiagnostic());
        return err;
    };
    defer statement.deinit();

    _ = statement.execute() catch |err| {
        printDiagnostic("create schema", err, statement.latestDiagnostic());
        return err;
    };
    statement.finalize() catch |err| {
        printDiagnostic("finalize schema", err, statement.latestDiagnostic());
        return err;
    };
}

fn insertPerson(connection: *turso.Connection, name: []const u8, age: i64) !void {
    var statement = connection.prepareSingle(
        "INSERT INTO people(name, age) VALUES (?1, ?2)",
    ) catch |err| {
        printDiagnostic("prepare insert", err, connection.latestDiagnostic());
        return err;
    };
    defer statement.deinit();

    try statement.bindText(1, name);
    try statement.bindInteger(2, age);
    _ = statement.execute() catch |err| {
        printDiagnostic("insert person", err, statement.latestDiagnostic());
        return err;
    };
    statement.finalize() catch |err| {
        printDiagnostic("finalize insert", err, statement.latestDiagnostic());
        return err;
    };
}

fn printPeople(allocator: std.mem.Allocator, connection: *turso.Connection) !void {
    var statement = connection.prepareSingle(
        "SELECT name, age FROM people ORDER BY age",
    ) catch |err| {
        printDiagnostic("prepare query", err, connection.latestDiagnostic());
        return err;
    };
    defer statement.deinit();

    while (true) {
        const result = statement.step() catch |err| {
            printDiagnostic("query people", err, statement.latestDiagnostic());
            return err;
        };
        if (result == .done) break;

        var name = try statement.value(0);
        defer name.deinit(allocator);
        var age = try statement.value(1);
        defer age.deinit(allocator);

        switch (name) {
            .text => |text| std.debug.print("person name={s}", .{text}),
            else => return error.UnexpectedNameType,
        }
        switch (age) {
            .integer => |integer| std.debug.print(" age={d}\n", .{integer}),
            else => return error.UnexpectedAgeType,
        }
    }

    statement.finalize() catch |err| {
        printDiagnostic("finalize query", err, statement.latestDiagnostic());
        return err;
    };
}

fn printDiagnostic(operation: []const u8, err: anyerror, diagnostic: ?[]const u8) void {
    if (diagnostic) |message| {
        std.debug.print("{s} failed ({s}): {s}\n", .{ operation, @errorName(err), message });
    } else {
        std.debug.print("{s} failed ({s})\n", .{ operation, @errorName(err) });
    }
}
