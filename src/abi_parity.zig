const std = @import("std");
const c_api = @import("c_api.zig");
const c = c_api.raw;
const aggregate_function = @import("aggregate_function.zig");
const callback_value = @import("callback_value.zig");
const collation = @import("collation.zig");
const connection = @import("connection.zig");
const Connection = connection.Connection;
const Database = @import("database.zig").Database;
const errors = @import("error.zig");
const progress = @import("io_progress.zig");
const setup = @import("setup.zig");
const statement = @import("statement.zig");
const Statement = statement.Statement;
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

pub const ZigApi = enum {
    connection_close,
    connection_deinit,
    connection_set_extension_loading,
    connection_autocommit,
    connection_last_insert_rowid,
    connection_load_extension_unsafe,
    connection_prepare_first,
    connection_prepare_single,
    connection_register_aggregate,
    connection_register_collation,
    connection_register_scalar,
    connection_set_busy_timeout,
    connection_unregister_collation,
    connection_unregister_function,
    database_connect,
    database_deinit,
    database_create,
    database_open,
    database_open_progress,
    setup,
    statement_bind_blob,
    statement_bind_real,
    statement_bind_integer,
    statement_bind_null,
    statement_bind_text,
    statement_column_array_dimensions,
    statement_column_base_type,
    statement_column_count,
    statement_column_declared_name,
    statement_column_declared_type,
    statement_column_kind,
    statement_column_name,
    statement_deinit,
    statement_execute,
    statement_execute_progress,
    statement_finalize,
    statement_finalize_progress,
    statement_changes,
    statement_named_position,
    statement_parameter_name,
    statement_parameter_count,
    statement_reset,
    statement_value,
    statement_run_io,
    statement_step,
    statement_step_progress,
    copy_and_free_diagnostic,
    version,
    aggregate_state_carrier,
    aggregate_final_trampoline,
    aggregate_init_trampoline,
    aggregate_step_trampoline,
    collation_compare_trampoline,
    column_kind,
    setup_config,
    logger_trampoline,
    connection_type,
    scalar_context_destructor,
    aggregate_context_destructor,
    aggregate_state_destructor,
    collation_context_destructor,
    database_config,
    database_type,
    decode_callback_args,
    managed_error,
    encode_callback_result,
    extension_result_code,
    extension_text_subtype,
    borrowed_text,
    log,
    scalar_trampoline,
    unused_slice_carrier,
    statement_type,
    status_to_error,
    open_progress,
    execute_progress,
    step_progress,
    finalize_progress,
    log_level,
    value,
    destroy_callback_result,
};

pub const FunctionRow = struct {
    name: []const u8,
    disposition: Disposition,
    apis: []const ZigApi,
    rationale: []const u8,
    issue_or_exception: []const u8,
};

pub const TypeRow = FunctionRow;

