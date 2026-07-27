const std = @import("std");
const c = @import("c_api.zig").raw;
const errors = @import("error.zig");
const ownership = @import("ownership.zig");
const progress = @import("io_progress.zig");
const Value = @import("value.zig").Value;

pub const Step = enum { row, done };

const ProgressOperation = enum { execute, step, finalize };
const ProgressPhase = enum { awaiting_io, retry_required };
const ProgressRejection = enum { awaiting_io, wrong_operation };
const RunIoRejection = enum { no_pending_operation, retry_required };

const NativeProgressStatus = enum { io, completed };

const ProgressState = struct {
    pending_operation: ?ProgressOperation = null,
    pending_phase: ProgressPhase = .awaiting_io,

    fn callRejection(self: ProgressState, operation: ProgressOperation) ?ProgressRejection {
        const pending_operation = self.pending_operation orelse return null;
        if (pending_operation != operation) return .wrong_operation;
        return switch (self.pending_phase) {
            .awaiting_io => .awaiting_io,
            .retry_required => null,
        };
    }

    fn runIoRejection(self: ProgressState) ?RunIoRejection {
        if (self.pending_operation == null) return .no_pending_operation;
        if (self.pending_phase == .retry_required) return .retry_required;
        return null;
    }

    fn recordIoRequired(self: *ProgressState, operation: ProgressOperation) void {
        if (self.pending_operation) |pending_operation| std.debug.assert(pending_operation == operation);
        self.pending_operation = operation;
        self.pending_phase = .awaiting_io;
    }

    fn recordIoCompleted(self: *ProgressState) void {
        std.debug.assert(self.pending_operation != null);
        std.debug.assert(self.pending_phase == .awaiting_io);
        self.pending_phase = .retry_required;
    }

    fn recordOperationCompleted(self: *ProgressState, operation: ProgressOperation) void {
        if (self.pending_operation) |pending_operation| std.debug.assert(pending_operation == operation);
        self.pending_operation = null;
        self.pending_phase = .awaiting_io;
    }

    fn recordRunIoStatus(self: *ProgressState, succeeded: bool) void {
        if (succeeded) self.recordIoCompleted();
    }

    fn isQuiescent(self: ProgressState) bool {
        return self.pending_operation == null;
    }
};

const ProgressRecord = struct {
    registration: ownership.StatementProgressRecord,
    state: ProgressState = .{},
};

pub fn init(
    allocator: std.mem.Allocator,
    handle: *c.turso_statement_t,
    connection_owner_state: *ownership.ConnectionState,
    io_mode: progress.IoMode,
) errors.Error!Statement {
    const record = try createProgressRecord(allocator, handle);
    connection_owner_state.addStatementProgressRecord(&record.registration);
    return .{
        .allocator = allocator,
        .handle = handle,
        .connection_owner_state = connection_owner_state,
        .io_mode = io_mode,
    };
}

pub const ColumnKind = enum {
    none,
    builtin,
    custom,
    domain,
    structure,
    union_type,
};

