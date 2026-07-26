const std = @import("std");

/// A row value. Text and blob variants own their bytes.
pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []u8,
    blob: []u8,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |bytes| allocator.free(bytes),
            .blob => |bytes| allocator.free(bytes),
            .null, .integer, .real => {},
        }
        self.* = .null;
    }
};