pub const functions = [_]FunctionRow{
    row("turso_connection_close", .safe_wrapper, &.{.connection_close}, "Checked close ordering and retained diagnostics.", "none"),
    row("turso_connection_deinit", .internal_ownership, &.{.connection_deinit}, "Owning handle teardown in reverse acquisition order.", "none"),
    row("turso_connection_enable_load_extension", .safe_wrapper, &.{.connection_set_extension_loading}, "Per-connection SQL extension capability gate.", "none"),
    row("turso_connection_get_autocommit", .safe_wrapper, &.{.connection_autocommit}, "Reentry-safe transaction-state accessor.", "none"),
    row("turso_connection_last_insert_rowid", .safe_wrapper, &.{.connection_last_insert_rowid}, "Reentry-safe rowid accessor.", "none"),
    row("turso_connection_load_extension", .trust_boundary_adapter, &.{.connection_load_extension_unsafe}, "Explicit arbitrary-native-code trust boundary; no sandbox or safe alias.", "unsafe native-code trust boundary"),
    row("turso_connection_prepare_first", .safe_wrapper, &.{.connection_prepare_first}, "Checked tail offset and owned statement.", "none"),
    row("turso_connection_prepare_single", .safer_adapter, &.{.connection_prepare_single}, "Deliberately uses prepare_first and rejects trailing SQL because native prepare_single ignores it.", "none"),
    row("turso_connection_register_aggregate_function", .safe_wrapper, &.{.connection_register_aggregate}, "Managed typed context and bounded per-group state ownership.", "none"),
    row("turso_connection_register_collation", .safe_wrapper, &.{.connection_register_collation}, "Managed typed comparator context.", "none"),
    row("turso_connection_register_scalar_function", .safe_wrapper, &.{.connection_register_scalar}, "Managed typed callback context and copied results.", "none"),
    row("turso_connection_set_busy_timeout_ms", .safe_wrapper, &.{.connection_set_busy_timeout}, "Checked unsigned-to-signed duration conversion.", "none"),
    row("turso_connection_unregister_collation", .safe_wrapper, &.{.connection_unregister_collation}, "Checked mutation and context ownership.", "none"),
    row("turso_connection_unregister_function", .safe_wrapper, &.{.connection_unregister_function}, "Checked mutation and callback context ownership.", "none"),
    row("turso_database_connect", .safe_wrapper, &.{.database_connect}, "Validates returned handle and tracks child ownership.", "none"),
    row("turso_database_deinit", .internal_ownership, &.{.database_deinit}, "Owning handle teardown after child-count assertion.", "none"),
    row("turso_database_new", .safe_wrapper, &.{.database_create}, "Owns configuration strings and construction diagnostics.", "none"),
    row("turso_database_open", .safe_wrapper, &.{ .database_open, .database_open_progress }, "Synchronous wrapper plus explicit caller-driven terminal gap result.", "no database run_io in 0.7.1"),
    row("turso_setup", .safe_wrapper, &.{.setup}, "Validated process-global setup with owned failures.", "none"),
    row("turso_statement_bind_positional_blob", .safe_wrapper, &.{.statement_bind_blob}, "Call-borrowed slice with checked position.", "none"),
    row("turso_statement_bind_positional_double", .safe_wrapper, &.{.statement_bind_real}, "Checked positional binding.", "none"),
    row("turso_statement_bind_positional_int", .safe_wrapper, &.{.statement_bind_integer}, "Checked positional binding.", "none"),
    row("turso_statement_bind_positional_null", .safe_wrapper, &.{.statement_bind_null}, "Checked positional binding.", "none"),
    row("turso_statement_bind_positional_text", .safe_wrapper, &.{.statement_bind_text}, "Call-borrowed slice with checked position.", "none"),
    row("turso_statement_column_array_dimensions", .safe_wrapper, &.{.statement_column_array_dimensions}, "Bounds-checked metadata accessor.", "none"),
    row("turso_statement_column_base_type", .safe_wrapper, &.{.statement_column_base_type}, "Copies and releases optional native text.", "none"),
    row("turso_statement_column_count", .safe_wrapper, &.{.statement_column_count}, "Validates signed count.", "none"),
    row("turso_statement_column_declared_name", .safe_wrapper, &.{.statement_column_declared_name}, "Copies and releases optional native text.", "none"),
    row("turso_statement_column_decltype", .safe_wrapper, &.{.statement_column_declared_type}, "Copies and releases optional native text.", "none"),
    row("turso_statement_column_kind", .safe_wrapper, &.{.statement_column_kind}, "Exhaustive stable-tag conversion.", "none"),
    row("turso_statement_column_name", .safe_wrapper, &.{.statement_column_name}, "Copies and releases required native text.", "none"),
    row("turso_statement_deinit", .internal_ownership, &.{.statement_deinit}, "Owning teardown with progress quiescence assertion.", "none"),
    row("turso_statement_execute", .safe_wrapper, &.{ .statement_execute, .statement_execute_progress }, "Synchronous and single-step progress adapters.", "none"),
    row("turso_statement_finalize", .safe_wrapper, &.{ .statement_finalize, .statement_finalize_progress }, "Synchronous and single-step progress adapters.", "none"),
    row("turso_statement_n_change", .safe_wrapper, &.{.statement_changes}, "Reentry-safe accessor.", "none"),
    row("turso_statement_named_position", .safe_wrapper, &.{.statement_named_position}, "NUL validation and optional checked index.", "none"),
    row("turso_statement_parameter_name", .safe_wrapper, &.{.statement_parameter_name}, "Copies and releases optional native text.", "none"),
    row("turso_statement_parameters_count", .safe_wrapper, &.{.statement_parameter_count}, "Validates signed count.", "none"),
    row("turso_statement_reset", .safe_wrapper, &.{.statement_reset}, "Rejects pending caller-driven work.", "none"),
    row("turso_statement_row_value_bytes_count", .internal_ownership, &.{.statement_value}, "Validated with pointer before allocator-owned copy.", "none"),
    row("turso_statement_row_value_bytes_ptr", .internal_ownership, &.{.statement_value}, "Borrowed bytes are copied before invalidation.", "none"),
    row("turso_statement_row_value_double", .safe_wrapper, &.{.statement_value}, "Decoded through the row-value tagged union.", "none"),
    row("turso_statement_row_value_int", .safe_wrapper, &.{.statement_value}, "Decoded through the row-value tagged union.", "none"),
    row("turso_statement_row_value_kind", .safe_wrapper, &.{.statement_value}, "Exhaustive tag dispatch.", "none"),
    row("turso_statement_run_io", .safe_wrapper, &.{.statement_run_io}, "Exactly one caller-driven I/O iteration with state enforcement.", "none"),
    row("turso_statement_step", .safe_wrapper, &.{ .statement_step, .statement_step_progress }, "Synchronous and single-step progress adapters.", "none"),
    row("turso_str_deinit", .internal_ownership, &.{.copy_and_free_diagnostic}, "Always paired immediately after native allocated-string reads.", "none"),
    row("turso_version", .safe_wrapper, &.{.version}, "Bounded validation of process-lifetime native text.", "none"),
};