pub const Statement = struct {
    allocator: std.mem.Allocator,
    handle: ?*c.turso_statement_t,
    connection_owner_state: *ownership.ConnectionState,
    io_mode: progress.IoMode,
    diagnostic: ?[]u8 = null,
    row_available: bool = false,
    finalized: bool = false,

    pub fn latestDiagnostic(self: *const Statement) ?[]const u8 {
        if (self.connection_owner_state.callback_active) {
            self.connection_owner_state.recordCallbackViolation();
            return self.diagnostic;
        }
        std.debug.assert(self.handle != null);
        return self.diagnostic;
    }

    pub fn bindNull(self: *Statement, position: usize) errors.Error!void {
        const handle = try self.beginMutation();
        try finishBind(c.turso_statement_bind_positional_null(handle, try self.checkedParameterPosition(position)));
    }

    pub fn bindInteger(self: *Statement, position: usize, input: i64) errors.Error!void {
        const handle = try self.beginMutation();
        try finishBind(c.turso_statement_bind_positional_int(handle, try self.checkedParameterPosition(position), input));
    }

    pub fn bindReal(self: *Statement, position: usize, input: f64) errors.Error!void {
        const handle = try self.beginMutation();
        try finishBind(c.turso_statement_bind_positional_double(handle, try self.checkedParameterPosition(position), input));
    }

    pub fn bindText(self: *Statement, position: usize, input: []const u8) errors.Error!void {
        const handle = try self.beginMutation();
        const pointer: [*c]const u8 = if (input.len == 0) null else input.ptr;
        try finishBind(c.turso_statement_bind_positional_text(
            handle,
            try self.checkedParameterPosition(position),
            pointer,
            input.len,
        ));
    }

    pub fn bindBlob(self: *Statement, position: usize, input: []const u8) errors.Error!void {
        const handle = try self.beginMutation();
        const pointer: [*c]const u8 = if (input.len == 0) null else input.ptr;
        try finishBind(c.turso_statement_bind_positional_blob(
            handle,
            try self.checkedParameterPosition(position),
            pointer,
            input.len,
        ));
    }

    pub fn execute(self: *Statement) errors.Error!u64 {
        const handle = try self.beginSynchronousOperation();
        var changes_count: u64 = 0;
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_statement_execute(handle, &changes_count, &error_opt_out);
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        try errors.finishExpected(
            self.allocator,
            status,
            c.TURSO_DONE,
            error_opt_out,
            &self.diagnostic,
        );
        return changes_count;
    }

    pub fn step(self: *Statement) errors.Error!Step {
        const handle = try self.beginSynchronousOperation();
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_statement_step(handle, &error_opt_out);
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        const copied = try errors.copyAndFreeDiagnostic(self.allocator, error_opt_out);
        switch (status) {
            c.TURSO_ROW => {
                try errors.rejectUnexpectedDiagnostic(self.allocator, copied);
                self.row_available = true;
                return .row;
            },
            c.TURSO_DONE => {
                try errors.rejectUnexpectedDiagnostic(self.allocator, copied);
                return .done;
            },
            else => {
                self.diagnostic = copied;
                return errors.statusToError(status);
            },
        }
    }

    pub fn executeProgress(self: *Statement) errors.Error!progress.ExecuteProgress {
        const handle = try self.beginProgressOperation(.execute);
        var changes_count: u64 = 0;
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_statement_execute(handle, &changes_count, &error_opt_out);
        switch (status) {
            c.TURSO_DONE => try self.finishProgressSuccess(.execute, error_opt_out),
            c.TURSO_IO => try self.finishProgressIo(.execute, error_opt_out),
            else => return self.finishProgressError(.execute, status, error_opt_out),
        }
        return executeProgressResult(status, changes_count);
    }

    pub fn stepProgress(self: *Statement) errors.Error!progress.StepProgress {
        const handle = try self.beginProgressOperation(.step);
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_statement_step(handle, &error_opt_out);
        return switch (status) {
            c.TURSO_ROW => value: {
                try self.finishProgressSuccess(.step, error_opt_out);
                self.row_available = true;
                break :value .row;
            },
            c.TURSO_DONE => value: {
                try self.finishProgressSuccess(.step, error_opt_out);
                break :value .done;
            },
            c.TURSO_IO => value: {
                try self.finishProgressIo(.step, error_opt_out);
                break :value .needs_io;
            },
            else => self.finishProgressError(.step, status, error_opt_out),
        };
    }

    pub fn runIo(self: *Statement) errors.Error!void {
        try self.rejectCallbackReentry();
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        self.row_available = false;
        const handle = self.handle orelse {
            std.debug.assert(false);
            return errors.Error.InvalidState;
        };
        if (self.io_mode != .caller_driven) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "runIo requires caller-driven I/O mode");
            return errors.Error.InvalidState;
        }
        if (self.progressState().runIoRejection()) |rejection| {
            const message = switch (rejection) {
                .no_pending_operation => "runIo requires a pending statement operation",
                .retry_required => "pending operation must be retried before running more I/O",
            };
            try errors.setDiagnostic(self.allocator, &self.diagnostic, message);
            return errors.Error.InvalidState;
        }

        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_statement_run_io(handle, &error_opt_out);
        self.progressState().recordRunIoStatus(status == c.TURSO_OK);
        const copied = try errors.copyAndFreeDiagnostic(self.allocator, error_opt_out);
        if (status == c.TURSO_OK) return errors.rejectUnexpectedDiagnostic(self.allocator, copied);
        self.diagnostic = copied;
        return errors.statusToError(status);
    }

    pub fn reset(self: *Statement) errors.Error!void {
        const handle = try self.beginMutationAllowFinalized();
        if (!self.progressState().isQuiescent()) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "pending statement operation must be completed before reset");
            return errors.Error.InvalidState;
        }
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_statement_reset(handle, &error_opt_out);
        recordResetStatus(self.progressState(), &self.finalized, status);
        try errors.finishExpected(self.allocator, status, c.TURSO_OK, error_opt_out, &self.diagnostic);
    }

    pub fn finalize(self: *Statement) errors.Error!void {
        const handle = try self.beginSynchronousOperation();
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_statement_finalize(handle, &error_opt_out);
        if (status == c.TURSO_DONE) self.finalized = true;
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        try errors.finishExpected(self.allocator, status, c.TURSO_DONE, error_opt_out, &self.diagnostic);
    }

    pub fn finalizeProgress(self: *Statement) errors.Error!progress.FinalizeProgress {
        const handle = try self.beginProgressOperation(.finalize);
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_statement_finalize(handle, &error_opt_out);
        recordFinalizeNativeStatus(self.progressState(), &self.finalized, status);
        return switch (status) {
            c.TURSO_DONE => value: {
                try self.finishProgressDiagnostic(error_opt_out);
                break :value .done;
            },
            c.TURSO_IO => value: {
                try self.finishProgressDiagnostic(error_opt_out);
                break :value .needs_io;
            },
            else => self.finishProgressError(.finalize, status, error_opt_out),
        };
    }

    pub fn changes(self: *const Statement) i64 {
        if (self.connection_owner_state.callback_active) {
            self.connection_owner_state.recordCallbackViolation();
            return 0;
        }
        const handle = self.handle orelse {
            std.debug.assert(false);
            return 0;
        };
        return c.turso_statement_n_change(handle);
    }

    pub fn parameterCount(self: *const Statement) errors.Error!usize {
        const handle = try self.validHandle();
        const count = c.turso_statement_parameters_count(handle);
        if (count < 0) return errors.Error.InvalidHandle;
        return std.math.cast(usize, count) orelse errors.Error.InvalidArgument;
    }

    pub fn parameterName(self: *const Statement, position: usize) errors.Error!?[]u8 {
        const handle = try self.validHandle();
        const count = try self.parameterCount();
        if (position == 0 or position > count) return errors.Error.InvalidIndex;
        const signed_position = std.math.cast(i64, position) orelse return errors.Error.InvalidIndex;
        const pointer = c.turso_statement_parameter_name(handle, signed_position);
        return try copyOptionalTursoString(self.allocator, pointer);
    }

    pub fn namedPosition(self: *const Statement, name: []const u8) errors.Error!?usize {
        const handle = try self.validHandle();
        if (std.mem.indexOfScalar(u8, name, 0) != null) return errors.Error.InvalidArgument;
        const name_z = self.allocator.dupeZ(u8, name) catch return errors.Error.OutOfMemory;
        defer self.allocator.free(name_z);
        const position = c.turso_statement_named_position(handle, name_z.ptr);
        if (position == -1) return null;
        if (position <= 0) return errors.Error.InvalidIndex;
        return std.math.cast(usize, position) orelse errors.Error.InvalidIndex;
    }

    pub fn columnCount(self: *const Statement) errors.Error!usize {
        const handle = try self.validHandle();
        const count = c.turso_statement_column_count(handle);
        if (count < 0) return errors.Error.InvalidHandle;
        return std.math.cast(usize, count) orelse errors.Error.InvalidArgument;
    }

    pub fn columnName(self: *const Statement, index: usize) errors.Error![]u8 {
        const handle = try self.checkedColumnHandle(index);
        const pointer = c.turso_statement_column_name(handle, index);
        return (try copyOptionalTursoString(self.allocator, pointer)) orelse errors.Error.InvalidHandle;
    }

    pub fn columnDeclaredType(self: *const Statement, index: usize) errors.Error!?[]u8 {
        const handle = try self.checkedColumnHandle(index);
        return try copyOptionalTursoString(self.allocator, c.turso_statement_column_decltype(handle, index));
    }

    pub fn columnDeclaredName(self: *const Statement, index: usize) errors.Error!?[]u8 {
        const handle = try self.checkedColumnHandle(index);
        return try copyOptionalTursoString(self.allocator, c.turso_statement_column_declared_name(handle, index));
    }

    pub fn columnArrayDimensions(self: *const Statement, index: usize) errors.Error!u32 {
        const handle = try self.checkedColumnHandle(index);
        return c.turso_statement_column_array_dimensions(handle, index);
    }

    pub fn columnBaseType(self: *const Statement, index: usize) errors.Error!?[]u8 {
        const handle = try self.checkedColumnHandle(index);
        return try copyOptionalTursoString(self.allocator, c.turso_statement_column_base_type(handle, index));
    }

    pub fn columnKind(self: *const Statement, index: usize) errors.Error!ColumnKind {
        const handle = try self.checkedColumnHandle(index);
        return switch (c.turso_statement_column_kind(handle, index)) {
            c.TURSO_COLUMN_KIND_NONE => .none,
            c.TURSO_COLUMN_KIND_BUILTIN => .builtin,
            c.TURSO_COLUMN_KIND_CUSTOM => .custom,
            c.TURSO_COLUMN_KIND_DOMAIN => .domain,
            c.TURSO_COLUMN_KIND_STRUCT => .structure,
            c.TURSO_COLUMN_KIND_UNION => .union_type,
            else => errors.Error.UnknownColumnKind,
        };
    }

    pub fn value(self: *const Statement, index: usize) errors.Error!Value {
        const handle = try self.checkedColumnHandle(index);
        if (!self.row_available) return errors.Error.InvalidState;
        return switch (c.turso_statement_row_value_kind(handle, index)) {
            c.TURSO_TYPE_NULL => .null,
            c.TURSO_TYPE_INTEGER => .{ .integer = c.turso_statement_row_value_int(handle, index) },
            c.TURSO_TYPE_REAL => .{ .real = c.turso_statement_row_value_double(handle, index) },
            c.TURSO_TYPE_TEXT => .{ .text = try self.copyRowBytes(handle, index) },
            c.TURSO_TYPE_BLOB => .{ .blob = try self.copyRowBytes(handle, index) },
            c.TURSO_TYPE_UNKNOWN => errors.Error.UnknownValueKind,
            else => errors.Error.UnknownValueKind,
        };
    }

    pub fn deinit(self: *Statement) void {
        if (self.connection_owner_state.callback_active) {
            self.connection_owner_state.recordCallbackViolation();
            return;
        }
        const handle = self.handle orelse {
            std.debug.assert(false);
            return;
        };
        std.debug.assert(self.connection_owner_state.active_statements > 0);
        if (self.io_mode == .caller_driven) std.debug.assert(self.progressState().isQuiescent());
        c.turso_statement_deinit(handle);
        const registration = self.connection_owner_state.removeStatementProgressRecord(@intFromPtr(handle));
        const record: *ProgressRecord = @fieldParentPtr("registration", registration);
        self.allocator.destroy(record);
        self.handle = null;
        if (self.connection_owner_state.active_statements == 0) {
            self.connection_owner_state.reclaimAggregateStates();
        }
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        self.row_available = false;
        self.finalized = true;
    }

    fn progressState(self: *const Statement) *ProgressState {
        const handle = self.handle orelse {
            std.debug.assert(false);
            unreachable;
        };
        const registration = self.connection_owner_state.findStatementProgressRecord(@intFromPtr(handle)) orelse {
            std.debug.assert(false);
            unreachable;
        };
        const record: *ProgressRecord = @fieldParentPtr("registration", registration);
        return &record.state;
    }

    fn validHandle(self: *const Statement) errors.Error!*c.turso_statement_t {
        try self.rejectCallbackReentry();
        return self.handle orelse {
            std.debug.assert(false);
            return errors.Error.InvalidState;
        };
    }

    fn checkedColumnHandle(self: *const Statement, index: usize) errors.Error!*c.turso_statement_t {
        const handle = try self.validHandle();
        if (index >= try self.columnCount()) return errors.Error.InvalidIndex;
        return handle;
    }

    fn checkedParameterPosition(self: *const Statement, position: usize) errors.Error!usize {
        if (position == 0 or position > try self.parameterCount()) return errors.Error.InvalidIndex;
        return position;
    }

    fn beginSynchronousOperation(self: *Statement) errors.Error!*c.turso_statement_t {
        const handle = try self.beginMutation();
        if (self.io_mode == .caller_driven) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "synchronous statement methods are unavailable in caller-driven I/O mode");
            return errors.Error.InvalidState;
        }
        return handle;
    }

    fn beginProgressOperation(self: *Statement, operation: ProgressOperation) errors.Error!*c.turso_statement_t {
        try self.rejectCallbackReentry();
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        self.row_available = false;
        const handle = self.handle orelse {
            std.debug.assert(false);
            return errors.Error.InvalidState;
        };
        if (self.finalized) return errors.Error.InvalidState;
        if (self.io_mode != .caller_driven) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "progress methods require caller-driven I/O mode");
            return errors.Error.InvalidState;
        }
        if (self.progressState().callRejection(operation)) |rejection| {
            const message = switch (rejection) {
                .awaiting_io => "pending statement operation requires runIo before retry",
                .wrong_operation => "pending statement operation requires retry of the same operation",
            };
            try errors.setDiagnostic(self.allocator, &self.diagnostic, message);
            return errors.Error.InvalidState;
        }
        return handle;
    }

    fn finishProgressSuccess(self: *Statement, operation: ProgressOperation, error_opt_out: [*c]const u8) errors.Error!void {
        recordNativeProgressStatus(self.progressState(), &self.finalized, operation, .completed);
        const copied = try errors.copyAndFreeDiagnostic(self.allocator, error_opt_out);
        try errors.rejectUnexpectedDiagnostic(self.allocator, copied);
    }

    fn finishProgressIo(self: *Statement, operation: ProgressOperation, error_opt_out: [*c]const u8) errors.Error!void {
        recordNativeProgressStatus(self.progressState(), &self.finalized, operation, .io);
        try self.finishProgressDiagnostic(error_opt_out);
    }

    fn finishProgressDiagnostic(self: *Statement, error_opt_out: [*c]const u8) errors.Error!void {
        const copied = try errors.copyAndFreeDiagnostic(self.allocator, error_opt_out);
        try errors.rejectUnexpectedDiagnostic(self.allocator, copied);
    }

    fn finishProgressError(self: *Statement, operation: ProgressOperation, status: c.turso_status_code_t, error_opt_out: [*c]const u8) errors.Error {
        if (operation != .finalize) recordNativeProgressStatus(self.progressState(), &self.finalized, operation, .completed);
        const copied = errors.copyAndFreeDiagnostic(self.allocator, error_opt_out) catch return errors.Error.OutOfMemory;
        self.diagnostic = copied;
        return errors.statusToError(status);
    }

    fn beginMutation(self: *Statement) errors.Error!*c.turso_statement_t {
        try self.rejectCallbackReentry();
        if (self.handle == null) {
            std.debug.assert(false);
            return errors.Error.InvalidState;
        }
        if (self.finalized) return errors.Error.InvalidState;
        if (!self.progressState().isQuiescent()) {
            errors.clearDiagnostic(self.allocator, &self.diagnostic);
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "pending statement operation must be completed");
            return errors.Error.InvalidState;
        }
        return self.beginMutationAllowFinalized();
    }

    fn beginMutationAllowFinalized(self: *Statement) errors.Error!*c.turso_statement_t {
        try self.rejectCallbackReentry();
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        self.row_available = false;
        return self.handle orelse {
            std.debug.assert(false);
            return errors.Error.InvalidState;
        };
    }

    fn rejectCallbackReentry(self: *const Statement) errors.Error!void {
        if (!self.connection_owner_state.callback_active) return;
        self.connection_owner_state.recordCallbackViolation();
        const mutable: *Statement = @constCast(self);
        errors.clearDiagnostic(self.allocator, &mutable.diagnostic);
        try errors.setDiagnostic(self.allocator, &mutable.diagnostic, "managed callback re-entry is not allowed");
        return errors.Error.InvalidState;
    }

    fn copyRowBytes(self: *const Statement, handle: *c.turso_statement_t, index: usize) errors.Error![]u8 {
        const signed_count = c.turso_statement_row_value_bytes_count(handle, index);
        if (signed_count < 0) return errors.Error.InvalidValue;
        const count = std.math.cast(usize, signed_count) orelse return errors.Error.InvalidValue;
        const pointer = c.turso_statement_row_value_bytes_ptr(handle, index);
        if (pointer == null) {
            if (count != 0) return errors.Error.InvalidValue;
            return self.allocator.dupe(u8, &.{}) catch errors.Error.OutOfMemory;
        }
        const bytes: [*]const u8 = @ptrCast(pointer);
        return self.allocator.dupe(u8, bytes[0..count]) catch errors.Error.OutOfMemory;
    }
};

