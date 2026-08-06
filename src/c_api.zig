const std = @import("std");

pub const raw = @cImport({
    @cInclude("turso.h");
});

comptime {
    assertConstant("TURSO_OK", raw.TURSO_OK, 0);
    assertConstant("TURSO_DONE", raw.TURSO_DONE, 1);
    assertConstant("TURSO_ROW", raw.TURSO_ROW, 2);
    assertConstant("TURSO_IO", raw.TURSO_IO, 3);
    assertConstant("TURSO_BUSY", raw.TURSO_BUSY, 4);
    assertConstant("TURSO_INTERRUPT", raw.TURSO_INTERRUPT, 5);
    assertConstant("TURSO_BUSY_SNAPSHOT", raw.TURSO_BUSY_SNAPSHOT, 6);
    assertConstant("TURSO_ERROR", raw.TURSO_ERROR, 127);
    assertConstant("TURSO_MISUSE", raw.TURSO_MISUSE, 128);
    assertConstant("TURSO_CONSTRAINT", raw.TURSO_CONSTRAINT, 129);
    assertConstant("TURSO_READONLY", raw.TURSO_READONLY, 130);
    assertConstant("TURSO_DATABASE_FULL", raw.TURSO_DATABASE_FULL, 131);
    assertConstant("TURSO_NOTADB", raw.TURSO_NOTADB, 132);
    assertConstant("TURSO_CORRUPT", raw.TURSO_CORRUPT, 133);
    assertConstant("TURSO_IOERR", raw.TURSO_IOERR, 134);

    assertConstant("TURSO_TRACING_LEVEL_ERROR", raw.TURSO_TRACING_LEVEL_ERROR, 1);
    assertConstant("TURSO_TRACING_LEVEL_WARN", raw.TURSO_TRACING_LEVEL_WARN, 2);
    assertConstant("TURSO_TRACING_LEVEL_INFO", raw.TURSO_TRACING_LEVEL_INFO, 3);
    assertConstant("TURSO_TRACING_LEVEL_DEBUG", raw.TURSO_TRACING_LEVEL_DEBUG, 4);
    assertConstant("TURSO_TRACING_LEVEL_TRACE", raw.TURSO_TRACING_LEVEL_TRACE, 5);

    assertConstant("TURSO_TYPE_UNKNOWN", raw.TURSO_TYPE_UNKNOWN, 0);
    assertConstant("TURSO_TYPE_INTEGER", raw.TURSO_TYPE_INTEGER, 1);
    assertConstant("TURSO_TYPE_REAL", raw.TURSO_TYPE_REAL, 2);
    assertConstant("TURSO_TYPE_TEXT", raw.TURSO_TYPE_TEXT, 3);
    assertConstant("TURSO_TYPE_BLOB", raw.TURSO_TYPE_BLOB, 4);
    assertConstant("TURSO_TYPE_NULL", raw.TURSO_TYPE_NULL, 5);

    assertConstant("TURSO_EXTENSION_VALUE_NULL", raw.TURSO_EXTENSION_VALUE_NULL, 0);
    assertConstant("TURSO_EXTENSION_VALUE_INTEGER", raw.TURSO_EXTENSION_VALUE_INTEGER, 1);
    assertConstant("TURSO_EXTENSION_VALUE_FLOAT", raw.TURSO_EXTENSION_VALUE_FLOAT, 2);
    assertConstant("TURSO_EXTENSION_VALUE_TEXT", raw.TURSO_EXTENSION_VALUE_TEXT, 3);
    assertConstant("TURSO_EXTENSION_VALUE_BLOB", raw.TURSO_EXTENSION_VALUE_BLOB, 4);
    assertConstant("TURSO_EXTENSION_VALUE_ERROR", raw.TURSO_EXTENSION_VALUE_ERROR, 5);
    for (.{
        raw.TURSO_EXTENSION_RESULT_OK,
        raw.TURSO_EXTENSION_RESULT_ERROR,
        raw.TURSO_EXTENSION_RESULT_INVALID_ARGS,
        raw.TURSO_EXTENSION_RESULT_UNKNOWN,
        raw.TURSO_EXTENSION_RESULT_OOM,
        raw.TURSO_EXTENSION_RESULT_CORRUPT,
        raw.TURSO_EXTENSION_RESULT_NOT_FOUND,
        raw.TURSO_EXTENSION_RESULT_ALREADY_EXISTS,
        raw.TURSO_EXTENSION_RESULT_PERMISSION_DENIED,
        raw.TURSO_EXTENSION_RESULT_ABORTED,
        raw.TURSO_EXTENSION_RESULT_OUT_OF_RANGE,
        raw.TURSO_EXTENSION_RESULT_UNIMPLEMENTED,
        raw.TURSO_EXTENSION_RESULT_INTERNAL,
        raw.TURSO_EXTENSION_RESULT_UNAVAILABLE,
        raw.TURSO_EXTENSION_RESULT_CUSTOM_ERROR,
        raw.TURSO_EXTENSION_RESULT_EOF,
        raw.TURSO_EXTENSION_RESULT_READ_ONLY,
        raw.TURSO_EXTENSION_RESULT_ROWID,
        raw.TURSO_EXTENSION_RESULT_ROW,
        raw.TURSO_EXTENSION_RESULT_INTERRUPT,
        raw.TURSO_EXTENSION_RESULT_BUSY,
        raw.TURSO_EXTENSION_RESULT_CONSTRAINT_VIOLATION,
    }, 0..) |actual, expected| assertConstant("TURSO_EXTENSION_RESULT_*", actual, expected);
    assertConstant("TURSO_EXTENSION_TEXT_TEXT", raw.TURSO_EXTENSION_TEXT_TEXT, 0);
    assertConstant("TURSO_EXTENSION_TEXT_JSON", raw.TURSO_EXTENSION_TEXT_JSON, 1);

    if (@offsetOf(raw.turso_value_t, "value_type") != 0 or
        @offsetOf(raw.turso_value_t, "value") < @sizeOf(raw.turso_extension_value_type_t) or
        @sizeOf(raw.turso_extension_value_data_t) != 8 or
        @sizeOf(raw.turso_value_t) != 16)
    {
        @compileError("Turso SDK Kit 0.7.1 callback value layout mismatch");
    }
    const scalar_pointer = @typeInfo(raw.turso_scalar_function_t).optional.child;
    const scalar_signature = @typeInfo(@typeInfo(scalar_pointer).pointer.child).@"fn";
    if (@sizeOf(raw.turso_context_destructor_t) != @sizeOf(?*const anyopaque) or
        @sizeOf(raw.turso_value_destructor_t) != @sizeOf(?*const anyopaque) or
        scalar_signature.params.len != 5 or
        @sizeOf(scalar_signature.params[0].type.?) != @sizeOf(usize) or
        @sizeOf(scalar_signature.params[1].type.?) != @sizeOf(c_int) or
        @sizeOf(scalar_signature.params[2].type.?) != @sizeOf([*c]const raw.turso_value_t) or
        @sizeOf(scalar_signature.params[3].type.?) != @sizeOf(raw.turso_context_destructor_t) or
        @sizeOf(scalar_signature.params[4].type.?) != @sizeOf(raw.turso_value_destructor_t) or
        scalar_signature.return_type.? != raw.turso_value_t)
    {
        @compileError("Turso SDK Kit 0.7.1 callback signature mismatch");
    }

    const database_open_signature = @typeInfo(@TypeOf(raw.turso_database_open)).@"fn";
    const statement_execute_signature = @typeInfo(@TypeOf(raw.turso_statement_execute)).@"fn";
    const statement_step_signature = @typeInfo(@TypeOf(raw.turso_statement_step)).@"fn";
    const statement_run_io_signature = @typeInfo(@TypeOf(raw.turso_statement_run_io)).@"fn";
    const statement_finalize_signature = @typeInfo(@TypeOf(raw.turso_statement_finalize)).@"fn";
    if (database_open_signature.params.len != 2 or
        database_open_signature.return_type.? != raw.turso_status_code_t or
        statement_execute_signature.params.len != 3 or
        statement_execute_signature.return_type.? != raw.turso_status_code_t or
        statement_step_signature.params.len != 2 or
        statement_step_signature.return_type.? != raw.turso_status_code_t or
        statement_run_io_signature.params.len != 2 or
        statement_run_io_signature.return_type.? != raw.turso_status_code_t or
        statement_finalize_signature.params.len != 2 or
        statement_finalize_signature.return_type.? != raw.turso_status_code_t)
    {
        @compileError("Turso SDK Kit 0.7.1 I/O progress signature mismatch");
    }

    const extension_gate_signature = @typeInfo(@TypeOf(raw.turso_connection_enable_load_extension)).@"fn";
    const extension_load_signature = @typeInfo(@TypeOf(raw.turso_connection_load_extension)).@"fn";
    if (extension_gate_signature.params.len != 3 or
        @sizeOf(extension_gate_signature.params[0].type.?) != @sizeOf(?*const anyopaque) or
        extension_gate_signature.params[1].type.? != bool or
        @sizeOf(extension_gate_signature.params[2].type.?) != @sizeOf(?*anyopaque) or
        extension_gate_signature.return_type.? != raw.turso_status_code_t or
        extension_load_signature.params.len != 3 or
        @sizeOf(extension_load_signature.params[0].type.?) != @sizeOf(?*const anyopaque) or
        @sizeOf(extension_load_signature.params[1].type.?) != @sizeOf(?*const anyopaque) or
        @sizeOf(extension_load_signature.params[2].type.?) != @sizeOf(?*anyopaque) or
        extension_load_signature.return_type.? != raw.turso_status_code_t)
    {
        @compileError("Turso SDK Kit 0.7.1 extension-control signature mismatch");
    }

    const collation_pointer = @typeInfo(raw.turso_collation_function_t).optional.child;
    const collation_signature = @typeInfo(@typeInfo(collation_pointer).pointer.child).@"fn";
    if (collation_signature.params.len != 5 or
        @sizeOf(collation_signature.params[0].type.?) != @sizeOf(usize) or
        @sizeOf(collation_signature.params[1].type.?) != @sizeOf([*c]const u8) or
        @sizeOf(collation_signature.params[2].type.?) != @sizeOf(usize) or
        @sizeOf(collation_signature.params[3].type.?) != @sizeOf([*c]const u8) or
        @sizeOf(collation_signature.params[4].type.?) != @sizeOf(usize) or
        @sizeOf(collation_signature.return_type.?) != @sizeOf(c_int))
    {
        @compileError("Turso SDK Kit 0.7.1 collation callback signature mismatch");
    }

    const aggregate_init_pointer = @typeInfo(raw.turso_aggregate_init_function_t).optional.child;
    const aggregate_step_pointer = @typeInfo(raw.turso_aggregate_step_function_t).optional.child;
    const aggregate_final_pointer = @typeInfo(raw.turso_aggregate_final_function_t).optional.child;
    const aggregate_init_signature = @typeInfo(@typeInfo(aggregate_init_pointer).pointer.child).@"fn";
    const aggregate_step_signature = @typeInfo(@typeInfo(aggregate_step_pointer).pointer.child).@"fn";
    const aggregate_final_signature = @typeInfo(@typeInfo(aggregate_final_pointer).pointer.child).@"fn";
    if (@sizeOf(raw.turso_agg_ctx_t) != @sizeOf(?*anyopaque) or
        @offsetOf(raw.turso_agg_ctx_t, "state") != 0 or
        aggregate_init_signature.params.len != 1 or
        aggregate_init_signature.return_type.? != [*c]raw.turso_agg_ctx_t or
        aggregate_step_signature.params.len != 4 or
        aggregate_step_signature.params[1].type.? != [*c]raw.turso_agg_ctx_t or
        aggregate_step_signature.return_type.? != raw.turso_value_t or
        aggregate_final_signature.params.len != 2 or
        aggregate_final_signature.params[1].type.? != [*c]raw.turso_agg_ctx_t or
        aggregate_final_signature.return_type.? != raw.turso_value_t)
    {
        @compileError("Turso SDK Kit 0.7.1 aggregate callback signature/layout mismatch");
    }

    assertConstant("TURSO_COLUMN_KIND_NONE", raw.TURSO_COLUMN_KIND_NONE, -1);
    assertConstant("TURSO_COLUMN_KIND_BUILTIN", raw.TURSO_COLUMN_KIND_BUILTIN, 0);
    assertConstant("TURSO_COLUMN_KIND_CUSTOM", raw.TURSO_COLUMN_KIND_CUSTOM, 1);
    assertConstant("TURSO_COLUMN_KIND_DOMAIN", raw.TURSO_COLUMN_KIND_DOMAIN, 2);
    assertConstant("TURSO_COLUMN_KIND_STRUCT", raw.TURSO_COLUMN_KIND_STRUCT, 3);
    assertConstant("TURSO_COLUMN_KIND_UNION", raw.TURSO_COLUMN_KIND_UNION, 4);
}

fn assertConstant(comptime name: []const u8, actual: c_int, expected: c_int) void {
    if (actual != expected) {
        @compileError(std.fmt.comptimePrint(
            "Turso SDK Kit 0.7.1 ABI mismatch: {s} is {d}, expected {d}",
            .{ name, actual, expected },
        ));
    }
}