pub const types = [_]TypeRow{
    row("turso_agg_ctx_t", .internal_ownership, &.{.aggregate_state_carrier}, "Heap-stable managed aggregate state carrier.", "none"),
    row("turso_aggregate_final_function_t", .internal_ownership, &.{.aggregate_final_trampoline}, "C-callconv trampoline into managed final callback.", "none"),
    row("turso_aggregate_init_function_t", .internal_ownership, &.{.aggregate_init_trampoline}, "C-callconv trampoline into managed state initializer.", "none"),
    row("turso_aggregate_step_function_t", .internal_ownership, &.{.aggregate_step_trampoline}, "C-callconv trampoline into managed step callback.", "none"),
    row("turso_collation_function_t", .internal_ownership, &.{.collation_compare_trampoline}, "C-callconv trampoline with invocation-borrowed UTF-8.", "none"),
    row("turso_column_kind_t", .safe_wrapper, &.{.column_kind}, "Exhaustive stable-tag conversion.", "none"),
    row("turso_config_t", .safe_wrapper, &.{ .setup_config, .logger_trampoline }, "Validated setup strings and logger adapter.", "none"),
    row("turso_connection_t", .internal_ownership, &.{.connection_type}, "Opaque owning handle.", "none"),
    row("turso_context_destructor_t", .internal_ownership, &.{ .scalar_context_destructor, .aggregate_context_destructor, .aggregate_state_destructor, .collation_context_destructor }, "C-callconv ownership trampoline with exactly-once contracts.", "none"),
    row("turso_database_config_t", .configuration_exception, &.{.database_config}, "async_io is mapped to IoMode; database open has no ABI run_io driver (upstream #8043).", "upstream #8043"),
    row("turso_database_t", .internal_ownership, &.{.database_type}, "Opaque owning handle.", "none"),
    row("turso_extension_blob_t", .internal_ownership, &.{ .decode_callback_args, .encode_callback_result }, "Invocation-borrowed callback blob decoded with bounds.", "none"),
    row("turso_extension_error_t", .internal_ownership, &.{ .managed_error, .decode_callback_args, .encode_callback_result }, "Defensive callback error decoding and copied result encoding.", "none"),
    row("turso_extension_result_code_t", .safe_wrapper, &.{.extension_result_code}, "Exhaustive callback result-code mapping.", "none"),
    row("turso_extension_text_subtype_t", .safe_wrapper, &.{.extension_text_subtype}, "Exhaustive text/JSON subtype mapping.", "none"),
    row("turso_extension_text_t", .internal_ownership, &.{ .borrowed_text, .decode_callback_args, .encode_callback_result }, "Invocation-borrowed callback text decoded with bounds.", "none"),
    row("turso_extension_value_data_t", .internal_ownership, &.{ .decode_callback_args, .encode_callback_result }, "ABI union decoded and encoded by tag.", "none"),
    row("turso_extension_value_type_t", .internal_ownership, &.{ .decode_callback_args, .encode_callback_result }, "Exhaustive callback value-tag dispatch.", "none"),
    row("turso_log_t", .safe_wrapper, &.{ .log, .logger_trampoline }, "Invocation-borrowed validated logging record.", "none"),
    row("turso_scalar_function_t", .internal_ownership, &.{.scalar_trampoline}, "C-callconv trampoline with managed context and result.", "none"),
    row("turso_slice_ref_t", .abi_carrier_exception, &.{.unused_slice_carrier}, "Unused raw ABI carrier: no public function in 0.7.1 accepts or returns it.", "unused ABI carrier"),
    row("turso_statement_t", .internal_ownership, &.{.statement_type}, "Opaque owning handle.", "none"),
    row("turso_status_code_t", .safe_wrapper, &.{ .status_to_error, .open_progress, .execute_progress, .step_progress, .finalize_progress }, "Exhaustive status/error/progress conversion.", "none"),
    row("turso_tracing_level_t", .safe_wrapper, &.{ .log_level, .logger_trampoline }, "Exhaustive tracing-level conversion.", "none"),
    row("turso_type_t", .safe_wrapper, &.{ .value, .statement_value }, "Exhaustive row-value conversion.", "none"),
    row("turso_value_destructor_t", .internal_ownership, &.{.destroy_callback_result}, "C-callconv release after native copies managed callback results.", "none"),
    row("turso_value_t", .internal_ownership, &.{ .decode_callback_args, .encode_callback_result }, "Tagged callback value carrier with checked layout.", "none"),
};