fn createProgressRecord(allocator: std.mem.Allocator, handle: *c.turso_statement_t) errors.Error!*ProgressRecord {
    const record = allocator.create(ProgressRecord) catch return errors.Error.OutOfMemory;
    record.* = .{ .registration = .{ .native_handle_key = @intFromPtr(handle) } };
    return record;
}

fn recordNativeProgressStatus(
    state: *ProgressState,
    finalized: *bool,
    operation: ProgressOperation,
    status: NativeProgressStatus,
) void {
    switch (status) {
        .io => state.recordIoRequired(operation),
        .completed => {
            state.recordOperationCompleted(operation);
            if (operation == .finalize) finalized.* = true;
        },
    }
}

fn recordFinalizeNativeStatus(state: *ProgressState, finalized: *bool, status: c.turso_status_code_t) void {
    switch (status) {
        c.TURSO_DONE => recordNativeProgressStatus(state, finalized, .finalize, .completed),
        c.TURSO_IO => recordNativeProgressStatus(state, finalized, .finalize, .io),
        else => {},
    }
}

fn recordResetStatus(state: *ProgressState, finalized: *bool, status: c.turso_status_code_t) void {
    if (status != c.TURSO_OK) return;
    std.debug.assert(state.isQuiescent());
    state.* = .{};
    finalized.* = false;
}

