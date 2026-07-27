const std = @import("std");
const c = @import("c_api.zig").raw;

pub const max_callback_args: usize = 127;
pub const max_result_backing: usize = 16 * 1024 * 1024;

pub const ExtensionResultCode = enum(c_uint) {
    ok = 0,
    error_code = 1,
    invalid_args = 2,
    unknown = 3,
    out_of_memory = 4,
    corrupt = 5,
    not_found = 6,
    already_exists = 7,
    permission_denied = 8,
    aborted = 9,
    out_of_range = 10,
    unimplemented = 11,
    internal = 12,
    unavailable = 13,
    custom_error = 14,
    end_of_file = 15,
    read_only = 16,
    row_id = 17,
    row = 18,
    interrupt = 19,
    busy = 20,
    constraint_violation = 21,
};

pub const ExtensionTextSubtype = enum(c_uint) {
    text = 0,
    json = 1,
};

pub const BorrowedText = struct {
    subtype: ExtensionTextSubtype,
    bytes: []const u8,
};

pub const ManagedError = struct {
    code: ExtensionResultCode,
    message: ?[]const u8 = null,
};

pub const BorrowedCallbackValue = union(enum) {
    null,
    integer: i64,
    float: f64,
    text: BorrowedText,
    blob: []const u8,
    managed_error: ManagedError,
};

pub const CallbackArgs = struct {
    values: []const BorrowedCallbackValue,
};

pub const CallbackResult = union(enum) {
    null,
    integer: i64,
    float: f64,
    text: BorrowedText,
    blob: []const u8,
    managed_error: ManagedError,
};

pub const Arity = union(enum) {
    fixed: u8,
    variadic,
};

pub fn ScalarFunction(comptime Context: type) type {
    return struct {
        context: Context,
        call: *const fn (context: *Context, args: CallbackArgs) CallbackResult,
        deinit: ?*const fn (context: *Context) void = null,
    };
}

pub const DecodeError = error{
    InvalidArgumentCount,
    MissingArguments,
    UnknownValueType,
    MissingValueBacking,
    OversizeValue,
    InvalidUtf8,
    UnknownTextSubtype,
    UnknownResultCode,
};

pub fn decodeArgs(
    argc: c_int,
    argv: [*c]const c.turso_value_t,
    storage: *[max_callback_args]BorrowedCallbackValue,
) DecodeError!CallbackArgs {
    if (argc < 0) return DecodeError.InvalidArgumentCount;
    const count = std.math.cast(usize, argc) orelse return DecodeError.InvalidArgumentCount;
    if (count > storage.len) return DecodeError.InvalidArgumentCount;
    if (count != 0 and argv == null) return DecodeError.MissingArguments;

    for (0..count) |index| storage[index] = try decodeValue(argv[index]);
    return .{ .values = storage[0..count] };
}

fn decodeValue(raw: c.turso_value_t) DecodeError!BorrowedCallbackValue {
    return switch (raw.value_type) {
        c.TURSO_EXTENSION_VALUE_NULL => .null,
        c.TURSO_EXTENSION_VALUE_INTEGER => .{ .integer = raw.value.int_value },
        c.TURSO_EXTENSION_VALUE_FLOAT => .{ .float = raw.value.float_value },
        c.TURSO_EXTENSION_VALUE_TEXT => value: {
            const text = raw.value.text;
            if (text == null) return DecodeError.MissingValueBacking;
            const len: usize = text.*.len;
            if (len > max_result_backing) return DecodeError.OversizeValue;
            const bytes = try checkedBytes(text.*.text, len);
            if (!std.unicode.utf8ValidateSlice(bytes)) return DecodeError.InvalidUtf8;
            const subtype = try decodeTextSubtype(text.*.subtype);
            break :value .{ .text = .{ .subtype = subtype, .bytes = bytes } };
        },
        c.TURSO_EXTENSION_VALUE_BLOB => value: {
            const blob = raw.value.blob;
            if (blob == null) return DecodeError.MissingValueBacking;
            const len = std.math.cast(usize, blob.*.size) orelse return DecodeError.OversizeValue;
            if (len > max_result_backing) return DecodeError.OversizeValue;
            break :value .{ .blob = try checkedBytes(blob.*.data, len) };
        },
        c.TURSO_EXTENSION_VALUE_ERROR => value: {
            const managed_error = raw.value.@"error";
            if (managed_error == null) return DecodeError.MissingValueBacking;
            const code = try decodeResultCode(managed_error.*.code);
            const message = if (managed_error.*.message == null)
                null
            else message: {
                const text = managed_error.*.message;
                const len: usize = text.*.len;
                if (len > max_result_backing) return DecodeError.OversizeValue;
                if (try decodeTextSubtype(text.*.subtype) != .text) return DecodeError.UnknownTextSubtype;
                const bytes = try checkedBytes(text.*.text, len);
                if (!std.unicode.utf8ValidateSlice(bytes)) return DecodeError.InvalidUtf8;
                break :message bytes;
            };
            break :value .{ .managed_error = .{ .code = code, .message = message } };
        },
        else => DecodeError.UnknownValueType,
    };
}

