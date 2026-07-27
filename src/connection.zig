const std = @import("std");
const c = @import("c_api.zig").raw;
const callback_value = @import("callback_value.zig");
const errors = @import("error.zig");
const ownership = @import("ownership.zig");
const Statement = @import("statement.zig").Statement;

pub const PrepareFirstResult = struct {
    statement: ?Statement,
    tail_offset: usize,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    handle: ?*c.turso_connection_t,
    database_owner_state: *ownership.DatabaseState,
    owner_state: *ownership.ConnectionState,
    diagnostic: ?[]u8 = null,
    closed: bool = false,

    pub fn latestDiagnostic(self: *const Connection) ?[]const u8 {
        std.debug.assert(self.handle != null);
        return self.diagnostic;
    }

    pub fn prepareSingle(self: *Connection, sql: []const u8) errors.Error!Statement {
        const handle = try self.beginOperation();
        const sql_z = try self.copySql(sql);
        defer self.allocator.free(sql_z);

        var statement_handle: ?*c.turso_statement_t = null;
        var tail_offset: usize = std.math.maxInt(usize);
        var error_opt_out: [*c]const u8 = null;
        // The 0.7.1 native prepare_single accepts and ignores trailing SQL. Use
        // prepare_first so the safe wrapper can enforce its single-statement contract.
        const status = c.turso_connection_prepare_first(
            handle,
            sql_z.ptr,
            &statement_handle,
            &tail_offset,
            &error_opt_out,
        );
        errdefer if (statement_handle) |unowned_handle| c.turso_statement_deinit(unowned_handle);
        try errors.finishOperation(self.allocator, status, error_opt_out, &self.diagnostic);
        if (statement_handle == null and tail_offset == std.math.maxInt(usize)) tail_offset = 0;
        if (tail_offset > sql.len) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "prepare tail offset exceeds SQL byte length");
            return errors.Error.InvalidValue;
        }
        if (std.mem.trim(u8, sql[tail_offset..], " \t\r\n").len != 0) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "prepareSingle received trailing SQL");
            return errors.Error.TrailingSql;
        }
        const valid_statement = statement_handle orelse {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "successful prepare returned a null statement");
            return errors.Error.InvalidHandle;
        };
        self.owner_state.active_statements += 1;
        return self.makeStatement(valid_statement);
    }

    pub fn prepareFirst(self: *Connection, sql: []const u8) errors.Error!PrepareFirstResult {
        const handle = try self.beginOperation();
        const sql_z = try self.copySql(sql);
        defer self.allocator.free(sql_z);

        var statement_handle: ?*c.turso_statement_t = null;
        var tail_offset: usize = std.math.maxInt(usize);
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_connection_prepare_first(
            handle,
            sql_z.ptr,
            &statement_handle,
            &tail_offset,
            &error_opt_out,
        );
        errdefer if (statement_handle) |unowned_handle| c.turso_statement_deinit(unowned_handle);
        try errors.finishOperation(self.allocator, status, error_opt_out, &self.diagnostic);
        if (statement_handle == null and tail_offset == std.math.maxInt(usize)) tail_offset = 0;
        if (tail_offset > sql.len) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "prepare tail offset exceeds SQL byte length");
            return errors.Error.InvalidValue;
        }
        const statement = if (statement_handle) |valid_statement| value: {
            self.owner_state.active_statements += 1;
            break :value self.makeStatement(valid_statement);
        } else null;
        return .{ .statement = statement, .tail_offset = tail_offset };
    }

    /// Registers or replaces a scalar callback. The callback and its deinitializer
    /// must not panic or call methods on this connection.
    pub fn registerScalarFunction(
        self: *Connection,
        name: []const u8,
        arity: callback_value.Arity,
        deterministic: bool,
        function: anytype,
    ) errors.Error!void {
        const Function = @TypeOf(function);
        const function_info = @typeInfo(Function);
        if (comptime function_info != .@"struct" or !@hasField(Function, "context") or
            !@hasField(Function, "call") or !@hasField(Function, "deinit"))
        {
            @compileError("function must be a turso.ScalarFunction(Context)");
        }
        const Context = @TypeOf(function.context);
        const Expected = callback_value.ScalarFunction(Context);
        if (comptime Function != Expected) {
            @compileError("function must be a turso.ScalarFunction(Context)");
        }

        const handle = try self.beginOperation();
        const native_arity: c_int = switch (arity) {
            .variadic => -1,
            .fixed => |count| if (count <= callback_value.max_callback_args)
                count
            else {
                try errors.setDiagnostic(self.allocator, &self.diagnostic, "scalar function arity exceeds 127 arguments");
                return errors.Error.InvalidArgument;
            },
        };
        try self.validateFunctionName(name);

        const name_z = self.allocator.dupeZ(u8, name) catch return errors.Error.OutOfMemory;
        defer self.allocator.free(name_z);
        const Box = ScalarBox(Context);
        const box = self.allocator.create(Box) catch return errors.Error.OutOfMemory;
        box.* = .{
            .allocator = self.allocator,
            .owner_state = self.owner_state,
            .function = function,
        };
        errdefer {
            if (box.function.deinit) |deinit_function| deinit_function(&box.function.context);
            self.allocator.destroy(box);
        }

        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_connection_register_scalar_function(
            handle,
            name_z.ptr,
            native_arity,
            deterministic,
            @intFromPtr(box),
            scalarTrampoline(Context),
            scalarContextDestructor(Context),
            callback_value.destroyResult,
            &error_opt_out,
        );
        try errors.finishOperation(self.allocator, status, error_opt_out, &self.diagnostic);
    }

    pub fn unregisterFunction(self: *Connection, name: []const u8) errors.Error!void {
        const handle = try self.beginOperation();
        try self.validateFunctionName(name);
        const name_z = self.allocator.dupeZ(u8, name) catch return errors.Error.OutOfMemory;
        defer self.allocator.free(name_z);

        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_connection_unregister_function(handle, name_z.ptr, &error_opt_out);
        try errors.finishOperation(self.allocator, status, error_opt_out, &self.diagnostic);
    }

    pub fn setBusyTimeoutMs(self: *Connection, timeout_ms: u64) errors.Error!void {
        const handle = try self.beginOperation();
        const signed_timeout = std.math.cast(i64, timeout_ms) orelse {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "busy timeout exceeds i64 milliseconds");
            return errors.Error.InvalidArgument;
        };
        c.turso_connection_set_busy_timeout_ms(handle, signed_timeout);
    }

    pub fn autocommit(self: *const Connection) bool {
        const handle = self.handle orelse {
            std.debug.assert(false);
            return false;
        };
        std.debug.assert(!self.closed);
        return c.turso_connection_get_autocommit(handle);
    }

    pub fn lastInsertRowid(self: *const Connection) i64 {
        const handle = self.handle orelse {
            std.debug.assert(false);
            return 0;
        };
        std.debug.assert(!self.closed);
        return c.turso_connection_last_insert_rowid(handle);
    }

    pub fn close(self: *Connection) errors.Error!void {
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        const handle = self.handle orelse {
            std.debug.assert(false);
            return errors.Error.InvalidState;
        };
        if (self.closed) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "connection is already closed");
            return errors.Error.InvalidState;
        }
        if (self.owner_state.active_statements != 0) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "connection still owns active statements");
            return errors.Error.InvalidState;
        }

        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_connection_close(handle, &error_opt_out);
        try errors.finishOperation(self.allocator, status, error_opt_out, &self.diagnostic);
        self.closed = true;
    }

    pub fn deinit(self: *Connection) void {
        const handle = self.handle orelse {
            std.debug.assert(false);
            return;
        };
        std.debug.assert(self.owner_state.active_statements == 0);
        std.debug.assert(self.database_owner_state.active_connections > 0);

        c.turso_connection_deinit(handle);
        self.handle = null;
        self.database_owner_state.active_connections -= 1;
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        self.allocator.destroy(self.owner_state);
        self.closed = true;
    }

    fn beginOperation(self: *Connection) errors.Error!*c.turso_connection_t {
        if (self.owner_state.callback_active) return errors.Error.InvalidState;
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        const handle = self.handle orelse {
            std.debug.assert(false);
            return errors.Error.InvalidState;
        };
        if (self.closed) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "connection is closed");
            return errors.Error.InvalidState;
        }
        return handle;
    }

    fn validateFunctionName(self: *Connection, name: []const u8) errors.Error!void {
        if (name.len == 0 or name.len > 255 or std.mem.indexOfScalar(u8, name, 0) != null or
            !std.unicode.utf8ValidateSlice(name))
        {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "scalar function name must be 1..255 UTF-8 bytes without NUL");
            return errors.Error.InvalidArgument;
        }
    }

    fn copySql(self: *Connection, sql: []const u8) errors.Error![:0]u8 {
        if (std.mem.indexOfScalar(u8, sql, 0) != null) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "SQL must not contain NUL bytes");
            return errors.Error.InvalidArgument;
        }
        return self.allocator.dupeZ(u8, sql) catch errors.Error.OutOfMemory;
    }

    fn makeStatement(self: *Connection, handle: *c.turso_statement_t) Statement {
        return .{
            .allocator = self.allocator,
            .handle = handle,
            .connection_owner_state = self.owner_state,
        };
    }
};