fn executeProgressResult(status: c.turso_status_code_t, changes_count: u64) progress.ExecuteProgress {
    return switch (status) {
        c.TURSO_DONE => .{ .done = changes_count },
        c.TURSO_IO => .needs_io,
        else => unreachable,
    };
}

fn failDiagnosticForTest(failure: errors.Error) errors.Error!void {
    return failure;
}

test "caller-driven operation state records native status before diagnostic errors" {
    var state: ProgressState = .{};
    var finalized = false;

    recordNativeProgressStatus(&state, &finalized, .execute, .io);
    try std.testing.expectError(errors.Error.OutOfMemory, failDiagnosticForTest(errors.Error.OutOfMemory));
    try std.testing.expectEqual(ProgressRejection.awaiting_io, state.callRejection(.execute).?);
    try std.testing.expectEqual(ProgressRejection.wrong_operation, state.callRejection(.step).?);

    state.recordRunIoStatus(false);
    try std.testing.expectEqual(ProgressRejection.awaiting_io, state.callRejection(.execute).?);
    state.recordRunIoStatus(true);
    try std.testing.expect(state.callRejection(.execute) == null);
    try std.testing.expectEqual(ProgressRejection.wrong_operation, state.callRejection(.finalize).?);

    recordNativeProgressStatus(&state, &finalized, .execute, .completed);
    try std.testing.expect(state.isQuiescent());
    recordFinalizeNativeStatus(&state, &finalized, c.TURSO_DONE);
    try std.testing.expectError(errors.Error.UnexpectedDiagnostic, failDiagnosticForTest(errors.Error.UnexpectedDiagnostic));
    try std.testing.expect(finalized);
    try std.testing.expect(state.isQuiescent());
}

