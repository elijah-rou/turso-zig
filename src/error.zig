const std = @import("std");
const c = @import("c_api.zig").raw;

/// Exhaustive public categories for Turso statuses plus wrapper boundary failures.
pub const Error = error{
    UnexpectedDone,
    UnexpectedRow,
    UnexpectedIo,
    Busy,
    Interrupted,
    BusySnapshot,
    SqlError,
    Misuse,
    Constraint,
    ReadOnly,
    DatabaseFull,
    NotADatabase,
    Corrupt,
    IoError,
    InvalidConfig,
    InvalidArgument,
    InvalidHandle,
    InvalidIndex,
    InvalidState,
    InvalidValue,
    TrailingSql,
    UnknownColumnKind,
    UnknownValueKind,
    UnexpectedDiagnostic,
    UnknownStatus,
    OutOfMemory,
};

pub fn clearDiagnostic(allocator: std.mem.Allocator, diagnostic: *?[]u8) void {
    if (diagnostic.*) |message| allocator.free(message);
    diagnostic.* = null;
}

pub fn setDiagnostic(
    allocator: std.mem.Allocator,
    diagnostic: *?[]u8,
    message: []const u8,
) Error!void {
    std.debug.assert(diagnostic.* == null);
    diagnostic.* = allocator.dupe(u8, message) catch return Error.OutOfMemory;
}

/// Copies and releases a Turso-owned error string. This is the only wrapper path
/// which consumes `error_opt_out`.
pub fn copyAndFreeDiagnostic(
    allocator: std.mem.Allocator,
    error_opt_out: [*c]const u8,
) Error!?[]u8 {
    if (error_opt_out == null) return null;
    defer c.turso_str_deinit(error_opt_out);
    return allocator.dupe(u8, std.mem.span(error_opt_out)) catch Error.OutOfMemory;
}

pub fn finishOperation(
    allocator: std.mem.Allocator,
    status: c.turso_status_code_t,
    error_opt_out: [*c]const u8,
    diagnostic: *?[]u8,
) Error!void {
    return finishExpected(allocator, status, c.TURSO_OK, error_opt_out, diagnostic);
}

pub fn finishExpected(
    allocator: std.mem.Allocator,
    status: c.turso_status_code_t,
    expected: c.turso_status_code_t,
    error_opt_out: [*c]const u8,
    diagnostic: *?[]u8,
) Error!void {
    std.debug.assert(diagnostic.* == null);
    const copied = try copyAndFreeDiagnostic(allocator, error_opt_out);
    if (status == expected) return rejectUnexpectedDiagnostic(allocator, copied);

    diagnostic.* = copied;
    return statusToError(status);
}

pub fn rejectUnexpectedDiagnostic(allocator: std.mem.Allocator, diagnostic: ?[]u8) Error!void {
    if (diagnostic) |unexpected| {
        allocator.free(unexpected);
        return Error.UnexpectedDiagnostic;
    }
}

pub fn statusToError(status: c.turso_status_code_t) Error {
    return switch (status) {
        c.TURSO_DONE => Error.UnexpectedDone,
        c.TURSO_ROW => Error.UnexpectedRow,
        c.TURSO_IO => Error.UnexpectedIo,
        c.TURSO_BUSY => Error.Busy,
        c.TURSO_INTERRUPT => Error.Interrupted,
        c.TURSO_BUSY_SNAPSHOT => Error.BusySnapshot,
        c.TURSO_ERROR => Error.SqlError,
        c.TURSO_MISUSE => Error.Misuse,
        c.TURSO_CONSTRAINT => Error.Constraint,
        c.TURSO_READONLY => Error.ReadOnly,
        c.TURSO_DATABASE_FULL => Error.DatabaseFull,
        c.TURSO_NOTADB => Error.NotADatabase,
        c.TURSO_CORRUPT => Error.Corrupt,
        c.TURSO_IOERR => Error.IoError,
        c.TURSO_OK => Error.InvalidState,
        else => Error.UnknownStatus,
    };
}