fn ScalarBox(comptime Context: type) type {
    return struct {
        allocator: std.mem.Allocator,
        owner_state: *ownership.ConnectionState,
        function: callback_value.ScalarFunction(Context),
    };
}

fn scalarTrampoline(comptime Context: type) c.turso_scalar_function_t {
    return struct {
        fn call(
            opaque_context: usize,
            argc: c_int,
            argv: [*c]const c.turso_value_t,
            _: c.turso_context_destructor_t,
            _: c.turso_value_destructor_t,
        ) callconv(.c) c.turso_value_t {
            if (opaque_context == 0) return callback_value.encodeBoundaryFailure(.invalid_args);
            const Box = ScalarBox(Context);
            const box: *Box = @ptrFromInt(opaque_context);
            if (box.owner_state.callback_active) return callback_value.encodeBoundaryFailure(.invalid_args);

            box.owner_state.callback_active = true;
            defer box.owner_state.callback_active = false;
            var storage: [callback_value.max_callback_args]callback_value.BorrowedCallbackValue = undefined;
            const args = callback_value.decodeArgs(argc, argv, &storage) catch |err| return switch (err) {
                error.OversizeValue => callback_value.encodeBoundaryFailure(.out_of_range),
                else => callback_value.encodeBoundaryFailure(.invalid_args),
            };
            const result = box.function.call(&box.function.context, args);
            return callback_value.encodeResult(box.allocator, result);
        }
    }.call;
}

fn scalarContextDestructor(comptime Context: type) c.turso_context_destructor_t {
    return struct {
        fn destroy(opaque_context: usize) callconv(.c) void {
            if (opaque_context == 0) return;
            const Box = ScalarBox(Context);
            const box: *Box = @ptrFromInt(opaque_context);
            if (box.owner_state.callback_active) return;
            box.owner_state.callback_active = true;
            if (box.function.deinit) |deinit_function| deinit_function(&box.function.context);
            box.owner_state.callback_active = false;
            const allocator = box.allocator;
            allocator.destroy(box);
        }
    }.destroy;
}