fn checkedBytes(pointer: [*c]const u8, len: usize) DecodeError![]const u8 {
    if (len == 0) return &.{};
    if (pointer == null) return DecodeError.MissingValueBacking;
    return pointer[0..len];
}

fn decodeTextSubtype(raw: c.turso_extension_text_subtype_t) DecodeError!ExtensionTextSubtype {
    return switch (raw) {
        c.TURSO_EXTENSION_TEXT_TEXT => .text,
        c.TURSO_EXTENSION_TEXT_JSON => .json,
        else => DecodeError.UnknownTextSubtype,
    };
}

fn decodeResultCode(raw: c.turso_extension_result_code_t) DecodeError!ExtensionResultCode {
    return switch (raw) {
        inline 0...21 => |value| @enumFromInt(value),
        else => DecodeError.UnknownResultCode,
    };
}

const TextBacking = struct {
    abi: c.turso_extension_text_t,
    allocator: std.mem.Allocator,
    bytes: []u8,
};

const BlobBacking = struct {
    abi: c.turso_extension_blob_t,
    allocator: std.mem.Allocator,
    bytes: []u8,
};

const ErrorBacking = struct {
    abi: c.turso_extension_error_t,
    allocator: std.mem.Allocator,
    message: ?*TextBacking,
};

var oom_error = c.turso_extension_error_t{ .code = c.TURSO_EXTENSION_RESULT_OOM, .message = null };
var invalid_args_error = c.turso_extension_error_t{ .code = c.TURSO_EXTENSION_RESULT_INVALID_ARGS, .message = null };
var out_of_range_error = c.turso_extension_error_t{ .code = c.TURSO_EXTENSION_RESULT_OUT_OF_RANGE, .message = null };

pub fn encodeResult(allocator: std.mem.Allocator, result: CallbackResult) c.turso_value_t {
    return switch (result) {
        .null => rawNull(),
        .integer => |value| .{
            .value_type = c.TURSO_EXTENSION_VALUE_INTEGER,
            .value = .{ .int_value = value },
        },
        .float => |value| .{
            .value_type = c.TURSO_EXTENSION_VALUE_FLOAT,
            .value = .{ .float_value = value },
        },
        .text => |value| encodeText(allocator, value) catch |err| allocationFailure(err),
        .blob => |value| encodeBlob(allocator, value) catch |err| allocationFailure(err),
        .managed_error => |value| encodeError(allocator, value) catch |err| allocationFailure(err),
    };
}

pub fn encodeBoundaryFailure(code: ExtensionResultCode) c.turso_value_t {
    return staticError(switch (code) {
        .out_of_range => &out_of_range_error,
        .out_of_memory => &oom_error,
        else => &invalid_args_error,
    });
}

const EncodeError = error{ OutOfMemory, Oversize, InvalidUtf8 };

fn encodeText(allocator: std.mem.Allocator, text: BorrowedText) EncodeError!c.turso_value_t {
    if (text.bytes.len > max_result_backing or text.bytes.len > std.math.maxInt(u32)) return EncodeError.Oversize;
    if (!std.unicode.utf8ValidateSlice(text.bytes)) return EncodeError.InvalidUtf8;
    const backing = allocator.create(TextBacking) catch return EncodeError.OutOfMemory;
    errdefer allocator.destroy(backing);
    const bytes = allocator.dupe(u8, text.bytes) catch return EncodeError.OutOfMemory;
    backing.* = .{
        .abi = .{
            .subtype = @intFromEnum(text.subtype),
            .text = if (bytes.len == 0) null else bytes.ptr,
            .len = @intCast(bytes.len),
        },
        .allocator = allocator,
        .bytes = bytes,
    };
    return .{ .value_type = c.TURSO_EXTENSION_VALUE_TEXT, .value = .{ .text = &backing.abi } };
}

