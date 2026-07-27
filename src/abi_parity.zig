const std = @import("std");
const c = @import("c_api.zig").raw;
const callback_value = @import("callback_value.zig");
const Connection = @import("connection.zig").Connection;
const Database = @import("database.zig").Database;
const errors = @import("error.zig");
const ownership = @import("ownership.zig");
const setup = @import("setup.zig");
const Statement = @import("statement.zig").Statement;
const Value = @import("value.zig").Value;

pub const sdk_version = "0.7.1";
pub const upstream_database_io_issue = "https://github.com/tursodatabase/turso/issues/8043";

pub const Disposition = enum {
    safe_wrapper,
    safer_adapter,
    internal_ownership,
    trust_boundary_adapter,
    configuration_exception,
    abi_carrier_exception,
};

pub const FunctionRow = struct {
    name: []const u8,
    disposition: Disposition,
    zig_api: []const u8,
    rationale: []const u8,
    raw_reference: type,
    zig_reference: type,
};

pub const TypeRow = struct {
    name: []const u8,
    disposition: Disposition,
    zig_api: []const u8,
    rationale: []const u8,
    raw_reference: type,
    zig_reference: type,
};

pub const functions = [_]FunctionRow{
    function("turso_connection_close", .safe_wrapper, "Connection.close", "Checked close ordering and retained diagnostics.", @TypeOf(c.turso_connection_close), @TypeOf(Connection.close)),
    function("turso_connection_deinit", .internal_ownership, "Connection.deinit", "Owning handle teardown in reverse acquisition order.", @TypeOf(c.turso_connection_deinit), @TypeOf(Connection.deinit)),
    function("turso_connection_enable_load_extension", .safe_wrapper, "Connection.setSqlExtensionLoadingEnabled", "Per-connection SQL extension capability gate.", @TypeOf(c.turso_connection_enable_load_extension), @TypeOf(Connection.setSqlExtensionLoadingEnabled)),
    function("turso_connection_get_autocommit", .safe_wrapper, "Connection.autocommit", "Reentry-safe transaction-state accessor.", @TypeOf(c.turso_connection_get_autocommit), @TypeOf(Connection.autocommit)),
    function("turso_connection_last_insert_rowid", .safe_wrapper, "Connection.lastInsertRowid", "Reentry-safe rowid accessor.", @TypeOf(c.turso_connection_last_insert_rowid), @TypeOf(Connection.lastInsertRowid)),
    function("turso_connection_load_extension", .trust_boundary_adapter, "Connection.loadExtensionUnsafe", "Explicit arbitrary-native-code trust boundary; no sandbox or safe alias.", @TypeOf(c.turso_connection_load_extension), @TypeOf(Connection.loadExtensionUnsafe)),
    function("turso_connection_prepare_first", .safe_wrapper, "Connection.prepareFirst", "Checked tail offset and owned statement.", @TypeOf(c.turso_connection_prepare_first), @TypeOf(Connection.prepareFirst)),
    function("turso_connection_prepare_single", .safer_adapter, "Connection.prepareSingle", "Deliberately uses prepare_first and rejects trailing SQL because native prepare_single ignores it.", @TypeOf(c.turso_connection_prepare_single), @TypeOf(Connection.prepareSingle)),
    function("turso_connection_register_aggregate_function", .safe_wrapper, "Connection.registerAggregateFunction", "Managed typed context and bounded per-group state ownership.", @TypeOf(c.turso_connection_register_aggregate_function), @TypeOf(Connection.registerAggregateFunction)),
    function("turso_connection_register_collation", .safe_wrapper, "Connection.registerCollation", "Managed typed comparator context.", @TypeOf(c.turso_connection_register_collation), @TypeOf(Connection.registerCollation)),
    function("turso_connection_register_scalar_function", .safe_wrapper, "Connection.registerScalarFunction", "Managed typed callback context and copied results.", @TypeOf(c.turso_connection_register_scalar_function), @TypeOf(Connection.registerScalarFunction)),
    function("turso_connection_set_busy_timeout_ms", .safe_wrapper, "Connection.setBusyTimeoutMs", "Checked unsigned-to-signed duration conversion.", @TypeOf(c.turso_connection_set_busy_timeout_ms), @TypeOf(Connection.setBusyTimeoutMs)),
    function("turso_connection_unregister_collation", .safe_wrapper, "Connection.unregisterCollation", "Checked mutation and context ownership.", @TypeOf(c.turso_connection_unregister_collation), @TypeOf(Connection.unregisterCollation)),
    function("turso_connection_unregister_function", .safe_wrapper, "Connection.unregisterFunction", "Checked mutation and callback context ownership.", @TypeOf(c.turso_connection_unregister_function), @TypeOf(Connection.unregisterFunction)),
    function("turso_database_connect", .safe_wrapper, "Database.connect", "Validates returned handle and tracks child ownership.", @TypeOf(c.turso_database_connect), @TypeOf(Database.connect)),
    function("turso_database_deinit", .internal_ownership, "Database.deinit", "Owning handle teardown after child-count assertion.", @TypeOf(c.turso_database_deinit), @TypeOf(Database.deinit)),
    function("turso_database_new", .safe_wrapper, "Database.create", "Owns configuration strings and construction diagnostics.", @TypeOf(c.turso_database_new), @TypeOf(Database.create)),
    function("turso_database_open", .safe_wrapper, "Database.open / Database.openProgress", "Synchronous wrapper plus explicit caller-driven terminal gap result.", @TypeOf(c.turso_database_open), @TypeOf(Database.openProgress)),
    function("turso_setup", .safe_wrapper, "setup", "Validated process-global setup with owned failures.", @TypeOf(c.turso_setup), @TypeOf(setup.setup)),
    function("turso_statement_bind_positional_blob", .safe_wrapper, "Statement.bindBlob", "Call-borrowed slice with checked position.", @TypeOf(c.turso_statement_bind_positional_blob), @TypeOf(Statement.bindBlob)),
    function("turso_statement_bind_positional_double", .safe_wrapper, "Statement.bindReal", "Checked positional binding.", @TypeOf(c.turso_statement_bind_positional_double), @TypeOf(Statement.bindReal)),
    function("turso_statement_bind_positional_int", .safe_wrapper, "Statement.bindInteger", "Checked positional binding.", @TypeOf(c.turso_statement_bind_positional_int), @TypeOf(Statement.bindInteger)),
    function("turso_statement_bind_positional_null", .safe_wrapper, "Statement.bindNull", "Checked positional binding.", @TypeOf(c.turso_statement_bind_positional_null), @TypeOf(Statement.bindNull)),
    function("turso_statement_bind_positional_text", .safe_wrapper, "Statement.bindText", "Call-borrowed slice with checked position.", @TypeOf(c.turso_statement_bind_positional_text), @TypeOf(Statement.bindText)),
    function("turso_statement_column_array_dimensions", .safe_wrapper, "Statement.columnArrayDimensions", "Bounds-checked metadata accessor.", @TypeOf(c.turso_statement_column_array_dimensions), @TypeOf(Statement.columnArrayDimensions)),
    function("turso_statement_column_base_type", .safe_wrapper, "Statement.columnBaseType", "Copies and releases optional native text.", @TypeOf(c.turso_statement_column_base_type), @TypeOf(Statement.columnBaseType)),
    function("turso_statement_column_count", .safe_wrapper, "Statement.columnCount", "Validates signed count.", @TypeOf(c.turso_statement_column_count), @TypeOf(Statement.columnCount)),
    function("turso_statement_column_declared_name", .safe_wrapper, "Statement.columnDeclaredName", "Copies and releases optional native text.", @TypeOf(c.turso_statement_column_declared_name), @TypeOf(Statement.columnDeclaredName)),
    function("turso_statement_column_decltype", .safe_wrapper, "Statement.columnDeclaredType", "Copies and releases optional native text.", @TypeOf(c.turso_statement_column_decltype), @TypeOf(Statement.columnDeclaredType)),
    function("turso_statement_column_kind", .safe_wrapper, "Statement.columnKind", "Exhaustive stable-tag conversion.", @TypeOf(c.turso_statement_column_kind), @TypeOf(Statement.columnKind)),
    function("turso_statement_column_name", .safe_wrapper, "Statement.columnName", "Copies and releases required native text.", @TypeOf(c.turso_statement_column_name), @TypeOf(Statement.columnName)),
    function("turso_statement_deinit", .internal_ownership, "Statement.deinit", "Owning teardown with progress quiescence assertion.", @TypeOf(c.turso_statement_deinit), @TypeOf(Statement.deinit)),
    function("turso_statement_execute", .safe_wrapper, "Statement.execute / Statement.executeProgress", "Synchronous and single-step progress adapters.", @TypeOf(c.turso_statement_execute), @TypeOf(Statement.executeProgress)),
    function("turso_statement_finalize", .safe_wrapper, "Statement.finalize / Statement.finalizeProgress", "Synchronous and single-step progress adapters.", @TypeOf(c.turso_statement_finalize), @TypeOf(Statement.finalizeProgress)),
    function("turso_statement_n_change", .safe_wrapper, "Statement.changes", "Reentry-safe accessor.", @TypeOf(c.turso_statement_n_change), @TypeOf(Statement.changes)),
    function("turso_statement_named_position", .safe_wrapper, "Statement.namedPosition", "NUL validation and optional checked index.", @TypeOf(c.turso_statement_named_position), @TypeOf(Statement.namedPosition)),
    function("turso_statement_parameter_name", .safe_wrapper, "Statement.parameterName", "Copies and releases optional native text.", @TypeOf(c.turso_statement_parameter_name), @TypeOf(Statement.parameterName)),
    function("turso_statement_parameters_count", .safe_wrapper, "Statement.parameterCount", "Validates signed count.", @TypeOf(c.turso_statement_parameters_count), @TypeOf(Statement.parameterCount)),
    function("turso_statement_reset", .safe_wrapper, "Statement.reset", "Rejects pending caller-driven work.", @TypeOf(c.turso_statement_reset), @TypeOf(Statement.reset)),
    function("turso_statement_row_value_bytes_count", .internal_ownership, "Statement.value", "Validated with pointer before allocator-owned copy.", @TypeOf(c.turso_statement_row_value_bytes_count), @TypeOf(Statement.value)),
    function("turso_statement_row_value_bytes_ptr", .internal_ownership, "Statement.value", "Borrowed bytes are copied before invalidation.", @TypeOf(c.turso_statement_row_value_bytes_ptr), @TypeOf(Statement.value)),
    function("turso_statement_row_value_double", .safe_wrapper, "Statement.value", "Decoded through the row-value tagged union.", @TypeOf(c.turso_statement_row_value_double), @TypeOf(Statement.value)),
    function("turso_statement_row_value_int", .safe_wrapper, "Statement.value", "Decoded through the row-value tagged union.", @TypeOf(c.turso_statement_row_value_int), @TypeOf(Statement.value)),
    function("turso_statement_row_value_kind", .safe_wrapper, "Statement.value", "Exhaustive tag dispatch.", @TypeOf(c.turso_statement_row_value_kind), @TypeOf(Statement.value)),
    function("turso_statement_run_io", .safe_wrapper, "Statement.runIo", "Exactly one caller-driven I/O iteration with state enforcement.", @TypeOf(c.turso_statement_run_io), @TypeOf(Statement.runIo)),
    function("turso_statement_step", .safe_wrapper, "Statement.step / Statement.stepProgress", "Synchronous and single-step progress adapters.", @TypeOf(c.turso_statement_step), @TypeOf(Statement.stepProgress)),
    function("turso_str_deinit", .internal_ownership, "diagnostic/value metadata copy helpers", "Always paired immediately after native allocated-string reads.", @TypeOf(c.turso_str_deinit), @TypeOf(errors.copyAndFreeDiagnostic)),
    function("turso_version", .safe_wrapper, "version", "Bounded validation of process-lifetime native text.", @TypeOf(c.turso_version), @TypeOf(setup.version)),
};