fn row(
    comptime name: []const u8,
    disposition: Disposition,
    comptime apis: []const ZigApi,
    comptime rationale: []const u8,
    comptime issue_or_exception: []const u8,
) FunctionRow {
    return .{
        .name = name,
        .disposition = disposition,
        .apis = apis,
        .rationale = rationale,
        .issue_or_exception = issue_or_exception,
    };
}

fn apiName(api: ZigApi) []const u8 {
    return switch (api) {
        .connection_close => "Connection.close",
        .connection_deinit => "Connection.deinit",
        .connection_set_extension_loading => "Connection.setSqlExtensionLoadingEnabled",
        .connection_autocommit => "Connection.autocommit",
        .connection_last_insert_rowid => "Connection.lastInsertRowid",
        .connection_load_extension_unsafe => "Connection.loadExtensionUnsafe",
        .connection_prepare_first => "Connection.prepareFirst",
        .connection_prepare_single => "Connection.prepareSingle",
        .connection_register_aggregate => "Connection.registerAggregateFunction",
        .connection_register_collation => "Connection.registerCollation",
        .connection_register_scalar => "Connection.registerScalarFunction",
        .connection_set_busy_timeout => "Connection.setBusyTimeoutMs",
        .connection_unregister_collation => "Connection.unregisterCollation",
        .connection_unregister_function => "Connection.unregisterFunction",
        .database_connect => "Database.connect",
        .database_deinit => "Database.deinit",
        .database_create => "Database.create",
        .database_open => "Database.open",
        .database_open_progress => "Database.openProgress",
        .setup => "setup",
        .statement_bind_blob => "Statement.bindBlob",
        .statement_bind_real => "Statement.bindReal",
        .statement_bind_integer => "Statement.bindInteger",
        .statement_bind_null => "Statement.bindNull",
        .statement_bind_text => "Statement.bindText",
        .statement_column_array_dimensions => "Statement.columnArrayDimensions",
        .statement_column_base_type => "Statement.columnBaseType",
        .statement_column_count => "Statement.columnCount",
        .statement_column_declared_name => "Statement.columnDeclaredName",
        .statement_column_declared_type => "Statement.columnDeclaredType",
        .statement_column_kind => "Statement.columnKind",
        .statement_column_name => "Statement.columnName",
        .statement_deinit => "Statement.deinit",
        .statement_execute => "Statement.execute",
        .statement_execute_progress => "Statement.executeProgress",
        .statement_finalize => "Statement.finalize",
        .statement_finalize_progress => "Statement.finalizeProgress",
        .statement_changes => "Statement.changes",
        .statement_named_position => "Statement.namedPosition",
        .statement_parameter_name => "Statement.parameterName",
        .statement_parameter_count => "Statement.parameterCount",
        .statement_reset => "Statement.reset",
        .statement_value => "Statement.value",
        .statement_run_io => "Statement.runIo",
        .statement_step => "Statement.step",
        .statement_step_progress => "Statement.stepProgress",
        .copy_and_free_diagnostic => "errors.copyAndFreeDiagnostic",
        .version => "version",
        .aggregate_state_carrier => "aggregate_function.StateBox",
        .aggregate_final_trampoline => "aggregate_function.finalTrampoline",
        .aggregate_init_trampoline => "aggregate_function.initTrampoline",
        .aggregate_step_trampoline => "aggregate_function.stepTrampoline",
        .collation_compare_trampoline => "collation.compareTrampoline",
        .column_kind => "ColumnKind",
        .setup_config => "SetupConfig",
        .logger_trampoline => "setup.loggerTrampoline",
        .connection_type => "Connection",
        .scalar_context_destructor => "connection.scalarContextDestructor",
        .aggregate_context_destructor => "aggregate_function.contextDestructor",
        .aggregate_state_destructor => "aggregate_function.stateDestructor",
        .collation_context_destructor => "collation.contextDestructor",
        .database_config => "Database.Config",
        .database_type => "Database",
        .decode_callback_args => "callback_value.decodeArgs",
        .managed_error => "ManagedError",
        .encode_callback_result => "callback_value.encodeResult",
        .extension_result_code => "ExtensionResultCode",
        .extension_text_subtype => "ExtensionTextSubtype",
        .borrowed_text => "BorrowedText",
        .log => "Log",
        .scalar_trampoline => "connection.scalarTrampoline",
        .unused_slice_carrier => "none (unused ABI carrier)",
        .statement_type => "Statement",
        .status_to_error => "errors.statusToError",
        .open_progress => "OpenProgress",
        .execute_progress => "ExecuteProgress",
        .step_progress => "StepProgress",
        .finalize_progress => "FinalizeProgress",
        .log_level => "LogLevel",
        .value => "Value",
        .destroy_callback_result => "callback_value.destroyResult",
    };
}

