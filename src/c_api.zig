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
