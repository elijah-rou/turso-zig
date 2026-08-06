const std = @import("std");

/// Raw Turso SDK Kit 0.7.1 C bindings. This namespace is unstable.
pub const c = @import("c_api.zig").raw;

pub const abi_version = "0.7.1";

/// Returns whether a native library version belongs to the pinned 0.7.1 ABI.
pub fn isAbiCompatibleVersion(version: []const u8) bool {
    if (!std.mem.startsWith(u8, version, abi_version)) return false;
    if (version.len == abi_version.len) return true;

    return switch (version[abi_version.len]) {
        '-', '+' => true,
        else => false,
    };
}