pub const types = [_]TypeRow{
    typeRow("turso_agg_ctx_t", .internal_ownership, "AggregateFunction", "Heap-stable managed aggregate state carrier.", c.turso_agg_ctx_t, callback_value.AggregateFunction(void, void)),
    typeRow("turso_aggregate_final_function_t", .internal_ownership, "AggregateFunction.final", "C-callconv trampoline into managed final callback.", c.turso_aggregate_final_function_t, callback_value.CallbackResult),
    typeRow("turso_aggregate_init_function_t", .internal_ownership, "AggregateFunction.init", "C-callconv trampoline into managed state initializer.", c.turso_aggregate_init_function_t, callback_value.AggregateFunction(void, void)),
    typeRow("turso_aggregate_step_function_t", .internal_ownership, "AggregateFunction.step", "C-callconv trampoline into managed step callback.", c.turso_aggregate_step_function_t, callback_value.CallbackArgs),
    typeRow("turso_collation_function_t", .internal_ownership, "Collation.compare", "C-callconv trampoline with invocation-borrowed UTF-8.", c.turso_collation_function_t, @import("collation.zig").Collation(void)),
    typeRow("turso_column_kind_t", .safe_wrapper, "ColumnKind", "Exhaustive stable-tag conversion.", c.turso_column_kind_t, @import("statement.zig").ColumnKind),
    typeRow("turso_config_t", .safe_wrapper, "SetupConfig", "Validated setup strings and logger adapter.", c.turso_config_t, setup.SetupConfig),
    typeRow("turso_connection_t", .internal_ownership, "Connection", "Opaque owning handle.", c.turso_connection_t, Connection),
    typeRow("turso_context_destructor_t", .internal_ownership, "managed callback deinitializers", "C-callconv ownership trampoline with exactly-once contracts.", c.turso_context_destructor_t, ownership.CallbackGuardSnapshot),
    typeRow("turso_database_config_t", .configuration_exception, "Database.Config", "async_io is mapped to IoMode; database open has no ABI run_io driver (upstream #8043).", c.turso_database_config_t, Database.Config),
    typeRow("turso_database_t", .internal_ownership, "Database", "Opaque owning handle.", c.turso_database_t, Database),
    typeRow("turso_extension_blob_t", .internal_ownership, "BorrowedCallbackValue.blob", "Invocation-borrowed callback blob decoded with bounds.", c.turso_extension_blob_t, callback_value.BorrowedCallbackValue),
    typeRow("turso_extension_error_t", .internal_ownership, "ManagedError", "Defensive callback error decoding and copied result encoding.", c.turso_extension_error_t, callback_value.ManagedError),
    typeRow("turso_extension_result_code_t", .safe_wrapper, "ExtensionResultCode", "Exhaustive callback result-code mapping.", c.turso_extension_result_code_t, callback_value.ExtensionResultCode),
    typeRow("turso_extension_text_subtype_t", .safe_wrapper, "ExtensionTextSubtype", "Exhaustive text/JSON subtype mapping.", c.turso_extension_text_subtype_t, callback_value.ExtensionTextSubtype),
    typeRow("turso_extension_text_t", .internal_ownership, "BorrowedText", "Invocation-borrowed callback text decoded with bounds.", c.turso_extension_text_t, callback_value.BorrowedText),
    typeRow("turso_extension_value_data_t", .internal_ownership, "BorrowedCallbackValue / CallbackResult", "ABI union decoded and encoded by tag.", c.turso_extension_value_data_t, callback_value.BorrowedCallbackValue),
    typeRow("turso_extension_value_type_t", .internal_ownership, "BorrowedCallbackValue", "Exhaustive callback value-tag dispatch.", c.turso_extension_value_type_t, callback_value.BorrowedCallbackValue),
    typeRow("turso_log_t", .safe_wrapper, "Log", "Invocation-borrowed validated logging record.", c.turso_log_t, setup.Log),
    typeRow("turso_scalar_function_t", .internal_ownership, "ScalarFunction.call", "C-callconv trampoline with managed context and result.", c.turso_scalar_function_t, callback_value.ScalarFunction(void)),
    typeRow("turso_slice_ref_t", .abi_carrier_exception, "none", "Unused raw ABI carrier: no public function in 0.7.1 accepts or returns it.", c.turso_slice_ref_t, void),
    typeRow("turso_statement_t", .internal_ownership, "Statement", "Opaque owning handle.", c.turso_statement_t, Statement),
    typeRow("turso_status_code_t", .safe_wrapper, "Error and progress unions", "Exhaustive status/error/progress conversion.", c.turso_status_code_t, errors.Error),
    typeRow("turso_tracing_level_t", .safe_wrapper, "LogLevel", "Exhaustive tracing-level conversion.", c.turso_tracing_level_t, setup.LogLevel),
    typeRow("turso_type_t", .safe_wrapper, "Value", "Exhaustive row-value conversion.", c.turso_type_t, Value),
    typeRow("turso_value_destructor_t", .internal_ownership, "CallbackResult backing destructor", "C-callconv release after native copies managed callback results.", c.turso_value_destructor_t, callback_value.CallbackResult),
    typeRow("turso_value_t", .internal_ownership, "BorrowedCallbackValue / CallbackResult", "Tagged callback value carrier with checked layout.", c.turso_value_t, callback_value.CallbackResult),
};

