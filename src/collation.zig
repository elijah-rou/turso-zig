const std = @import("std");
const c = @import("c_api.zig").raw;
const ownership = @import("ownership.zig");

/// A managed collation owns its context after successful registration. Input
/// slices are UTF-8, borrowed for one comparison, and must not escape it.
/// Callbacks and deinitializers must not panic or re-enter the owning connection
/// or any statement created by it.
pub fn Collation(comptime Context: type) type {
    return struct {
        context: Context,
        compare: *const fn (context: *Context, left: []const u8, right: []const u8) std.math.Order,
        deinit: ?*const fn (context: *Context) void = null,
    };
}

pub fn Box(comptime Context: type) type {
    return struct {
        allocator: std.mem.Allocator,
        owner_state: *ownership.ConnectionState,
        collation: Collation(Context),
    };
}

pub fn compareTrampoline(comptime Context: type) c.turso_collation_function_t {
    return struct {
        fn compare(
            opaque_context: usize,
            left_pointer: [*c]const u8,
            left_length: usize,
            right_pointer: [*c]const u8,
            right_length: usize,
        ) callconv(.c) c_int {
            if (opaque_context == 0) return 0;
            const box: *Box(Context) = @ptrFromInt(opaque_context);
            if (box.owner_state.callback_active) {
                box.owner_state.recordCallbackViolation();
                return 0;
            }
            const left = borrowedText(left_pointer, left_length) orelse return 0;
            const right = borrowedText(right_pointer, right_length) orelse return 0;

            const previous = box.owner_state.enterCallback();
            defer _ = box.owner_state.leaveCallback(previous);
            const order = box.collation.compare(&box.collation.context, left, right);
            if (box.owner_state.callback_violation) return 0;
            return switch (order) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
        }
    }.compare;
}

pub fn contextDestructor(comptime Context: type) c.turso_context_destructor_t {
    return struct {
        fn destroy(opaque_context: usize) callconv(.c) void {
            if (opaque_context == 0) return;
            const box: *Box(Context) = @ptrFromInt(opaque_context);
            const allocator = box.allocator;
            if (box.owner_state.active_statements != 0) {
                box.owner_state.recordCallbackViolation();
            }
            const previous = box.owner_state.enterCallback();
            if (box.collation.deinit) |deinit_function| deinit_function(&box.collation.context);
            _ = box.owner_state.leaveCallback(previous);
            allocator.destroy(box);
        }
    }.destroy;
}

fn borrowedText(pointer: [*c]const u8, length: usize) ?[]const u8 {
    if (length == 0) return "";
    if (pointer == null) return null;
    if (length > std.math.maxInt(isize)) return null;
    const bytes: [*]const u8 = @ptrCast(pointer);
    const text = bytes[0..length];
    if (!std.unicode.utf8ValidateSlice(text)) return null;
    return text;
}

test "nested collation callback activity records a violation" {
    const Context = struct {
        fn compare(_: *@This(), _: []const u8, _: []const u8) std.math.Order {
            return .eq;
        }
    };
    var owner_state: ownership.ConnectionState = .{ .callback_active = true };
    const box = try std.testing.allocator.create(Box(Context));
    defer std.testing.allocator.destroy(box);
    box.* = .{
        .allocator = std.testing.allocator,
        .owner_state = &owner_state,
        .collation = .{ .context = .{}, .compare = Context.compare },
    };

    const compare = compareTrampoline(Context).?;
    try std.testing.expectEqual(@as(c_int, 0), compare(@intFromPtr(box), "a", 1, "b", 1));
    try std.testing.expect(owner_state.callback_violation);
}

test "collation context destruction records non-quiescent native retirement" {
    const Context = struct {
        deinits: *usize,
        fn compare(_: *@This(), _: []const u8, _: []const u8) std.math.Order {
            return .eq;
        }
        fn deinit(context: *@This()) void {
            context.deinits.* += 1;
        }
    };
    var owner_state: ownership.ConnectionState = .{ .active_statements = 1 };
    var deinits: usize = 0;
    const box = try std.testing.allocator.create(Box(Context));
    box.* = .{
        .allocator = std.testing.allocator,
        .owner_state = &owner_state,
        .collation = .{
            .context = .{ .deinits = &deinits },
            .compare = Context.compare,
            .deinit = Context.deinit,
        },
    };

    contextDestructor(Context).?(@intFromPtr(box));
    try std.testing.expectEqual(@as(usize, 1), deinits);
    try std.testing.expect(owner_state.callback_violation);
}

test "collation boundary validates borrowed text and maps ordering exactly" {
    const Context = struct {
        calls: usize = 0,
        fn compare(context: *@This(), left: []const u8, right: []const u8) std.math.Order {
            context.calls += 1;
            return std.mem.order(u8, left, right);
        }
    };
    var owner_state: ownership.ConnectionState = .{};
    const box = try std.testing.allocator.create(Box(Context));
    box.* = .{
        .allocator = std.testing.allocator,
        .owner_state = &owner_state,
        .collation = .{ .context = .{}, .compare = Context.compare },
    };
    defer contextDestructor(Context).?(@intFromPtr(box));
    const compare = compareTrampoline(Context).?;

    try std.testing.expectEqual(@as(c_int, -1), compare(@intFromPtr(box), "a", 1, "b", 1));
    try std.testing.expectEqual(@as(c_int, 0), compare(@intFromPtr(box), null, 0, "", 0));
    try std.testing.expectEqual(@as(c_int, 1), compare(@intFromPtr(box), "é", 2, "z", 1));
    try std.testing.expectEqual(@as(c_int, 0), compare(@intFromPtr(box), null, 1, "a", 1));
    try std.testing.expectEqual(@as(c_int, 0), compare(@intFromPtr(box), "\xff", 1, "a", 1));
    try std.testing.expectEqual(@as(usize, 3), box.collation.context.calls);
}
