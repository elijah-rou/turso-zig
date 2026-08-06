const std = @import("std");
const turso = @import("turso");

const EmptyContext = struct {};
const SumState = struct { total: i64 = 0 };

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();

    try managedCallbacks(allocator);
    try callerDrivenProgress(allocator);
}

fn managedCallbacks(allocator: std.mem.Allocator) !void {
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

    try connection.registerScalarFunction("twice", .{ .fixed = 1 }, true, turso.ScalarFunction(EmptyContext){
        .context = .{},
        .call = twice,
    });
    try connection.registerAggregateFunction("total", .{ .fixed = 1 }, turso.AggregateFunction(EmptyContext, SumState){
        .context = .{},
        .init = sumInit,
        .step = sumStep,
        .final = sumFinal,
    });
    try connection.registerCollation("reverse", turso.Collation(EmptyContext){
        .context = .{},
        .compare = reverseCompare,
    });

    var statement = try connection.prepareSingle(
        "WITH numbers(value) AS (VALUES (1), (2), (3)) SELECT twice(4), total(value), min(CAST(value AS TEXT) COLLATE reverse) FROM numbers",
    );
    defer statement.deinit();
    if (try statement.step() != .row) return error.ExpectedRow;
    var doubled = try statement.value(0);
    defer doubled.deinit(allocator);
    var total = try statement.value(1);
    defer total.deinit(allocator);
    if (doubled != .integer or doubled.integer != 8) return error.UnexpectedScalarResult;
    switch (total) {
        .integer => |value| if (value != 6) return error.UnexpectedAggregateResult,
        .real => |value| if (value != 6) return error.UnexpectedAggregateResult,
        else => return error.UnexpectedAggregateResult,
    }
    try statement.finalize();
}

fn twice(_: *EmptyContext, args: turso.CallbackArgs) turso.CallbackResult {
    if (args.values.len != 1 or args.values[0] != .integer) return .{ .managed_error = .{ .code = .invalid_args } };
    return .{ .integer = args.values[0].integer * 2 };
}

fn sumInit(_: *EmptyContext) ?SumState {
    return .{};
}

fn sumStep(_: *EmptyContext, state: *SumState, args: turso.CallbackArgs) turso.CallbackResult {
    if (args.values.len != 1 or args.values[0] != .integer) return .{ .managed_error = .{ .code = .invalid_args } };
    state.total += args.values[0].integer;
    return .null;
}

fn sumFinal(_: *EmptyContext, state: *SumState) turso.CallbackResult {
    return .{ .integer = state.total };
}

fn reverseCompare(_: *EmptyContext, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, right, left);
}

fn callerDrivenProgress(allocator: std.mem.Allocator) !void {
    var construction = try turso.Database.create(allocator, .{
        .path = ":memory:",
        .io_mode = .caller_driven,
        .vfs = "memory",
    });
    var database = switch (construction) {
        .success => |value| value,
        .failure => |*failure| {
            defer failure.deinit(allocator);
            return failure.category;
        },
    };
    defer database.deinit();
    if (try database.openProgress() != .ready) return error.DatabaseOpenNeedsUnavailableDriver;
    var connection = try database.connect();
    defer connection.deinit();
    var statement = try connection.prepareSingle("SELECT 1");
    defer statement.deinit();

    while (true) switch (try statement.stepProgress()) {
        .row => {},
        .done => break,
        .needs_io => try statement.runIo(),
    };
    while (true) switch (try statement.finalizeProgress()) {
        .done => break,
        .needs_io => try statement.runIo(),
    };
}
