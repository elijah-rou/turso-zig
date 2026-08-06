const std = @import("std");
const turso = @import("turso");

var first_count: std.atomic.Value(usize) = .init(0);
var second_count: std.atomic.Value(usize) = .init(0);

fn firstLogger(log: turso.Log) void {
    if (log.level == .debug) _ = first_count.fetchAdd(1, .monotonic);
}

fn secondLogger(log: turso.Log) void {
    if (log.level == .debug) _ = second_count.fetchAdd(1, .monotonic);
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    var level = [_]u8{ 'd', 'e', 'b', 'u', 'g' };
    try expectSetupSuccess(allocator, try turso.setup(allocator, .{
        .log_level = &level,
        .logger = firstLogger,
    }));
    @memset(&level, 'x');
    try prepareOnce(allocator, "SELECT 1");
    try expect(first_count.load(.monotonic) != 0);

    const first_before_replacement = first_count.load(.monotonic);
    try expectSetupSuccess(allocator, try turso.setup(allocator, .{
        .log_level = "trace",
        .logger = secondLogger,
    }));
    try prepareOnce(allocator, "SELECT 2");
    try expect(first_count.load(.monotonic) == first_before_replacement);
    try expect(second_count.load(.monotonic) != 0);
}

fn expectSetupSuccess(allocator: std.mem.Allocator, result: turso.SetupResult) !void {
    var mutable_result = result;
    switch (mutable_result) {
        .success => {},
        .failure => |*failure| {
            defer failure.deinit(allocator);
            std.debug.print("setup failed ({s}): {s}\n", .{ @errorName(failure.category), failure.diagnostic });
            return failure.category;
        },
    }
}

fn prepareOnce(allocator: std.mem.Allocator, sql: []const u8) !void {
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
    var statement = try connection.prepareSingle(sql);
    defer statement.deinit();
}

fn expect(condition: bool) !void {
    if (!condition) return error.TestExpectationFailed;
}
