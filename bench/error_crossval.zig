const bcs = @import("bcs");
const std = @import("std");

const TinyEnum = union(enum) {
    Unit,
    Value: u64,
};

const Nested = struct {
    id: u16,
    names: []const bcs.String,
    flag: bool,
};

fn errName(err: bcs.Error) []const u8 {
    return switch (err) {
        error.UnexpectedEndOfInput => "eof",
        error.SequenceTooLong => "sequence_too_long",
        error.ContainerTooDeep => "container_too_deep",
        error.InvalidBool => "invalid_bool",
        error.NonCanonicalMap => "non_canonical_map",
        error.InvalidOptionTag => "invalid_option_tag",
        error.TrailingBytes => "trailing_bytes",
        error.Utf8 => "utf8",
        error.NonCanonicalUleb128 => "non_canonical_uleb128",
        error.Uleb128Overflow => "uleb128_overflow",
        error.NotSupported => "not_supported",
        error.InvalidEnumTag => "invalid_enum_tag",
        error.OutOfMemory => "out_of_memory",
    };
}

fn emitStatus(comptime T: type, allocator: std.mem.Allocator, name: []const u8, raw: []const u8) void {
    const value = bcs.deserialize(T, allocator, raw) catch |err| {
        std.debug.print("{s}=err:{s}\n", .{ name, errName(err) });
        return;
    };
    defer bcs.freeDeserialized(T, allocator, value);
    std.debug.print("{s}=ok\n", .{name});
}

fn emitPrefixCases(comptime T: type, allocator: std.mem.Allocator, base_name: []const u8, value: T) !void {
    const bytes = try bcs.serialize(allocator, value);
    defer allocator.free(bytes);

    {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_full", .{base_name});
        emitStatus(T, allocator, name, bytes);
    }

    for (0..bytes.len) |i| {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_prefix_{d:0>3}", .{ base_name, i });
        emitStatus(T, allocator, name, bytes[0..i]);
    }

    const trailing = try allocator.alloc(u8, bytes.len + 1);
    defer allocator.free(trailing);
    @memcpy(trailing[0..bytes.len], bytes);
    trailing[bytes.len] = 0;

    {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_trailing", .{base_name});
        emitStatus(T, allocator, name, trailing);
    }
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const NumericMap = bcs.Map(u8, void);
    const StringMap = bcs.Map(bcs.String, u8);
    const numeric_entries = [_]NumericMap.Entry{
        .{ .key = 4, .value = {} },
        .{ .key = 5, .value = {} },
    };
    const string_entries = [_]StringMap.Entry{
        .{ .key = bcs.String.init("beta"), .value = 2 },
        .{ .key = bcs.String.init("alpha"), .value = 1 },
    };
    const nested_names = [_]bcs.String{
        bcs.String.init("hi"),
        bcs.String.init("there"),
    };

    try emitPrefixCases(bool, allocator, "bool_true", true);
    try emitPrefixCases(u32, allocator, "u32_42", @as(u32, 42));
    try emitPrefixCases(bcs.String, allocator, "string_hello", bcs.String.init("hello"));
    try emitPrefixCases([]const u16, allocator, "vec_u16", @as([]const u16, &.{ 1, 2, 3 }));
    try emitPrefixCases(?u8, allocator, "opt_some_u8", @as(?u8, 42));
    try emitPrefixCases(TinyEnum, allocator, "enum_value", TinyEnum{ .Value = 0x1234 });
    try emitPrefixCases(struct { u32, bool }, allocator, "tuple_pair", .{ @as(u32, 42), true });
    try emitPrefixCases(NumericMap, allocator, "map_u8_unit", NumericMap.from(&numeric_entries));
    try emitPrefixCases(StringMap, allocator, "map_string_u8", StringMap.from(&string_entries));
    try emitPrefixCases(Nested, allocator, "nested_struct", .{
        .id = 7,
        .names = &nested_names,
        .flag = true,
    });

    emitStatus(bool, allocator, "manual_invalid_bool", &.{9});
    emitStatus(?u8, allocator, "manual_invalid_option", &.{ 5, 0 });
    emitStatus(TinyEnum, allocator, "manual_invalid_enum_tag", &.{5});
    emitStatus(TinyEnum, allocator, "manual_invalid_enum_tag_wide", &.{ 0x80, 0x80, 0x80, 0x80, 0x0f });
    emitStatus(TinyEnum, allocator, "manual_noncanonical_uleb", &.{ 0x80, 0x80, 0x80, 0x00 });
    emitStatus(TinyEnum, allocator, "manual_uleb_overflow", &.{ 0x80, 0x80, 0x80, 0x80, 0x80 });
    emitStatus(bcs.String, allocator, "manual_invalid_utf8", &.{ 1, 0xff });
    emitStatus([]const u8, allocator, "manual_sequence_too_long", &.{ 0x80, 0x80, 0x80, 0x80, 0x08 });
    emitStatus(NumericMap, allocator, "manual_map_out_of_order", &.{ 2, 5, 4 });
    emitStatus(NumericMap, allocator, "manual_map_duplicate", &.{ 2, 5, 5 });
    emitStatus(StringMap, allocator, "manual_map_string_invalid_utf8_key", &.{ 1, 1, 0xff, 1 });
}
