const std = @import("std");
const c = @import("c_api.zig").raw;
const errors = @import("error.zig");

const max_c_string_length: usize = 64 * 1024;
const max_log_level_length: usize = 64;
const max_version_length: usize = 256;

/// A native tracing severity. Values match Turso SDK Kit 0.7.1 exactly.
pub const LogLevel = enum(c.turso_tracing_level_t) {
    err = c.TURSO_TRACING_LEVEL_ERROR,
    warn = c.TURSO_TRACING_LEVEL_WARN,
    info = c.TURSO_TRACING_LEVEL_INFO,
    debug = c.TURSO_TRACING_LEVEL_DEBUG,
    trace = c.TURSO_TRACING_LEVEL_TRACE,
};

/// A log record borrowed only for the logger invocation.
pub const Log = struct {
    message: []const u8,
    target: []const u8,
    file: []const u8,
    timestamp: u64,
    line: usize,
    level: LogLevel,
};

/// A process-lifetime callback. It may run concurrently on native threads and
/// must not retain record slices, panic, call itself reentrantly, or call setup.
/// Empty message, target, and file slices and zero timestamps and lines are
/// valid native records.
pub const Logger = *const fn (log: Log) void;

pub const SetupConfig = struct {
    /// Replaces the callback installed by an earlier successful setup call.
    /// Null leaves an installed callback unchanged and installs none initially.
    logger: ?Logger = null,
    /// One of error, warn, info, debug, or trace. Null uses native environment
    /// filtering on the first successful setup call.
    log_level: ?[]const u8 = null,
};

pub const SetupFailure = struct {
    category: errors.Error,
    diagnostic: []u8,

    pub fn deinit(self: *SetupFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.diagnostic);
        self.diagnostic = &.{};
    }
};

pub const SetupResult = union(enum) {
    success,
    failure: SetupFailure,
};

var setup_mutex: std.Io.Mutex = .init;
var logger_pointer: std.atomic.Value(?Logger) = .init(null);
threadlocal var logger_invocation_active = false;

/// Returns the process-lifetime native SDK version string.
pub fn version() errors.Error![]const u8 {
    const pointer = c.turso_version();
    return boundedCString(pointer, max_version_length) orelse errors.Error.InvalidValue;
}

/// Configures process-global native tracing. The first successful call fixes
/// the native level filter for the process. Later successful calls may replace
/// the logger, but cannot change that filter.
pub fn setup(allocator: std.mem.Allocator, config: SetupConfig) std.mem.Allocator.Error!SetupResult {
    if (logger_invocation_active) {
        return setupFailure(allocator, errors.Error.InvalidState, "setup must not be called from a logger callback");
    }
    if (config.log_level) |level| {
        if (level.len > max_log_level_length) {
            return setupFailure(allocator, errors.Error.InvalidConfig, "setup log level exceeds the supported length");
        }
        if (parseLogLevel(level) == null) {
            return setupFailure(allocator, errors.Error.InvalidConfig, "setup log level must be one of error, warn, info, debug, or trace");
        }
    }

    const stored_level = if (config.log_level) |level| try allocator.dupeZ(u8, level) else null;
    defer if (stored_level) |level| allocator.free(level);

    std.Io.Threaded.mutexLock(&setup_mutex);
    defer std.Io.Threaded.mutexUnlock(&setup_mutex);

    var c_config = std.mem.zeroes(c.turso_config_t);
    c_config.logger = if (config.logger != null) loggerTrampoline else null;
    c_config.log_level = if (stored_level) |level| level.ptr else null;

    const previous_logger = logger_pointer.load(.acquire);
    const candidate_logger = config.logger orelse previous_logger;
    logger_pointer.store(candidate_logger, .release);

    var error_opt_out: [*c]const u8 = null;
    const status = c.turso_setup(&c_config, &error_opt_out);
    if (status == c.TURSO_OK) {
        if (error_opt_out != null) {
            c.turso_str_deinit(error_opt_out);
            std.log.err("turso_setup returned TURSO_OK with an unexpected diagnostic", .{});
            std.debug.assert(error_opt_out == null);
        }
        return .success;
    }

    logger_pointer.store(previous_logger, .release);
    const category = errors.statusToError(status);
    const diagnostic = errors.copyAndFreeDiagnostic(allocator, error_opt_out) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    return .{ .failure = .{
        .category = category,
        .diagnostic = diagnostic orelse try allocator.dupe(u8, @errorName(category)),
    } };
}

