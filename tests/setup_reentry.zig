const std = @import("std");
const turso = @import("turso");

var callback_count: std.atomic.Value(usize) = .init(0);
var invalid_state_count: std.atomic.Value(usize) = .init(0);
var unexpected_result: std.atomic.Value(bool) = .init(false);

fn logger(log: turso.Log) void {
    if (log.level != .debug) return;
    _ = callback_count.fetchAdd(1, .monotonic);

    var result = turso.setup(std.heap.page_allocator, .{ .logger = logger }) catch {
        unexpected_result.store(true, .monotonic);
        return;
    };
    switch (result) {
        .success => unexpected_result.store(true, .monotonic),
        .failure => |*failure| {
            defer failure.deinit(std.heap.page_allocator);
            if (failure.category == turso.Error.InvalidState) {
                _ = invalid_state_count.fetchAdd(1, .monotonic);
            } else {
                unexpected_result.store(true, .monotonic);
            }
        },
    }
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    try expectSetupSuccess(allocator, try turso.setup(allocator, .{
        .log_level = "debug",
        .logger = logger,
    }));
    try prepareOnce(allocator);

    const callbacks = callback_count.load(.monotonic);
    if (callbacks == 0) return error.LoggerWasNotInvoked;
    if (invalid_state_count.load(.monotonic) != callbacks) return error.SetupReentryWasNotRejected;
    if (unexpected_result.load(.monotonic)) return error.UnexpectedSetupReentryResult;
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
