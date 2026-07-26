const std = @import("std");
const turso = @import("turso");

var debug_count: std.atomic.Value(usize) = .init(0);

fn logger(log: turso.Log) void {
    if (log.level == .debug) _ = debug_count.fetchAdd(1, .monotonic);
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    try expectSetupSuccess(allocator, try turso.setup(allocator, .{
        .log_level = "error",
        .logger = logger,
    }));
    try expectSetupSuccess(allocator, try turso.setup(allocator, .{
        .log_level = "trace",
        .logger = logger,
    }));
    try prepareOnce(allocator);
    if (debug_count.load(.monotonic) != 0) return error.FirstSuccessfulLevelWasReplaced;
}

fn expectSetupSuccess(allocator: std.mem.Allocator, result: turso.SetupResult) !void {
    var mutable_result = result;
    switch (mutable_result) {
        .success => {},
        .failure => |*failure| {
            defer failure.deinit(allocator);
            return failure.category;
        },
    }
}

fn prepareOnce(allocator: std.mem.Allocator) !void {
    var construction = try turso.Database.create(allocator, .{ .path = ":memory:" });
    var database = switch (construction) {
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
    var statement = try connection.prepareSingle("SELECT 1");
    defer statement.deinit();
}
