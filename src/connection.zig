const std = @import("std");
const c = @import("c_api.zig").raw;
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
