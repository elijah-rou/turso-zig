const std = @import("std");

/// Machine-checked classification of every public Turso SDK Kit 0.7.1 ABI declaration.
pub const abi_parity = @import("abi_parity.zig");
/// Raw Turso SDK Kit 0.7.1 C bindings. This namespace is unstable and unsafe;
/// parity classification does not make direct raw calls memory-safe.
pub const c = @import("c_api.zig").raw;
pub const Error = @import("error.zig").Error;
pub const LogLevel = @import("setup.zig").LogLevel;
pub const Log = @import("setup.zig").Log;
pub const Logger = @import("setup.zig").Logger;
pub const SetupConfig = @import("setup.zig").SetupConfig;
pub const SetupFailure = @import("setup.zig").SetupFailure;
pub const SetupResult = @import("setup.zig").SetupResult;
pub const setup = @import("setup.zig").setup;
pub const version = @import("setup.zig").version;
pub const Value = @import("value.zig").Value;
pub const IoMode = @import("io_progress.zig").IoMode;
pub const OpenProgress = @import("io_progress.zig").OpenProgress;
pub const StepProgress = @import("io_progress.zig").StepProgress;
pub const ExecuteProgress = @import("io_progress.zig").ExecuteProgress;
pub const FinalizeProgress = @import("io_progress.zig").FinalizeProgress;
pub const ExtensionResultCode = @import("callback_value.zig").ExtensionResultCode;
pub const ExtensionTextSubtype = @import("callback_value.zig").ExtensionTextSubtype;
pub const BorrowedText = @import("callback_value.zig").BorrowedText;
pub const ManagedError = @import("callback_value.zig").ManagedError;
pub const BorrowedCallbackValue = @import("callback_value.zig").BorrowedCallbackValue;
pub const CallbackArgs = @import("callback_value.zig").CallbackArgs;
pub const CallbackResult = @import("callback_value.zig").CallbackResult;
pub const Arity = @import("callback_value.zig").Arity;
pub const ScalarFunction = @import("callback_value.zig").ScalarFunction;
pub const AggregateFunction = @import("callback_value.zig").AggregateFunction;
pub const Collation = @import("collation.zig").Collation;
pub const Database = @import("database.zig").Database;
pub const Connection = @import("connection.zig").Connection;
pub const PrepareFirstResult = @import("connection.zig").PrepareFirstResult;
pub const Statement = @import("statement.zig").Statement;
pub const Step = @import("statement.zig").Step;
pub const ColumnKind = @import("statement.zig").ColumnKind;
pub const ConstructionFailure = @import("database.zig").ConstructionFailure;

pub const abi_version = "0.7.1";

/// Returns whether a native library version belongs to the pinned 0.7.1 ABI.
pub fn isAbiCompatibleVersion(runtime_version: []const u8) bool {
    if (!std.mem.startsWith(u8, runtime_version, abi_version)) return false;
    if (runtime_version.len == abi_version.len) return true;

    return switch (runtime_version[abi_version.len]) {
        '-', '+' => true,
        else => false,
    };
}