fn setupFailure(
    allocator: std.mem.Allocator,
    category: errors.Error,
    diagnostic: []const u8,
) std.mem.Allocator.Error!SetupResult {
    return .{ .failure = .{
        .category = category,
        .diagnostic = try allocator.dupe(u8, diagnostic),
    } };
}

fn parseLogLevel(level: []const u8) ?LogLevel {
    if (std.mem.eql(u8, level, "error")) return .err;
    if (std.mem.eql(u8, level, "warn")) return .warn;
    if (std.mem.eql(u8, level, "info")) return .info;
    if (std.mem.eql(u8, level, "debug")) return .debug;
    if (std.mem.eql(u8, level, "trace")) return .trace;
    return null;
}

fn loggerTrampoline(log_pointer: [*c]const c.turso_log_t) callconv(.c) void {
    if (log_pointer == null) return;
    if (logger_invocation_active) return;

    const native_log = log_pointer[0];
    const message = boundedCString(native_log.message, max_c_string_length) orelse return;
    const target = boundedCString(native_log.target, max_c_string_length) orelse return;
    const file = boundedCString(native_log.file, max_c_string_length) orelse return;
    const level: LogLevel = switch (native_log.level) {
        c.TURSO_TRACING_LEVEL_ERROR => .err,
        c.TURSO_TRACING_LEVEL_WARN => .warn,
        c.TURSO_TRACING_LEVEL_INFO => .info,
        c.TURSO_TRACING_LEVEL_DEBUG => .debug,
        c.TURSO_TRACING_LEVEL_TRACE => .trace,
        else => return,
    };
    const logger = logger_pointer.load(.acquire) orelse return;

    logger_invocation_active = true;
    defer logger_invocation_active = false;
    logger(.{
        .message = message,
        .target = target,
        .file = file,
        .timestamp = native_log.timestamp,
        .line = native_log.line,
        .level = level,
    });
}

fn boundedCString(pointer: [*c]const u8, limit: usize) ?[]const u8 {
    if (pointer == null) return null;
    var length: usize = 0;
    while (length < limit) : (length += 1) {
        if (pointer[length] == 0) return pointer[0..length];
    }
    return null;
}

const CLogger = ?*const fn ([*c]const c.turso_log_t) callconv(.c) void;

const ExpectedConfig = extern struct {
    logger: CLogger,
    log_level: [*c]const u8,
};

const ExpectedLog = extern struct {
    message: [*c]const u8,
    target: [*c]const u8,
    file: [*c]const u8,
    timestamp: u64,
    line: usize,
    level: c.turso_tracing_level_t,
};

comptime {
    if (@sizeOf(LogLevel) != @sizeOf(c.turso_tracing_level_t)) @compileError("Turso log level ABI size mismatch");
    if (@sizeOf(Logger) != @sizeOf(usize)) @compileError("Turso logger pointer size mismatch");
    if (@sizeOf(ExpectedConfig) != @sizeOf(c.turso_config_t)) @compileError("Turso setup config ABI size mismatch");
    if (@alignOf(ExpectedConfig) != @alignOf(c.turso_config_t)) @compileError("Turso setup config ABI alignment mismatch");
    for (.{ "logger", "log_level" }) |field| {
        if (@offsetOf(ExpectedConfig, field) != @offsetOf(c.turso_config_t, field)) {
            @compileError("Turso setup config ABI field offset mismatch: " ++ field);
        }
    }
    if (@sizeOf(ExpectedLog) != @sizeOf(c.turso_log_t)) @compileError("Turso log ABI size mismatch");
    if (@alignOf(ExpectedLog) != @alignOf(c.turso_log_t)) @compileError("Turso log ABI alignment mismatch");
    for (.{ "message", "target", "file", "timestamp", "line", "level" }) |field| {
        if (@offsetOf(ExpectedLog, field) != @offsetOf(c.turso_log_t, field)) {
            @compileError("Turso log ABI field offset mismatch: " ++ field);
        }
    }

    const expected_logger: CLogger = loggerTrampoline;
    _ = expected_logger;
    const expected_setup: *const fn ([*c]const c.turso_config_t, [*c][*c]const u8) callconv(.c) c.turso_status_code_t = &c.turso_setup;
    _ = expected_setup;
    const expected_version: *const fn (...) callconv(.c) [*c]const u8 = &c.turso_version;
    _ = expected_version;
}