fn validateApiReference(api: ZigApi) void {
    switch (api) {
        .connection_close => _ = @TypeOf(Connection.close),
        .connection_deinit => _ = @TypeOf(Connection.deinit),
        .connection_set_extension_loading => _ = @TypeOf(Connection.setSqlExtensionLoadingEnabled),
        .connection_autocommit => _ = @TypeOf(Connection.autocommit),
        .connection_last_insert_rowid => _ = @TypeOf(Connection.lastInsertRowid),
        .connection_load_extension_unsafe => _ = @TypeOf(Connection.loadExtensionUnsafe),
        .connection_prepare_first => _ = @TypeOf(Connection.prepareFirst),
        .connection_prepare_single => _ = @TypeOf(Connection.prepareSingle),
        .connection_register_aggregate => _ = @TypeOf(Connection.registerAggregateFunction),
        .connection_register_collation => _ = @TypeOf(Connection.registerCollation),
        .connection_register_scalar => _ = @TypeOf(Connection.registerScalarFunction),
        .connection_set_busy_timeout => _ = @TypeOf(Connection.setBusyTimeoutMs),
        .connection_unregister_collation => _ = @TypeOf(Connection.unregisterCollation),
        .connection_unregister_function => _ = @TypeOf(Connection.unregisterFunction),
        .database_connect => _ = @TypeOf(Database.connect),
        .database_deinit => _ = @TypeOf(Database.deinit),
        .database_create => _ = @TypeOf(Database.create),
        .database_open => _ = @TypeOf(Database.open),
        .database_open_progress => _ = @TypeOf(Database.openProgress),
        .setup => _ = @TypeOf(setup.setup),
        .statement_bind_blob => _ = @TypeOf(Statement.bindBlob),
        .statement_bind_real => _ = @TypeOf(Statement.bindReal),
        .statement_bind_integer => _ = @TypeOf(Statement.bindInteger),
        .statement_bind_null => _ = @TypeOf(Statement.bindNull),
        .statement_bind_text => _ = @TypeOf(Statement.bindText),
        .statement_column_array_dimensions => _ = @TypeOf(Statement.columnArrayDimensions),
        .statement_column_base_type => _ = @TypeOf(Statement.columnBaseType),
        .statement_column_count => _ = @TypeOf(Statement.columnCount),
        .statement_column_declared_name => _ = @TypeOf(Statement.columnDeclaredName),
        .statement_column_declared_type => _ = @TypeOf(Statement.columnDeclaredType),
        .statement_column_kind => _ = @TypeOf(Statement.columnKind),
        .statement_column_name => _ = @TypeOf(Statement.columnName),
        .statement_deinit => _ = @TypeOf(Statement.deinit),
        .statement_execute => _ = @TypeOf(Statement.execute),
        .statement_execute_progress => _ = @TypeOf(Statement.executeProgress),
        .statement_finalize => _ = @TypeOf(Statement.finalize),
        .statement_finalize_progress => _ = @TypeOf(Statement.finalizeProgress),
        .statement_changes => _ = @TypeOf(Statement.changes),
        .statement_named_position => _ = @TypeOf(Statement.namedPosition),
        .statement_parameter_name => _ = @TypeOf(Statement.parameterName),
        .statement_parameter_count => _ = @TypeOf(Statement.parameterCount),
        .statement_reset => _ = @TypeOf(Statement.reset),
        .statement_value => _ = @TypeOf(Statement.value),
        .statement_run_io => _ = @TypeOf(Statement.runIo),
        .statement_step => _ = @TypeOf(Statement.step),
        .statement_step_progress => _ = @TypeOf(Statement.stepProgress),
        .copy_and_free_diagnostic => _ = @TypeOf(errors.copyAndFreeDiagnostic),
        .version => _ = @TypeOf(setup.version),
        .aggregate_state_carrier => _ = @TypeOf(aggregate_function.StateBox(void)),
        .aggregate_final_trampoline => _ = @TypeOf(aggregate_function.finalTrampoline(void, void)),
        .aggregate_init_trampoline => _ = @TypeOf(aggregate_function.initTrampoline(void, void)),
        .aggregate_step_trampoline => _ = @TypeOf(aggregate_function.stepTrampoline(void, void)),
        .collation_compare_trampoline => _ = @TypeOf(collation.compareTrampoline(void)),
        .column_kind => _ = @TypeOf(statement.ColumnKind),
        .setup_config => _ = @TypeOf(setup.SetupConfig),
        .logger_trampoline => _ = @TypeOf(setup.loggerTrampoline),
        .connection_type => _ = @TypeOf(Connection),
        .scalar_context_destructor => _ = @TypeOf(connection.scalarContextDestructor(void)),
        .aggregate_context_destructor => _ = @TypeOf(aggregate_function.contextDestructor(void, void)),
        .aggregate_state_destructor => _ = @TypeOf(aggregate_function.stateDestructor(void, void)),
        .collation_context_destructor => _ = @TypeOf(collation.contextDestructor(void)),
        .database_config => _ = @TypeOf(Database.Config),
        .database_type => _ = @TypeOf(Database),
        .decode_callback_args => _ = @TypeOf(callback_value.decodeArgs),
        .managed_error => _ = @TypeOf(callback_value.ManagedError),
        .encode_callback_result => _ = @TypeOf(callback_value.encodeResult),
        .extension_result_code => _ = @TypeOf(callback_value.ExtensionResultCode),
        .extension_text_subtype => _ = @TypeOf(callback_value.ExtensionTextSubtype),
        .borrowed_text => _ = @TypeOf(callback_value.BorrowedText),
        .log => _ = @TypeOf(setup.Log),
        .scalar_trampoline => _ = @TypeOf(connection.scalarTrampoline(void)),
        .unused_slice_carrier => _ = @TypeOf(void),
        .statement_type => _ = @TypeOf(Statement),
        .status_to_error => _ = @TypeOf(errors.statusToError),
        .open_progress => _ = @TypeOf(progress.OpenProgress),
        .execute_progress => _ = @TypeOf(progress.ExecuteProgress),
        .step_progress => _ = @TypeOf(progress.StepProgress),
        .finalize_progress => _ = @TypeOf(progress.FinalizeProgress),
        .log_level => _ = @TypeOf(setup.LogLevel),
        .value => _ = @TypeOf(Value),
        .destroy_callback_result => _ = @TypeOf(callback_value.destroyResult),
    }
}

