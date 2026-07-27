const std = @import("std");
const c = @import("c_api.zig").raw;
const callback_value = @import("callback_value.zig");
const ownership = @import("ownership.zig");

/// Bounds simultaneously live per-group states retained by one registration.
pub const max_states_per_registration: usize = 4096;

pub fn AggregateBox(comptime Context: type, comptime State: type) type {
    return struct {
        allocator: std.mem.Allocator,
        owner_state: *ownership.ConnectionState,
        function: callback_value.AggregateFunction(Context, State),
        states: [max_states_per_registration]?*StateBox(State) = @splat(null),
        init_failure: callback_value.ExtensionResultCode = .invalid_args,
    };
}

fn StateBox(comptime State: type) type {
    return struct {
        abi: c.turso_agg_ctx_t,
        state: State,
        active: bool,
        finalized: bool,
    };
}

pub fn initTrampoline(comptime Context: type, comptime State: type) c.turso_aggregate_init_function_t {
    return struct {
        fn call(opaque_context: usize) callconv(.c) [*c]c.turso_agg_ctx_t {
            if (opaque_context == 0) return null;
            const Box = AggregateBox(Context, State);
            const box: *Box = @ptrFromInt(opaque_context);
            if (box.owner_state.callback_active) {
                box.init_failure = .invalid_args;
                return null;
            }

            const previous = box.owner_state.enterCallback();
            defer _ = box.owner_state.leaveCallback(previous);
            var state = box.function.init(&box.function.context) orelse {
                box.init_failure = .invalid_args;
                return null;
            };
            if (box.owner_state.callback_violation) {
                deinitTemporary(Context, State, box, &state);
                box.init_failure = .invalid_args;
                return null;
            }

            const state_box = box.allocator.create(StateBox(State)) catch {
                deinitTemporary(Context, State, box, &state);
                box.init_failure = .out_of_memory;
                return null;
            };
            state_box.* = .{
                .abi = .{ .state = @ptrCast(box) },
                .state = state,
                .active = true,
                .finalized = false,
            };
            for (&box.states) |*slot| {
                if (slot.* == null) {
                    slot.* = state_box;
                    box.init_failure = .invalid_args;
                    return &state_box.abi;
                }
            }

            deinitState(Context, State, box, state_box);
            box.allocator.destroy(state_box);
            box.init_failure = .out_of_range;
            return null;
        }
    }.call;
}

pub fn stepTrampoline(comptime Context: type, comptime State: type) c.turso_aggregate_step_function_t {
    return struct {
        fn call(
            opaque_context: usize,
            aggregate_context: [*c]c.turso_agg_ctx_t,
            argc: c_int,
            argv: [*c]const c.turso_value_t,
        ) callconv(.c) c.turso_value_t {
            const box = validBox(Context, State, opaque_context) orelse
                return callback_value.encodeBoundaryFailure(.invalid_args);
            const state_box = findState(Context, State, box, aggregate_context) orelse
                return callback_value.encodeBoundaryFailure(if (aggregate_context == null) box.init_failure else .invalid_args);
            if (!state_box.active or state_box.finalized or box.owner_state.callback_active)
                return callback_value.encodeBoundaryFailure(.invalid_args);

            const previous = box.owner_state.enterCallback();
            defer _ = box.owner_state.leaveCallback(previous);
            var storage: [callback_value.max_callback_args]callback_value.BorrowedCallbackValue = undefined;
            const args = callback_value.decodeArgs(argc, argv, &storage) catch |err| {
                return callback_value.encodeBoundaryFailure(switch (err) {
                    error.OversizeValue => .out_of_range,
                    else => .invalid_args,
                });
            };
            const result = box.function.step(&box.function.context, &state_box.state, args);
            if (box.owner_state.callback_violation) return reentryFailure(box.allocator);
            return callback_value.encodeResult(box.allocator, result);
        }
    }.call;
}

pub fn finalTrampoline(comptime Context: type, comptime State: type) c.turso_aggregate_final_function_t {
    return struct {
        fn call(
            opaque_context: usize,
            aggregate_context: [*c]c.turso_agg_ctx_t,
        ) callconv(.c) c.turso_value_t {
            const box = validBox(Context, State, opaque_context) orelse
                return callback_value.encodeBoundaryFailure(.invalid_args);
            const state_box = findState(Context, State, box, aggregate_context) orelse
                return callback_value.encodeBoundaryFailure(if (aggregate_context == null) box.init_failure else .invalid_args);
            if (!state_box.active or state_box.finalized or box.owner_state.callback_active)
                return callback_value.encodeBoundaryFailure(.invalid_args);

            state_box.finalized = true;
            const previous = box.owner_state.enterCallback();
            defer _ = box.owner_state.leaveCallback(previous);
            const result = box.function.final(&box.function.context, &state_box.state);
            if (box.owner_state.callback_violation) return reentryFailure(box.allocator);
            return callback_value.encodeResult(box.allocator, result);
        }
    }.call;
}