fn encodeBlob(allocator: std.mem.Allocator, value: []const u8) EncodeError!c.turso_value_t {
    if (value.len > max_result_backing) return EncodeError.Oversize;
    const backing = allocator.create(BlobBacking) catch return EncodeError.OutOfMemory;
    errdefer allocator.destroy(backing);
    const bytes = allocator.dupe(u8, value) catch return EncodeError.OutOfMemory;
    backing.* = .{
        .abi = .{ .data = if (bytes.len == 0) null else bytes.ptr, .size = bytes.len },
        .allocator = allocator,
        .bytes = bytes,
    };
    return .{ .value_type = c.TURSO_EXTENSION_VALUE_BLOB, .value = .{ .blob = &backing.abi } };
}

fn encodeError(allocator: std.mem.Allocator, value: ManagedError) EncodeError!c.turso_value_t {
    const backing = allocator.create(ErrorBacking) catch return EncodeError.OutOfMemory;
    errdefer allocator.destroy(backing);
    var message: ?*TextBacking = null;
    errdefer if (message) |text| destroyText(&text.abi);
    if (value.message) |bytes| {
        const encoded = try encodeText(allocator, .{ .subtype = .text, .bytes = bytes });
        const abi: *c.turso_extension_text_t = @ptrCast(@constCast(encoded.value.text));
        message = @fieldParentPtr("abi", abi);
    }
    backing.* = .{
        .abi = .{
            .code = @intFromEnum(value.code),
            .message = if (message) |text| &text.abi else null,
        },
        .allocator = allocator,
        .message = message,
    };
    return .{ .value_type = c.TURSO_EXTENSION_VALUE_ERROR, .value = .{ .@"error" = &backing.abi } };
}

fn allocationFailure(err: EncodeError) c.turso_value_t {
    return switch (err) {
        error.OutOfMemory => staticError(&oom_error),
        error.Oversize => staticError(&out_of_range_error),
        error.InvalidUtf8 => staticError(&invalid_args_error),
    };
}

fn staticError(backing: *c.turso_extension_error_t) c.turso_value_t {
    return .{ .value_type = c.TURSO_EXTENSION_VALUE_ERROR, .value = .{ .@"error" = backing } };
}

fn rawNull() c.turso_value_t {
    return .{ .value_type = c.TURSO_EXTENSION_VALUE_NULL, .value = .{ .int_value = 0 } };
}

pub fn destroyResult(result: [*c]c.turso_value_t) callconv(.c) void {
    if (result == null) return;
    switch (result.*.value_type) {
        c.TURSO_EXTENSION_VALUE_TEXT => destroyText(result.*.value.text),
        c.TURSO_EXTENSION_VALUE_BLOB => {
            const abi = result.*.value.blob;
            if (abi == null) return;
            const abi_pointer: *c.turso_extension_blob_t = @ptrCast(@constCast(abi));
            const backing: *BlobBacking = @fieldParentPtr("abi", abi_pointer);
            const allocator = backing.allocator;
            allocator.free(backing.bytes);
            allocator.destroy(backing);
        },
        c.TURSO_EXTENSION_VALUE_ERROR => {
            const abi = result.*.value.@"error";
            if (abi == null or abi == &oom_error or abi == &invalid_args_error or abi == &out_of_range_error) return;
            const abi_pointer: *c.turso_extension_error_t = @ptrCast(@constCast(abi));
            const backing: *ErrorBacking = @fieldParentPtr("abi", abi_pointer);
            const allocator = backing.allocator;
            if (backing.message) |message| destroyText(&message.abi);
            allocator.destroy(backing);
        },
        else => {},
    }
}

fn destroyText(abi: [*c]const c.turso_extension_text_t) void {
    if (abi == null) return;
    const abi_pointer: *c.turso_extension_text_t = @ptrCast(@constCast(abi));
    const backing: *TextBacking = @fieldParentPtr("abi", abi_pointer);
    const allocator = backing.allocator;
    allocator.free(backing.bytes);
    allocator.destroy(backing);
}

test "callback codec copies all managed result backing and frees it once" {
    const allocator = std.testing.allocator;
    const results = [_]CallbackResult{
        .{ .text = .{ .subtype = .text, .bytes = "a\x00b" } },
        .{ .text = .{ .subtype = .json, .bytes = "{\"a\":1}" } },
        .{ .blob = &.{ 0, 1, 255 } },
        .{ .text = .{ .subtype = .text, .bytes = "" } },
        .{ .blob = &.{} },
        .{ .managed_error = .{ .code = .custom_error, .message = "failure" } },
    };
    for (results) |result| {
        var raw = encodeResult(allocator, result);
        destroyResult(&raw);
    }
}

