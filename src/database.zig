const std = @import("std");
const c = @import("c_api.zig").raw;
const errors = @import("error.zig");
const ownership = @import("ownership.zig");
const Connection = @import("connection.zig").Connection;

pub const DatabaseConfig = struct {
    path: []const u8,
    experimental_features: ?[]const u8 = null,
    vfs: ?[]const u8 = null,
    encryption_cipher: ?[]const u8 = null,
    encryption_hexkey: ?[]const u8 = null,
};

pub const ConstructionFailure = struct {
    category: errors.Error,
    diagnostic: []u8,

    pub fn deinit(self: *ConstructionFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.diagnostic);
        self.diagnostic = &.{};
    }
};

pub const InitResult = union(enum) {
    success: Database,
    failure: ConstructionFailure,
};

pub const Database = struct {
    pub const Config = DatabaseConfig;
    pub const ConstructionResult = InitResult;

    allocator: std.mem.Allocator,
    handle: ?*const c.turso_database_t,
    stored_config: StoredConfig,
    diagnostic: ?[]u8 = null,
    owner_state: *ownership.DatabaseState,
    opened: bool = false,

    pub fn create(allocator: std.mem.Allocator, config: DatabaseConfig) std.mem.Allocator.Error!InitResult {
        if (!configStringsAreValid(config)) {
            return .{ .failure = .{
                .category = errors.Error.InvalidConfig,
                .diagnostic = try allocator.dupe(u8, "database config strings must not contain NUL bytes"),
            } };
        }

        var stored_config = try StoredConfig.init(allocator, config);
        errdefer stored_config.deinit(allocator);

        var c_config = std.mem.zeroes(c.turso_database_config_t);
        c_config.async_io = 0;
        c_config.path = stored_config.path.ptr;
        c_config.experimental_features = optionalPointer(stored_config.experimental_features);
        c_config.vfs = optionalPointer(stored_config.vfs);
        c_config.encryption_cipher = optionalPointer(stored_config.encryption_cipher);
        c_config.encryption_hexkey = optionalPointer(stored_config.encryption_hexkey);
        std.debug.assert(c_config.async_io == 0);
        std.debug.assert(c_config.path != null);

        var handle: ?*const c.turso_database_t = null;
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_database_new(&c_config, &handle, &error_opt_out);
        const copied = errors.copyAndFreeDiagnostic(allocator, error_opt_out) catch {
            if (handle) |created_handle| c.turso_database_deinit(created_handle);
            return error.OutOfMemory;
        };

        if (status != c.TURSO_OK) {
            if (handle) |unexpected_handle| c.turso_database_deinit(unexpected_handle);
            const category = errors.statusToError(status);
            const diagnostic = copied orelse try allocator.dupe(u8, @errorName(category));
            stored_config.deinit(allocator);
            return .{ .failure = .{ .category = category, .diagnostic = diagnostic } };
        }

        if (copied) |unexpected| {
            if (handle) |unexpected_handle| c.turso_database_deinit(unexpected_handle);
            stored_config.deinit(allocator);
            return .{ .failure = .{
                .category = errors.Error.UnexpectedDiagnostic,
                .diagnostic = unexpected,
            } };
        }
        const valid_handle = handle orelse {
            const diagnostic = try allocator.dupe(u8, "successful database construction returned a null handle");
            stored_config.deinit(allocator);
            return .{ .failure = .{
                .category = errors.Error.InvalidHandle,
                .diagnostic = diagnostic,
            } };
        };
        const owner_state = allocator.create(ownership.DatabaseState) catch {
            c.turso_database_deinit(valid_handle);
            return error.OutOfMemory;
        };
        owner_state.* = .{};

        return .{ .success = .{
            .allocator = allocator,
            .handle = valid_handle,
            .stored_config = stored_config,
            .owner_state = owner_state,
        } };
    }

    pub fn latestDiagnostic(self: *const Database) ?[]const u8 {
        std.debug.assert(self.handle != null);
        return self.diagnostic;
    }

    pub fn activeConnectionCount(self: *const Database) usize {
        const handle = self.handle orelse {
            std.debug.assert(false);
            return 0;
        };
        _ = handle;
        return self.owner_state.active_connections;
    }

    pub fn open(self: *Database) errors.Error!void {
        const handle = self.handle orelse {
            std.debug.assert(false);
            return errors.Error.InvalidState;
        };
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        if (self.opened) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "database is already open");
            return errors.Error.InvalidState;
        }

        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_database_open(handle, &error_opt_out);
        if (status == c.TURSO_OK) self.opened = true;
        try errors.finishOperation(self.allocator, status, error_opt_out, &self.diagnostic);
    }

    pub fn connect(self: *Database) errors.Error!Connection {
        const handle = self.handle orelse {
            std.debug.assert(false);
            return errors.Error.InvalidState;
        };
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        if (!self.opened) {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "database must be opened before connecting");
            return errors.Error.InvalidState;
        }

        var connection_handle: ?*c.turso_connection_t = null;
        var error_opt_out: [*c]const u8 = null;
        const status = c.turso_database_connect(handle, &connection_handle, &error_opt_out);
        errdefer if (connection_handle) |unowned_handle| c.turso_connection_deinit(unowned_handle);
        try errors.finishOperation(self.allocator, status, error_opt_out, &self.diagnostic);
        const valid_handle = connection_handle orelse {
            try errors.setDiagnostic(self.allocator, &self.diagnostic, "successful database connect returned a null handle");
            return errors.Error.InvalidHandle;
        };
        const owner_state = self.allocator.create(ownership.ConnectionState) catch return errors.Error.OutOfMemory;
        errdefer self.allocator.destroy(owner_state);
        owner_state.* = .{};

        self.owner_state.active_connections += 1;
        return .{
            .allocator = self.allocator,
            .handle = valid_handle,
            .database_owner_state = self.owner_state,
            .owner_state = owner_state,
        };
    }

    pub fn deinit(self: *Database) void {
        const handle = self.handle orelse {
            std.debug.assert(false);
            return;
        };
        std.debug.assert(self.owner_state.active_connections == 0);

        c.turso_database_deinit(handle);
        self.handle = null;
        errors.clearDiagnostic(self.allocator, &self.diagnostic);
        self.stored_config.deinit(self.allocator);
        self.allocator.destroy(self.owner_state);
        self.opened = false;
    }
};

