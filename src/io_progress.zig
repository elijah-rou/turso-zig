const std = @import("std");

pub const IoMode = enum {
    library_driven,
    caller_driven,
};

pub const OpenProgress = enum {
    ready,
    needs_io_without_driver,
};

pub const StepProgress = enum {
    row,
    done,
    needs_io,
};

pub const ExecuteProgress = union(enum) {
    done: u64,
    needs_io,
};

pub const FinalizeProgress = enum {
    done,
    needs_io,
};

pub const Operation = enum {
    execute,
    step,
    finalize,
};

pub const Pending = struct {
    operation: Operation,
    phase: enum { awaiting_io, retry_required },
};

pub const CallRejection = enum {
    awaiting_io,
    wrong_operation,
};

pub const State = struct {
    pending: ?Pending = null,

    pub fn callRejection(self: State, operation: Operation) ?CallRejection {
        const pending = self.pending orelse return null;
        if (pending.operation != operation) return .wrong_operation;
        return switch (pending.phase) {
            .awaiting_io => .awaiting_io,
            .retry_required => null,
        };
    }

    pub fn canCall(self: State, operation: Operation) bool {
        return self.callRejection(operation) == null;
    }

    pub fn needsIo(self: *State, operation: Operation) void {
        if (self.pending) |pending| std.debug.assert(pending.operation == operation);
        self.pending = .{ .operation = operation, .phase = .awaiting_io };
    }

    pub fn ioCompleted(self: *State) void {
        std.debug.assert(self.pending != null);
        std.debug.assert(self.pending.?.phase == .awaiting_io);
        self.pending.?.phase = .retry_required;
    }

    pub fn operationCompleted(self: *State, operation: Operation) void {
        if (self.pending) |pending| std.debug.assert(pending.operation == operation);
        self.pending = null;
    }

    pub fn abort(self: *State) void {
        self.pending = null;
    }
};

test "pending operation transition table requires IO then same-operation retry" {
    var state: State = .{};
    const cases = [_]Operation{ .execute, .step, .finalize };
    for (cases) |operation| {
        try std.testing.expect(state.canCall(operation));
        state.needsIo(operation);
        try std.testing.expectEqual(CallRejection.awaiting_io, state.callRejection(operation).?);
        inline for (cases) |other| {
            if (other != operation) try std.testing.expectEqual(CallRejection.wrong_operation, state.callRejection(other).?);
        }
        state.ioCompleted();
        try std.testing.expect(state.canCall(operation));
        inline for (cases) |other| {
            if (other != operation) try std.testing.expectEqual(CallRejection.wrong_operation, state.callRejection(other).?);
        }
        state.operationCompleted(operation);
        try std.testing.expect(state.pending == null);
    }
}

test "abort clears awaiting and retry-required pending states" {
    var state: State = .{};
    state.needsIo(.step);
    state.abort();
    try std.testing.expect(state.pending == null);
    state.needsIo(.finalize);
    state.ioCompleted();
    state.abort();
    try std.testing.expect(state.pending == null);
}
