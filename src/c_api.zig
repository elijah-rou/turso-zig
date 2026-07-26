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

    assertConstant("TURSO_TYPE_UNKNOWN", raw.TURSO_TYPE_UNKNOWN, 0);
    assertConstant("TURSO_TYPE_INTEGER", raw.TURSO_TYPE_INTEGER, 1);
    assertConstant("TURSO_TYPE_REAL", raw.TURSO_TYPE_REAL, 2);
    assertConstant("TURSO_TYPE_TEXT", raw.TURSO_TYPE_TEXT, 3);
    assertConstant("TURSO_TYPE_BLOB", raw.TURSO_TYPE_BLOB, 4);
    assertConstant("TURSO_TYPE_NULL", raw.TURSO_TYPE_NULL, 5);

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