test "finalize progress changes completion state only for native DONE" {
    var state: ProgressState = .{};
    var finalized = false;

    recordFinalizeNativeStatus(&state, &finalized, c.TURSO_ERROR);
    try std.testing.expect(!finalized);
    try std.testing.expect(state.isQuiescent());
    try std.testing.expect(state.callRejection(.finalize) == null);

    recordFinalizeNativeStatus(&state, &finalized, c.TURSO_IO);
    try std.testing.expect(!finalized);
    try std.testing.expectEqual(ProgressRejection.awaiting_io, state.callRejection(.finalize).?);
    state.recordRunIoStatus(true);

    recordFinalizeNativeStatus(&state, &finalized, c.TURSO_ERROR);
    try std.testing.expect(!finalized);
    try std.testing.expect(state.callRejection(.finalize) == null);
    try std.testing.expect(!state.isQuiescent());

    recordFinalizeNativeStatus(&state, &finalized, c.TURSO_OK);
    try std.testing.expectError(errors.Error.UnexpectedDiagnostic, failDiagnosticForTest(errors.Error.UnexpectedDiagnostic));
    try std.testing.expect(!finalized);
    try std.testing.expect(!state.isQuiescent());

    recordFinalizeNativeStatus(&state, &finalized, c.TURSO_DONE);
    try std.testing.expect(finalized);
    try std.testing.expect(state.isQuiescent());
}