pub const AuditCounts = struct { missing: usize = 0, unexpected: usize = 0 };

pub fn auditNamespace(comptime Namespace: type, comptime expected_functions: []const FunctionRow, comptime expected_types: []const TypeRow) AuditCounts {
    var counts: AuditCounts = .{};
    inline for (expected_functions) |manifest_row| if (!@hasDecl(Namespace, manifest_row.name)) {
        counts.missing += 1;
    };
    inline for (expected_types) |manifest_row| if (!@hasDecl(Namespace, manifest_row.name)) {
        counts.missing += 1;
    };
    inline for (@typeInfo(Namespace).@"struct".decls) |decl| {
        if (comptime !std.mem.startsWith(u8, decl.name, "turso_")) continue;
        const value = @field(Namespace, decl.name);
        const is_public_function = comptime @typeInfo(@TypeOf(value)) == .@"fn";
        const is_public_type = comptime @TypeOf(value) == type and std.mem.endsWith(u8, decl.name, "_t");
        if (comptime !is_public_function and !is_public_type) continue;
        const rows = if (is_public_function) expected_functions else expected_types;
        var found = false;
        inline for (rows) |manifest_row| found = found or std.mem.eql(u8, manifest_row.name, decl.name);
        if (!found) counts.unexpected += 1;
    }
    return counts;
}