pub fn stateDestructor(comptime Context: type, comptime State: type) c.turso_context_destructor_t {
    return struct {
        fn destroy(opaque_state: usize) callconv(.c) void {
            if (opaque_state == 0) return;
            const aggregate_context: *c.turso_agg_ctx_t = @ptrFromInt(opaque_state);
            const opaque_registration = aggregate_context.state orelse return;
            const Box = AggregateBox(Context, State);
            const box: *Box = @ptrCast(@alignCast(opaque_registration));
            for (&box.states) |*slot| {
                const state_box = slot.* orelse continue;
                if (@intFromPtr(&state_box.abi) != @intFromPtr(aggregate_context)) continue;
                if (!state_box.active) return;

                const previous = box.owner_state.enterCallback();
                deinitState(Context, State, box, state_box);
                _ = box.owner_state.leaveCallback(previous);
                slot.* = null;
                box.allocator.destroy(state_box);
                return;
            }
        }
    }.destroy;
}

pub fn contextDestructor(comptime Context: type, comptime State: type) c.turso_context_destructor_t {
    return struct {
        fn destroy(opaque_context: usize) callconv(.c) void {
            if (opaque_context == 0) return;
            const Box = AggregateBox(Context, State);
            const box: *Box = @ptrFromInt(opaque_context);
            const allocator = box.allocator;
            const previous = box.owner_state.enterCallback();
            for (&box.states) |*slot| {
                const state_box = slot.* orelse continue;
                if (state_box.active) deinitState(Context, State, box, state_box);
                allocator.destroy(state_box);
                slot.* = null;
            }
            if (box.function.context_deinit) |deinit_function| deinit_function(&box.function.context);
            _ = box.owner_state.leaveCallback(previous);
            allocator.destroy(box);
        }
    }.destroy;
}

fn validBox(comptime Context: type, comptime State: type, opaque_context: usize) ?*AggregateBox(Context, State) {
    if (opaque_context == 0) return null;
    return @ptrFromInt(opaque_context);
}

fn findState(
    comptime Context: type,
    comptime State: type,
    box: *AggregateBox(Context, State),
    aggregate_context: [*c]c.turso_agg_ctx_t,
) ?*StateBox(State) {
    if (aggregate_context == null) return null;
    const address = @intFromPtr(aggregate_context);
    for (box.states) |slot| {
        const state_box = slot orelse continue;
        if (@intFromPtr(&state_box.abi) == address) return state_box;
    }
    return null;
}

fn deinitTemporary(
    comptime Context: type,
    comptime State: type,
    box: *AggregateBox(Context, State),
    state: *State,
) void {
    if (box.function.state_deinit) |deinit_function| deinit_function(&box.function.context, state);
}

fn deinitState(
    comptime Context: type,
    comptime State: type,
    box: *AggregateBox(Context, State),
    state_box: *StateBox(State),
) void {
    if (!state_box.active) return;
    if (box.function.state_deinit) |deinit_function| deinit_function(&box.function.context, &state_box.state);
    state_box.active = false;
}

fn reentryFailure(allocator: std.mem.Allocator) c.turso_value_t {
    return callback_value.encodeResult(allocator, .{ .managed_error = .{
        .code = .invalid_args,
        .message = "aggregate callback re-entry is not allowed",
    } });
}

test "aggregate trampolines destroy state once and reject repeated callbacks" {
    const Counts = struct {
        state_deinits: usize = 0,
        context_deinits: usize = 0,
        fn init(_: *@This()) ?u64 {
            return 0;
        }
        fn step(_: *@This(), state: *u64, args: callback_value.CallbackArgs) callback_value.CallbackResult {
            state.* += args.values.len;
            return .null;
        }
        fn final(_: *@This(), state: *u64) callback_value.CallbackResult {
            return .{ .integer = @intCast(state.*) };
        }
        fn stateDeinit(context: *@This(), _: *u64) void {
            context.state_deinits += 1;
        }
        fn contextDeinit(context: *@This()) void {
            context.context_deinits += 1;
        }
    };
    var owner_state: ownership.ConnectionState = .{};
    const Box = AggregateBox(Counts, u64);
    const box = try std.testing.allocator.create(Box);
    box.* = .{
        .allocator = std.testing.allocator,
        .owner_state = &owner_state,
        .function = .{
            .context = .{},
            .init = Counts.init,
            .step = Counts.step,
            .final = Counts.final,
            .state_deinit = Counts.stateDeinit,
            .context_deinit = Counts.contextDeinit,
        },
    };

    const aggregate_context = initTrampoline(Counts, u64).?(@intFromPtr(box));
    try std.testing.expect(aggregate_context != null);
    var step_result = stepTrampoline(Counts, u64).?(@intFromPtr(box), aggregate_context, 0, null);
    callback_value.destroyResult(&step_result);
    var final_result = finalTrampoline(Counts, u64).?(@intFromPtr(box), aggregate_context);
    try std.testing.expectEqual(@as(i64, 0), final_result.value.int_value);
    callback_value.destroyResult(&final_result);
    var repeated_final = finalTrampoline(Counts, u64).?(@intFromPtr(box), aggregate_context);
    try std.testing.expectEqual(@as(c_uint, c.TURSO_EXTENSION_RESULT_INVALID_ARGS), repeated_final.value.@"error".*.code);
    callback_value.destroyResult(&repeated_final);

    stateDestructor(Counts, u64).?(@intFromPtr(aggregate_context));
    try std.testing.expectEqual(@as(usize, 1), box.function.context.state_deinits);
    var stale_step = stepTrampoline(Counts, u64).?(@intFromPtr(box), aggregate_context, 0, null);
    try std.testing.expectEqual(@as(c_uint, c.TURSO_EXTENSION_RESULT_INVALID_ARGS), stale_step.value.@"error".*.code);
    callback_value.destroyResult(&stale_step);
    contextDestructor(Counts, u64).?(@intFromPtr(box));
}

