const bcs = @import("bcs");
const std = @import("std");

const TinyEnum = union(enum) {
    Unit,
    Value: u64,
};

fn emitHex(name: []const u8, bytes: []const u8) void {
    std.debug.print("{s}=ok:", .{name});
    for (bytes) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
}

fn emitErr(name: []const u8) void {
    std.debug.print("{s}=err\n", .{name});
}

fn emitStatus(comptime T: type, allocator: std.mem.Allocator, name: []const u8, raw: []const u8) void {
    const value = bcs.deserialize(T, allocator, raw) catch {
        emitErr(name);
        return;
    };
    defer bcs.freeDeserialized(T, allocator, value);

    const encoded = bcs.serialize(allocator, value) catch {
        emitErr(name);
        return;
    };
    defer allocator.free(encoded);
    emitHex(name, encoded);
}

pub fn main() void {
    const allocator = std.heap.c_allocator;
    const KeySet = bcs.Map(u8, void);

    emitStatus(bool, allocator, "bool_true", &.{0x01});
    emitStatus(bool, allocator, "bool_invalid", &.{0x02});
    emitStatus(u8, allocator, "u8_trailing", &.{ 0x01, 0x02 });

    emitStatus(?u8, allocator, "opt_some_u8", &.{ 0x01, 0x2a });
    emitStatus(?u8, allocator, "opt_invalid_tag", &.{0x05});

    emitStatus(bcs.String, allocator, "string_utf8", &.{ 0x05, 'h', 'e', 'l', 'l', 'o' });
    emitStatus(bcs.String, allocator, "string_invalid_utf8", &.{ 0x02, 0xc0, 0x80 });
    emitStatus([]const u8, allocator, "bytes_invalid_utf8", &.{ 0x02, 0xc0, 0x80 });

    emitStatus(TinyEnum, allocator, "enum_unit", &.{0x00});
    emitStatus(TinyEnum, allocator, "enum_value", &.{ 0x01, 0x34, 0x12, 0, 0, 0, 0, 0, 0 });
    emitStatus(TinyEnum, allocator, "enum_invalid_tag", &.{0x02});
    emitStatus(TinyEnum, allocator, "enum_noncanonical_tag", &.{ 0x80, 0x80, 0x80, 0x80, 0x00 });

    emitStatus([]const u16, allocator, "vec_u16_ok", &.{ 0x02, 0x01, 0x00, 0x02, 0x00 });
    emitStatus([]const u16, allocator, "vec_u16_short", &.{ 0x02, 0x01, 0x00 });

    emitStatus(struct { u32, bool }, allocator, "tuple_pair", &.{ 0x2a, 0x00, 0x00, 0x00, 0x01 });

    emitStatus(KeySet, allocator, "map_empty", &.{0x00});
    emitStatus(KeySet, allocator, "map_canonical", &.{ 0x02, 0x04, 0x05 });
    emitStatus(KeySet, allocator, "map_out_of_order", &.{ 0x02, 0x05, 0x04 });
    emitStatus(KeySet, allocator, "map_duplicate", &.{ 0x02, 0x05, 0x05 });
}
