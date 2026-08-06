const std = @import("std");
const c = @import("c_api.zig").raw;
const errors = @import("error.zig");

pub const Connection = struct {
    allocator: std.mem.Allocator,
    handle: ?*c.turso_connection_t,
    database_active_connections: *usize,
    diagnostic: ?[]u8 = null,
    active_statements: usize = 0,
    closed: bool = false,

    pub fn latestDiagnostic(self: *const Connection) ?[]const u8 {
        return self.diagnostic;
    }

    pub fn close(self: *Connection) errors.Error!void {
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        const handle = self.handle orelse return errors.Error.InvalidState;
        if (self.closed) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "connection is already closed");
            return errors.Error.InvalidState;
        }
        if (self.active_statements != 0) {
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
        std.debug.assert(self.active_statements == 0);
        std.debug.assert(self.database_active_connections.* > 0);

        c.turso_connection_deinit(handle);
        self.handle = null;
        self.database_active_connections.* -= 1;
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        self.closed = true;
    }
};
