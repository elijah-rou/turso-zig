const std = @import("std");
const c = @import("c_api.zig").raw;
const callback_value = @import("callback_value.zig");
const ownership = @import("ownership.zig");

/// Bounds live and abandoned per-group states retained by one registration.
pub const max_states_per_registration: usize = 4096;

pub fn AggregateBox(comptime Context: type, comptime State: type) type {
    return struct {
        allocator: std.mem.Allocator,
        owner_state: *ownership.ConnectionState,
        registration: ownership.AggregateRegistration = .{
            .reclaim_states = reclaimStates(Context, State),
        },
        function: callback_value.AggregateFunction(Context, State),
        states: [max_states_per_registration]?*StateBox(State) = @splat(null),
        init_failure: callback_value.ExtensionResultCode = .invalid_args,
    };
}

pub fn StateBox(comptime State: type) type {
    return struct {
        abi: c.turso_agg_ctx_t,
        state: State,
    };
}

pub fn initTrampoline(comptime Context: type, comptime State: type) c.turso_aggregate_init_function_t {
    return struct {
        fn call(opaque_context: usize) callconv(.c) [*c]c.turso_agg_ctx_t {
            const box = validBox(Context, State, opaque_context) orelse return null;
            if (box.owner_state.callback_active) {
                box.init_failure = .invalid_args;
                return null;
            }

            var available_slot: ?*?*StateBox(State) = null;
            for (&box.states) |*slot| {
                if (slot.* == null) {
                    available_slot = slot;
                    break;
                }
            }
            const slot = available_slot orelse {
                box.init_failure = .out_of_range;
                return null;
            };

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
            };
            std.debug.assert(slot.* == null);
            slot.* = state_box;
            box.init_failure = .invalid_args;
            return &state_box.abi;
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
            if (box.owner_state.callback_active)
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
            if (box.owner_state.callback_active)
                return callback_value.encodeBoundaryFailure(.invalid_args);

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
            // Turso 0.7.1 also calls this destructor for intermediate window
            // values and can reuse the same state afterward. Keep the state alive
            // until the final owning statement is deinitialized.
            _ = findState(Context, State, box, aggregate_context) orelse return;
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
            const owner_state = box.owner_state;
            std.debug.assert(owner_state.active_statements == 0);

            owner_state.reclaimAggregateStates();
            owner_state.removeAggregateRegistration(&box.registration);
            const previous = owner_state.enterCallback();
            if (box.function.context_deinit) |deinit_function| deinit_function(&box.function.context);
            _ = owner_state.leaveCallback(previous);
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
    if (box.function.state_deinit) |deinit_function| deinit_function(&box.function.context, &state_box.state);
}

fn reclaimStates(comptime Context: type, comptime State: type) *const fn (*ownership.AggregateRegistration) void {
    return struct {
        fn reclaim(registration: *ownership.AggregateRegistration) void {
            const Box = AggregateBox(Context, State);
            const box: *Box = @fieldParentPtr("registration", registration);
            std.debug.assert(box.owner_state.active_statements == 0);
            const previous = box.owner_state.enterCallback();
            for (&box.states) |*slot| {
                const state_box = slot.* orelse continue;
                deinitState(Context, State, box, state_box);
                box.allocator.destroy(state_box);
                slot.* = null;
            }
            _ = box.owner_state.leaveCallback(previous);
        }
    }.reclaim;
}

fn reentryFailure(allocator: std.mem.Allocator) c.turso_value_t {
    return callback_value.encodeResult(allocator, .{ .managed_error = .{
        .code = .invalid_args,
        .message = "aggregate callback re-entry is not allowed",
    } });
}

test "aggregate states survive repeated native release until statement quiescence" {
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
    var owner_state: ownership.ConnectionState = .{ .active_statements = 1 };
    const Box = AggregateBox(Counts, u64);
    const box = try std.testing.allocator.create(Box);
    box.* = .{ .allocator = std.testing.allocator, .owner_state = &owner_state, .function = .{
        .context = .{},
        .init = Counts.init,
        .step = Counts.step,
        .final = Counts.final,
        .state_deinit = Counts.stateDeinit,
        .context_deinit = Counts.contextDeinit,
    } };
    owner_state.addAggregateRegistration(&box.registration);

    const aggregate_context = initTrampoline(Counts, u64).?(@intFromPtr(box));
    try std.testing.expect(aggregate_context != null);
    stateDestructor(Counts, u64).?(@intFromPtr(aggregate_context));
    stateDestructor(Counts, u64).?(@intFromPtr(aggregate_context));
    try std.testing.expectEqual(@as(usize, 0), box.function.context.state_deinits);
    var continued_step = stepTrampoline(Counts, u64).?(@intFromPtr(box), aggregate_context, 0, null);
    try std.testing.expectEqual(@as(c_uint, c.TURSO_EXTENSION_VALUE_NULL), continued_step.value_type);
    callback_value.destroyResult(&continued_step);
    var continued_final = finalTrampoline(Counts, u64).?(@intFromPtr(box), aggregate_context);
    try std.testing.expectEqual(@as(c_uint, c.TURSO_EXTENSION_VALUE_INTEGER), continued_final.value_type);
    callback_value.destroyResult(&continued_final);

    owner_state.active_statements = 0;
    owner_state.reclaimAggregateStates();
    try std.testing.expectEqual(@as(usize, 1), box.function.context.state_deinits);
    contextDestructor(Counts, u64).?(@intFromPtr(box));
    try std.testing.expectEqual(@as(usize, 0), owner_state.aggregate_registration_count);
}

test "aggregate retained-state boundary rejects 4097 before init or allocation" {
    const Counts = struct {
        inits: usize = 0,
        deinits: usize = 0,
        fn init(context: *@This()) ?u8 {
            context.inits += 1;
            return 1;
        }
        fn step(_: *@This(), _: *u8, _: callback_value.CallbackArgs) callback_value.CallbackResult {
            return .null;
        }
        fn final(_: *@This(), state: *u8) callback_value.CallbackResult {
            return .{ .integer = state.* };
        }
        fn deinit(context: *@This(), _: *u8) void {
            context.deinits += 1;
        }
    };
    var owner_state: ownership.ConnectionState = .{};
    const Box = AggregateBox(Counts, u8);
    const box = try std.testing.allocator.create(Box);
    box.* = .{ .allocator = std.testing.allocator, .owner_state = &owner_state, .function = .{
        .context = .{},
        .init = Counts.init,
        .step = Counts.step,
        .final = Counts.final,
        .state_deinit = Counts.deinit,
    } };
    owner_state.addAggregateRegistration(&box.registration);
    for (0..max_states_per_registration) |_| try std.testing.expect(initTrampoline(Counts, u8).?(@intFromPtr(box)) != null);
    try std.testing.expectEqual(max_states_per_registration, box.function.context.inits);
    try std.testing.expect(initTrampoline(Counts, u8).?(@intFromPtr(box)) == null);
    try std.testing.expectEqual(max_states_per_registration, box.function.context.inits);
    var overflow = finalTrampoline(Counts, u8).?(@intFromPtr(box), null);
    try std.testing.expectEqual(@as(c_uint, c.TURSO_EXTENSION_RESULT_OUT_OF_RANGE), overflow.value.@"error".*.code);
    callback_value.destroyResult(&overflow);
    owner_state.reclaimAggregateStates();
    contextDestructor(Counts, u8).?(@intFromPtr(box));
}