fn function(comptime name: []const u8, disposition: Disposition, comptime zig_api: []const u8, comptime rationale: []const u8, raw_reference: type, zig_reference: type) FunctionRow {
    return .{ .name = name, .disposition = disposition, .zig_api = zig_api, .rationale = rationale, .raw_reference = raw_reference, .zig_reference = zig_reference };
}

fn typeRow(comptime name: []const u8, disposition: Disposition, comptime zig_api: []const u8, comptime rationale: []const u8, raw_reference: type, zig_reference: type) TypeRow {
    return .{ .name = name, .disposition = disposition, .zig_api = zig_api, .rationale = rationale, .raw_reference = raw_reference, .zig_reference = zig_reference };
}

pub const AuditCounts = struct { missing: usize = 0, unexpected: usize = 0 };

pub fn auditNamespace(comptime Namespace: type, comptime expected_functions: []const FunctionRow, comptime expected_types: []const TypeRow) AuditCounts {
    var counts: AuditCounts = .{};
    inline for (expected_functions) |row| if (!@hasDecl(Namespace, row.name)) {
        counts.missing += 1;
    };
    inline for (expected_types) |row| if (!@hasDecl(Namespace, row.name)) {
        counts.missing += 1;
    };
    inline for (@typeInfo(Namespace).@"struct".decls) |decl| {
        if (comptime !std.mem.startsWith(u8, decl.name, "turso_")) continue;
        const value = @field(Namespace, decl.name);
        const is_public_function = @typeInfo(@TypeOf(value)) == .@"fn";
        const is_public_type = @TypeOf(value) == type and std.mem.endsWith(u8, decl.name, "_t");
        if (!is_public_function and !is_public_type) continue;
        const rows = if (is_public_function) expected_functions else expected_types;
        var found = false;
        inline for (rows) |row| found = found or std.mem.eql(u8, row.name, decl.name);
        if (!found) counts.unexpected += 1;
    }
    return counts;
}