test "aggregate context destructor reclaims source-proven reset abandonment" {
    const Counts = struct {
        state_deinits: *usize,
        context_deinits: *usize,
        fn init(_: *@This()) ?u8 {
            return 1;
        }
        fn step(_: *@This(), _: *u8, _: callback_value.CallbackArgs) callback_value.CallbackResult {
            return .null;
        }
        fn final(_: *@This(), state: *u8) callback_value.CallbackResult {
            return .{ .integer = state.* };
        }
        fn stateDeinit(context: *@This(), _: *u8) void {
            context.state_deinits.* += 1;
        }
        fn contextDeinit(context: *@This()) void {
            context.context_deinits.* += 1;
        }
    };
    var state_deinits: usize = 0;
    var context_deinits: usize = 0;
    var owner_state: ownership.ConnectionState = .{};
    const Box = AggregateBox(Counts, u8);
    const box = try std.testing.allocator.create(Box);
    box.* = .{
        .allocator = std.testing.allocator,
        .owner_state = &owner_state,
        .function = .{
            .context = .{ .state_deinits = &state_deinits, .context_deinits = &context_deinits },
            .init = Counts.init,
            .step = Counts.step,
            .final = Counts.final,
            .state_deinit = Counts.stateDeinit,
            .context_deinit = Counts.contextDeinit,
        },
    };
    try std.testing.expect(initTrampoline(Counts, u8).?(@intFromPtr(box)) != null);

    // Turso 0.7.1 ProgramState::reset replaces registers without invoking the
    // ExternalAggState destructor. Registration release occurs after programs
    // that can still hold the pointer are gone, so it is the safe reclaim point.
    contextDestructor(Counts, u8).?(@intFromPtr(box));
    try std.testing.expectEqual(@as(usize, 1), state_deinits);
    try std.testing.expectEqual(@as(usize, 1), context_deinits);
}

test "aggregate init null and allocation failure become managed errors" {
    const State = struct {
        deinits: *usize,
        return_null: bool,
        fn init(context: *@This()) ?u8 {
            if (context.return_null) return null;
            return 1;
        }
        fn step(_: *@This(), _: *u8, _: callback_value.CallbackArgs) callback_value.CallbackResult {
            return .null;
        }
        fn final(_: *@This(), state: *u8) callback_value.CallbackResult {
            return .{ .integer = state.* };
        }
        fn stateDeinit(context: *@This(), _: *u8) void {
            context.deinits.* += 1;
        }
    };
    var deinits: usize = 0;
    var owner_state: ownership.ConnectionState = .{};
    const Box = AggregateBox(State, u8);
    const box = try std.testing.allocator.create(Box);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    box.* = .{
        .allocator = failing.allocator(),
        .owner_state = &owner_state,
        .function = .{
            .context = .{ .deinits = &deinits, .return_null = false },
            .init = State.init,
            .step = State.step,
            .final = State.final,
            .state_deinit = State.stateDeinit,
        },
    };
    try std.testing.expect(initTrampoline(State, u8).?(@intFromPtr(box)) == null);
    try std.testing.expectEqual(@as(usize, 1), deinits);
    var oom = finalTrampoline(State, u8).?(@intFromPtr(box), null);
    try std.testing.expectEqual(@as(c_uint, c.TURSO_EXTENSION_RESULT_OOM), oom.value.@"error".*.code);
    callback_value.destroyResult(&oom);

    box.allocator = std.testing.allocator;
    box.function.context.return_null = true;
    try std.testing.expect(initTrampoline(State, u8).?(@intFromPtr(box)) == null);
    var invalid = finalTrampoline(State, u8).?(@intFromPtr(box), null);
    try std.testing.expectEqual(@as(c_uint, c.TURSO_EXTENSION_RESULT_INVALID_ARGS), invalid.value.@"error".*.code);
    callback_value.destroyResult(&invalid);
    contextDestructor(State, u8).?(@intFromPtr(box));
}