const DocumentError = error{DocumentMismatch};

fn validateDocumentRow(document: []const u8, manifest_row: FunctionRow) DocumentError!void {
    const name_offset = std.mem.indexOf(u8, document, manifest_row.name) orelse return error.DocumentMismatch;
    const line_start = std.mem.lastIndexOfScalar(u8, document[0..name_offset], '\n') orelse return error.DocumentMismatch;
    const line_end = std.mem.indexOfScalarPos(u8, document, name_offset, '\n') orelse return error.DocumentMismatch;
    var columns = std.mem.splitScalar(u8, document[line_start + 1 .. line_end], '|');
    _ = columns.next() orelse return error.DocumentMismatch;
    const raw_name = std.mem.trim(u8, columns.next() orelse return error.DocumentMismatch, " ");
    const disposition = std.mem.trim(u8, columns.next() orelse return error.DocumentMismatch, " ");
    const api_names = std.mem.trim(u8, columns.next() orelse return error.DocumentMismatch, " ");
    const rationale = std.mem.trim(u8, columns.next() orelse return error.DocumentMismatch, " ");
    const issue_or_exception = std.mem.trim(u8, columns.next() orelse return error.DocumentMismatch, " ");
    if (columns.next() == null or columns.next() != null) return error.DocumentMismatch;

    if (raw_name.len != manifest_row.name.len + 2 or raw_name[0] != '`' or raw_name[raw_name.len - 1] != '`') return error.DocumentMismatch;
    if (!std.mem.eql(u8, raw_name[1 .. raw_name.len - 1], manifest_row.name)) return error.DocumentMismatch;
    const disposition_name = @tagName(manifest_row.disposition);
    if (disposition.len != disposition_name.len + 2 or !std.mem.eql(u8, disposition[1 .. disposition.len - 1], disposition_name)) return error.DocumentMismatch;
    if (api_names.len < 2 or api_names[0] != '`' or api_names[api_names.len - 1] != '`') return error.DocumentMismatch;
    var documented_apis = std.mem.splitSequence(u8, api_names[1 .. api_names.len - 1], " / ");
    for (manifest_row.apis) |api| {
        if (!std.mem.eql(u8, documented_apis.next() orelse return error.DocumentMismatch, apiName(api))) return error.DocumentMismatch;
    }
    if (documented_apis.next() != null) return error.DocumentMismatch;
    if (!std.mem.eql(u8, rationale, manifest_row.rationale)) return error.DocumentMismatch;
    if (!std.mem.eql(u8, issue_or_exception, manifest_row.issue_or_exception)) return error.DocumentMismatch;
}