test "statement progress sidecar registration is exact and allocation failure is bounded" {
    var owner_state: ownership.ConnectionState = .{};
    const fake_handle: *c.turso_statement_t = @ptrFromInt(@alignOf(*c.turso_statement_t));
    var full_owner_state: ownership.ConnectionState = .{ .active_statements = ownership.max_active_statements };
    try std.testing.expect(!full_owner_state.canRegisterStatement());

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(errors.Error.OutOfMemory, createProgressRecord(failing_allocator.allocator(), fake_handle));
    try std.testing.expectEqual(@as(usize, 0), owner_state.active_statements);
    try std.testing.expect(owner_state.findStatementProgressRecord(@intFromPtr(fake_handle)) == null);

    const record = try createProgressRecord(std.testing.allocator, fake_handle);
    owner_state.addStatementProgressRecord(&record.registration);
    try std.testing.expectEqual(@as(usize, 1), owner_state.active_statements);
    try std.testing.expect(owner_state.findStatementProgressRecord(@intFromPtr(fake_handle)) == &record.registration);
    const removed = owner_state.removeStatementProgressRecord(@intFromPtr(fake_handle));
    try std.testing.expect(removed == &record.registration);
    try std.testing.expectEqual(@as(usize, 0), owner_state.active_statements);
    try std.testing.expect(owner_state.statement_progress_records == null);
    std.testing.allocator.destroy(record);
}