test "callback codec round trips every managed error result code" {
    var storage: [max_callback_args]BorrowedCallbackValue = undefined;
    inline for (@typeInfo(ExtensionResultCode).@"enum".fields) |field| {
        var raw = encodeResult(std.testing.allocator, .{ .managed_error = .{
            .code = @enumFromInt(field.value),
            .message = null,
        } });
        defer destroyResult(&raw);
        const args = try decodeArgs(1, @ptrCast(&raw), &storage);
        try std.testing.expectEqual(@as(usize, 1), args.values.len);
        try std.testing.expectEqual(@as(ExtensionResultCode, @enumFromInt(field.value)), args.values[0].managed_error.code);
        try std.testing.expect(args.values[0].managed_error.message == null);
    }
}

test "callback codec turns allocation and oversize failures into static errors" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var oom = encodeResult(failing.allocator(), .{ .text = .{ .subtype = .text, .bytes = "x" } });
    try std.testing.expectEqual(@as(c_uint, c.TURSO_EXTENSION_RESULT_OOM), oom.value.@"error".*.code);
    destroyResult(&oom);

    const fake: [*]const u8 = @ptrFromInt(@alignOf(u8));
    var oversize = encodeResult(std.testing.allocator, .{ .blob = fake[0 .. max_result_backing + 1] });
    try std.testing.expectEqual(@as(c_uint, c.TURSO_EXTENSION_RESULT_OUT_OF_RANGE), oversize.value.@"error".*.code);
    destroyResult(&oversize);
}

test "callback decoder rejects malformed pointers lengths utf8 and unknown tags" {
    var storage: [max_callback_args]BorrowedCallbackValue = undefined;
    try std.testing.expectError(error.InvalidArgumentCount, decodeArgs(-1, null, &storage));
    try std.testing.expectError(error.MissingArguments, decodeArgs(1, null, &storage));
    try std.testing.expectError(error.InvalidArgumentCount, decodeArgs(max_callback_args + 1, null, &storage));

    var raw = rawNull();
    raw.value_type = std.math.maxInt(c_uint);
    try std.testing.expectError(error.UnknownValueType, decodeArgs(1, @ptrCast(&raw), &storage));
    raw.value_type = c.TURSO_EXTENSION_VALUE_TEXT;
    raw.value.text = null;
    try std.testing.expectError(error.MissingValueBacking, decodeArgs(1, @ptrCast(&raw), &storage));

    var bad_bytes = [_]u8{0xff};
    var bad_text = c.turso_extension_text_t{
        .subtype = c.TURSO_EXTENSION_TEXT_TEXT,
        .text = &bad_bytes,
        .len = bad_bytes.len,
    };
    raw.value.text = &bad_text;
    try std.testing.expectError(error.InvalidUtf8, decodeArgs(1, @ptrCast(&raw), &storage));
    bad_text.subtype = 99;
    bad_text.len = 0;
    try std.testing.expectError(error.UnknownTextSubtype, decodeArgs(1, @ptrCast(&raw), &storage));
    bad_text.subtype = c.TURSO_EXTENSION_TEXT_TEXT;
    bad_text.len = max_result_backing + 1;
    try std.testing.expectError(error.OversizeValue, decodeArgs(1, @ptrCast(&raw), &storage));

    raw.value_type = c.TURSO_EXTENSION_VALUE_BLOB;
    raw.value.blob = null;
    try std.testing.expectError(error.MissingValueBacking, decodeArgs(1, @ptrCast(&raw), &storage));
    var bad_blob = c.turso_extension_blob_t{ .data = null, .size = 1 };
    raw.value.blob = &bad_blob;
    try std.testing.expectError(error.MissingValueBacking, decodeArgs(1, @ptrCast(&raw), &storage));
    bad_blob.size = max_result_backing + 1;
    try std.testing.expectError(error.OversizeValue, decodeArgs(1, @ptrCast(&raw), &storage));

    raw.value_type = c.TURSO_EXTENSION_VALUE_ERROR;
    raw.value.@"error" = null;
    try std.testing.expectError(error.MissingValueBacking, decodeArgs(1, @ptrCast(&raw), &storage));
    var bad_error = c.turso_extension_error_t{ .code = 99, .message = null };
    raw.value.@"error" = &bad_error;
    try std.testing.expectError(error.UnknownResultCode, decodeArgs(1, @ptrCast(&raw), &storage));
    bad_error.code = c.TURSO_EXTENSION_RESULT_ERROR;
    bad_error.message = &bad_text;
    bad_text.subtype = c.TURSO_EXTENSION_TEXT_JSON;
    bad_text.len = 0;
    try std.testing.expectError(error.UnknownTextSubtype, decodeArgs(1, @ptrCast(&raw), &storage));
}