fn validateManifest() void {
    @setEvalBranchQuota(100_000);
    if (functions.len != 48) @compileError("ABI function manifest must contain 48 rows");
    if (types.len != 27) @compileError("ABI type manifest must contain 27 rows");
    inline for (functions, 0..) |row, index| {
        if (row.zig_api.len == 0 or row.rationale.len == 0) @compileError("empty ABI function disposition");
        if (index > 0 and std.mem.order(u8, functions[index - 1].name, row.name) != .lt) @compileError("ABI function manifest is unsorted or duplicated");
        _ = row.raw_reference;
        _ = row.zig_reference;
    }
    inline for (types, 0..) |row, index| {
        if (row.zig_api.len == 0 or row.rationale.len == 0) @compileError("empty ABI type disposition");
        if (index > 0 and std.mem.order(u8, types[index - 1].name, row.name) != .lt) @compileError("ABI type manifest is unsorted or duplicated");
        _ = row.raw_reference;
        _ = row.zig_reference;
    }
    const counts = auditNamespace(c, &functions, &types);
    if (counts.missing != 0 or counts.unexpected != 0) @compileError("Turso public ABI declarations do not exactly match the parity manifest");
    validateCriticalAbi();
}

fn validateCriticalAbi() void {
    if (@sizeOf(c.turso_slice_ref_t) != @sizeOf(usize) * 2 or @alignOf(c.turso_slice_ref_t) != @alignOf(usize) or @offsetOf(c.turso_slice_ref_t, "len") != @sizeOf(usize)) @compileError("slice ABI layout mismatch");
    if (@offsetOf(c.turso_database_config_t, "async_io") != 0 or @offsetOf(c.turso_database_config_t, "path") != 8) @compileError("database config ABI layout mismatch");
    if (@offsetOf(c.turso_extension_text_t, "subtype") != 0 or @offsetOf(c.turso_extension_text_t, "text") != 8 or @offsetOf(c.turso_extension_text_t, "len") != 16) @compileError("extension text ABI layout mismatch");
    if (@sizeOf(c.turso_extension_value_data_t) != 8 or @offsetOf(c.turso_value_t, "value_type") != 0 or @offsetOf(c.turso_value_t, "value") != 8 or @sizeOf(c.turso_value_t) != 16) @compileError("callback value ABI layout mismatch");
    inline for (.{ c.turso_context_destructor_t, c.turso_value_destructor_t, c.turso_scalar_function_t, c.turso_aggregate_init_function_t, c.turso_aggregate_step_function_t, c.turso_aggregate_final_function_t, c.turso_collation_function_t }) |Callback| {
        const pointer = @typeInfo(Callback).optional.child;
        const signature = @typeInfo(@typeInfo(pointer).pointer.child).@"fn";
        if (std.meta.activeTag(signature.calling_convention) != std.meta.activeTag(std.builtin.CallingConvention.c)) @compileError("callback calling convention mismatch");
    }
    if (c.TURSO_OK != 0 or c.TURSO_IO != 3 or c.TURSO_ERROR != 127 or c.TURSO_IOERR != 134) @compileError("status tags mismatch");
    if (c.TURSO_TYPE_UNKNOWN != 0 or c.TURSO_TYPE_NULL != 5) @compileError("value tags mismatch");
    if (c.TURSO_EXTENSION_VALUE_NULL != 0 or c.TURSO_EXTENSION_VALUE_ERROR != 5) @compileError("callback value tags mismatch");
    if (c.TURSO_EXTENSION_RESULT_OK != 0 or c.TURSO_EXTENSION_RESULT_CONSTRAINT_VIOLATION != 21) @compileError("callback result tags mismatch");
    if (c.TURSO_COLUMN_KIND_NONE != -1 or c.TURSO_COLUMN_KIND_UNION != 4) @compileError("column kind tags mismatch");
}

comptime {
    validateManifest();
}

test "documentation is structurally tied to the manifest" {
    @setEvalBranchQuota(100_000);
    const document = @embedFile("abi-parity-doc");
    try std.testing.expect(std.mem.indexOf(u8, document, "48 public functions") != null);
    try std.testing.expect(std.mem.indexOf(u8, document, "27 public typedefs") != null);
    inline for (functions) |row| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, document, std.fmt.comptimePrint("`{s}` |", .{row.name})));
    inline for (types) |row| try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, document, std.fmt.comptimePrint("`{s}` |", .{row.name})));
}

test "synthetic namespace mismatch detects missing and extra declarations" {
    const Empty = struct {};
    const Extra = struct {
        pub fn turso_extra() callconv(.c) void {}
    };
    const one = functions[0..1];
    const missing = auditNamespace(Empty, one, &.{});
    try std.testing.expectEqual(@as(usize, 1), missing.missing);
    try std.testing.expectEqual(@as(usize, 0), missing.unexpected);
    const extra = auditNamespace(Extra, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), extra.missing);
    try std.testing.expectEqual(@as(usize, 1), extra.unexpected);
}