test "reset changes wrapper state only after native success" {
    var state: ProgressState = .{};
    var finalized = true;
    recordResetStatus(&state, &finalized, c.TURSO_IOERR);
    try std.testing.expect(finalized);
    recordResetStatus(&state, &finalized, c.TURSO_OK);
    try std.testing.expect(!finalized);
    try std.testing.expect(state.isQuiescent());
}

test "execute progress exposes changes only on native completion" {
    const done = executeProgressResult(c.TURSO_DONE, 17);
    try std.testing.expectEqual(@as(u64, 17), done.done);
    const needs_io = executeProgressResult(c.TURSO_IO, 99);
    try std.testing.expect(needs_io == .needs_io);
}

test "caller-driven state rejects repeated runIo and pending native drain" {
    var state: ProgressState = .{};
    try std.testing.expect(state.isQuiescent());
    state.recordIoRequired(.step);
    try std.testing.expect(!state.isQuiescent());
    state.recordRunIoStatus(true);
    try std.testing.expectEqual(ProgressPhase.retry_required, state.pending_phase);
    try std.testing.expectEqual(RunIoRejection.retry_required, state.runIoRejection().?);
    try std.testing.expectEqual(ProgressRejection.wrong_operation, state.callRejection(.execute).?);
    try std.testing.expect(!state.isQuiescent());
    state.recordOperationCompleted(.step);
    try std.testing.expect(state.isQuiescent());
}

fn finishBind(status: c.turso_status_code_t) errors.Error!void {
    if (status == c.TURSO_OK) return;
    return errors.statusToError(status);
}

fn copyOptionalTursoString(
    allocator: std.mem.Allocator,
    pointer: [*c]const u8,
) errors.Error!?[]u8 {
    if (pointer == null) return null;
    defer c.turso_str_deinit(pointer);
    return allocator.dupe(u8, std.mem.span(pointer)) catch errors.Error.OutOfMemory;
}