const StoredConfig = struct {
    path: [:0]u8,
    experimental_features: ?[:0]u8,
    vfs: ?[:0]u8,
    encryption_cipher: ?[:0]u8,
    encryption_hexkey: ?[:0]u8,

    fn init(allocator: std.mem.Allocator, config: DatabaseConfig) std.mem.Allocator.Error!StoredConfig {
        const path = try allocator.dupeZ(u8, config.path);
        errdefer allocator.free(path);
        const experimental_features = try optionalDupeZ(allocator, config.experimental_features);
        errdefer if (experimental_features) |value| allocator.free(value);
        const vfs = try optionalDupeZ(allocator, config.vfs);
        errdefer if (vfs) |value| allocator.free(value);
        const encryption_cipher = try optionalDupeZ(allocator, config.encryption_cipher);
        errdefer if (encryption_cipher) |value| allocator.free(value);
        const encryption_hexkey = try optionalDupeZ(allocator, config.encryption_hexkey);

        return .{
            .path = path,
            .experimental_features = experimental_features,
            .vfs = vfs,
            .encryption_cipher = encryption_cipher,
            .encryption_hexkey = encryption_hexkey,
        };
    }

    fn deinit(self: *StoredConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.experimental_features) |value| allocator.free(value);
        if (self.vfs) |value| allocator.free(value);
        if (self.encryption_cipher) |value| allocator.free(value);
        if (self.encryption_hexkey) |value| allocator.free(value);
    }
};

fn configStringsAreValid(config: DatabaseConfig) bool {
    if (std.mem.indexOfScalar(u8, config.path, 0) != null) return false;
    inline for (.{ config.experimental_features, config.vfs, config.encryption_cipher, config.encryption_hexkey }) |value| {
        if (value) |string| {
            if (std.mem.indexOfScalar(u8, string, 0) != null) return false;
        }
    }
    return true;
}

fn optionalDupeZ(allocator: std.mem.Allocator, value: ?[]const u8) std.mem.Allocator.Error!?[:0]u8 {
    if (value) |string| return try allocator.dupeZ(u8, string);
    return null;
}

fn optionalPointer(value: ?[:0]u8) [*c]const u8 {
    if (value) |string| return string.ptr;
    return null;
}
