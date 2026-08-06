const std = @import("std");
const c = @import("c_api.zig").raw;
const errors = @import("error.zig");
const ownership = @import("ownership.zig");
const Value = @import("value.zig").Value;

pub const Step = enum { row, done };

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
        const handle = try self.beginMutation();
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
        const handle = try self.beginMutation();
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

    pub fn reset(self: *Statement) errors.Error!void {
        const handle = try self.beginMutationAllowFinalized();
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_statement_reset(handle, &error_opt_out);
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        try errors.finishExpected(self.allocator, status, c.TURSO_OK, error_opt_out, &self.diagnostic);
        self.finalized = false;
    }

    pub fn finalize(self: *Statement) errors.Error!void {
        const handle = try self.beginMutation();
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_statement_finalize(handle, &error_opt_out);
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        try errors.finishExpected(self.allocator, status, c.TURSO_DONE, error_opt_out, &self.diagnostic);
        self.finalized = true;
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
        c.turso_statement_deinit(handle);
        self.handle = null;
        self.connection_owner_state.active_statements -= 1;
        if (self.connection_owner_state.active_statements == 0) {
            self.connection_owner_state.reclaimAggregateStates();
        }
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        self.row_available = false;
        self.finalized = true;
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

    fn beginMutation(self: *Statement) errors.Error!*c.turso_statement_t {
        try self.rejectCallbackReentry();
        if (self.handle == null) {
            std.debug.assert(false);
            return errors.Error.InvalidState;
        }
        if (self.finalized) return errors.Error.InvalidState;
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
