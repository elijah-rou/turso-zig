const std = @import("std");

const sdk_kit = @cImport({
    @cInclude("turso.h");
});

comptime {
    std.debug.assert(sdk_kit.TURSO_OK == 0);
    std.debug.assert(sdk_kit.TURSO_IOERR == 134);
}