fn validateDocument(document: []const u8) DocumentError!void {
    if (std.mem.count(u8, document, "48 public functions") != 1) return error.DocumentMismatch;
    if (std.mem.count(u8, document, "27 public typedefs") != 1) return error.DocumentMismatch;
    inline for (functions) |manifest_row| try validateDocumentRow(document, manifest_row);
    inline for (types) |manifest_row| try validateDocumentRow(document, manifest_row);
    if (std.mem.count(u8, document, "| `turso_") != functions.len + types.len) return error.DocumentMismatch;
}

fn validateManifest() void {
    @setEvalBranchQuota(200_000);
    if (functions.len != 48) @compileError("ABI function manifest must contain 48 rows");
    if (types.len != 27) @compileError("ABI type manifest must contain 27 rows");
    inline for (functions, 0..) |manifest_row, index| {
        if (manifest_row.rationale.len == 0 or manifest_row.issue_or_exception.len == 0) @compileError("empty ABI function disposition");
        if (index > 0 and std.mem.order(u8, functions[index - 1].name, manifest_row.name) != .lt) @compileError("ABI function manifest is unsorted or duplicated");
        _ = @TypeOf(@field(c, manifest_row.name));
        inline for (manifest_row.apis) |api| validateApiReference(api);
    }
    inline for (types, 0..) |manifest_row, index| {
        if (manifest_row.rationale.len == 0 or manifest_row.issue_or_exception.len == 0) @compileError("empty ABI type disposition");
        if (index > 0 and std.mem.order(u8, types[index - 1].name, manifest_row.name) != .lt) @compileError("ABI type manifest is unsorted or duplicated");
        _ = @TypeOf(@field(c, manifest_row.name));
        inline for (manifest_row.apis) |api| validateApiReference(api);
    }
    const counts = auditNamespace(c, &functions, &types);
    if (counts.missing != 0 or counts.unexpected != 0) @compileError("Turso public ABI declarations do not exactly match the parity manifest");
    c_api.validateAbi();
}

comptime {
    validateManifest();
}

test "documentation is exactly derived from the manifest" {
    @setEvalBranchQuota(200_000);
    try validateDocument(@embedFile("abi-parity-doc"));
}

test "synthetic namespace mismatch detects missing and extra functions and typedefs" {
    const Empty = struct {};
    const ExtraFunction = struct {
        pub fn turso_extra() callconv(.c) void {}
    };
    const ExtraType = struct {
        pub const turso_extra_t = opaque {};
    };
    const missing_function = auditNamespace(Empty, functions[0..1], &.{});
    try std.testing.expectEqual(@as(usize, 1), missing_function.missing);
    try std.testing.expectEqual(@as(usize, 0), missing_function.unexpected);
    const extra_function = auditNamespace(ExtraFunction, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), extra_function.missing);
    try std.testing.expectEqual(@as(usize, 1), extra_function.unexpected);

    const missing_type = auditNamespace(Empty, &.{}, types[0..1]);
    try std.testing.expectEqual(@as(usize, 1), missing_type.missing);
    try std.testing.expectEqual(@as(usize, 0), missing_type.unexpected);
    const extra_type = auditNamespace(ExtraType, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), extra_type.missing);
    try std.testing.expectEqual(@as(usize, 1), extra_type.unexpected);
}

test "documentation validation rejects any changed manifest cell" {
    const document = @embedFile("abi-parity-doc");
    const offset = std.mem.indexOf(u8, document, "Checked close ordering") orelse return error.TestExpectedEqual;
    const drifted = try std.testing.allocator.dupe(u8, document);
    defer std.testing.allocator.free(drifted);
    drifted[offset] = 'X';
    try std.testing.expectError(error.DocumentMismatch, validateDocument(drifted));
}
