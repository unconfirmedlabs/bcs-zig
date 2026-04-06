// Cross-language BCS validation — Zig output
// Serializes identical test vectors as crossval.rs, prints hex for diffing
const bcs = @import("bcs");
const std = @import("std");

fn emit(allocator: std.mem.Allocator, name: []const u8, bytes: []const u8) void {
    std.debug.print("{s}=", .{name});
    for (bytes) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
    allocator.free(bytes);
}

const SimpleStruct = struct { a: u64, b: bool, c: [32]u8 };
const InnerStruct = struct { x: u32, y: u32 };
const NestedStruct = struct { inner: InnerStruct, flag: bool };

const TestEnum = union(enum) {
    Unit,
    WithU64: u64,
    WithBytes: [4]u8,
    WithStruct: struct { a: u16, b: u8 },
};

const ComplexStruct = struct {
    id: u64,
    name: bcs.String,
    scores: []const u32,
    active: bool,
    metadata: [8]u8,
};

const WithOption = struct { a: u32, b: ?u64, c: u8 };
const TupleStruct = struct { i8, bcs.String };

pub fn main() !void {
    const a = std.heap.c_allocator;

    // ── Primitives ────────────────────────────────────────────────
    emit(a, "bool_true", try bcs.serialize(a, true));
    emit(a, "bool_false", try bcs.serialize(a, false));
    emit(a, "u8_0", try bcs.serialize(a, @as(u8, 0)));
    emit(a, "u8_255", try bcs.serialize(a, @as(u8, 255)));
    emit(a, "u16_0", try bcs.serialize(a, @as(u16, 0)));
    emit(a, "u16_max", try bcs.serialize(a, @as(u16, 0xFFFF)));
    emit(a, "u16_0x0102", try bcs.serialize(a, @as(u16, 0x0102)));
    emit(a, "u32_0", try bcs.serialize(a, @as(u32, 0)));
    emit(a, "u32_max", try bcs.serialize(a, @as(u32, 0xFFFFFFFF)));
    emit(a, "u32_305419896", try bcs.serialize(a, @as(u32, 305419896)));
    emit(a, "u64_0", try bcs.serialize(a, @as(u64, 0)));
    emit(a, "u64_max", try bcs.serialize(a, @as(u64, 0xFFFFFFFFFFFFFFFF)));
    emit(a, "u64_42", try bcs.serialize(a, @as(u64, 42)));
    emit(a, "u128_0", try bcs.serialize(a, @as(u128, 0)));
    emit(a, "u128_max", try bcs.serialize(a, @as(u128, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)));
    emit(a, "u128_1", try bcs.serialize(a, @as(u128, 1)));

    // Signed integers
    emit(a, "i8_neg1", try bcs.serialize(a, @as(i8, -1)));
    emit(a, "i8_min", try bcs.serialize(a, @as(i8, -128)));
    emit(a, "i8_max", try bcs.serialize(a, @as(i8, 127)));
    emit(a, "i16_neg4660", try bcs.serialize(a, @as(i16, -4660)));
    emit(a, "i16_min", try bcs.serialize(a, @as(i16, -32768)));
    emit(a, "i32_neg1", try bcs.serialize(a, @as(i32, -1)));
    emit(a, "i32_min", try bcs.serialize(a, @as(i32, -2147483648)));
    emit(a, "i64_neg1", try bcs.serialize(a, @as(i64, -1)));
    emit(a, "i64_min", try bcs.serialize(a, @as(i64, -9223372036854775808)));
    emit(a, "i128_neg1", try bcs.serialize(a, @as(i128, -1)));
    emit(a, "i128_min", try bcs.serialize(a, @as(i128, @as(i128, -1) << 127)));

    // ── Strings ───────────────────────────────────────────────────
    emit(a, "string_empty", try bcs.serialize(a, bcs.String.init("")));
    emit(a, "string_hello", try bcs.serialize(a, bcs.String.init("hello")));
    emit(a, "string_diem", try bcs.serialize(a, bcs.String.init("diem")));
    emit(a, "string_utf8", try bcs.serialize(a, bcs.String.init("café")));

    // ── Vectors ───────────────────────────────────────────────────
    {
        const empty: []const u8 = &.{};
        emit(a, "vec_empty_u8", try bcs.serialize(a, empty));
    }
    emit(a, "vec_u8_3", try bcs.serialize(a, @as([]const u8, &.{ 1, 2, 3 })));
    emit(a, "vec_u16_2", try bcs.serialize(a, @as([]const u16, &.{ 1, 2 })));
    emit(a, "vec_u32_5", try bcs.serialize(a, @as([]const u32, &.{ 100, 200, 300, 400, 500 })));
    emit(a, "vec_u64_1", try bcs.serialize(a, @as([]const u64, &.{0xDEADBEEF})));
    emit(a, "vec_string_2", try bcs.serialize(a, @as([]const bcs.String, &.{ bcs.String.init("abc"), bcs.String.init("def") })));
    emit(a, "vec_vec_u8", try bcs.serialize(a, @as([]const []const u8, &.{ &.{ 1, 2 }, &.{ 3, 4, 5 } })));

    // ── Fixed arrays ──────────────────────────────────────────────
    emit(a, "arr_u8_4", try bcs.serialize(a, [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD }));
    emit(a, "arr_u16_3", try bcs.serialize(a, [3]u16{ 1, 2, 3 }));
    emit(a, "arr_u32_2", try bcs.serialize(a, [2]u32{ 0x12345678, 0xABCDEF01 }));
    emit(a, "arr_32b", try bcs.serialize(a, [32]u8{ 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42 }));

    // ── Optionals ─────────────────────────────────────────────────
    emit(a, "opt_some_u8", try bcs.serialize(a, @as(?u8, 42)));
    emit(a, "opt_none_u8", try bcs.serialize(a, @as(?u8, null)));
    emit(a, "opt_some_u64", try bcs.serialize(a, @as(?u64, 0xCAFEBABE)));
    emit(a, "opt_none_u64", try bcs.serialize(a, @as(?u64, null)));
    emit(a, "opt_some_string", try bcs.serialize(a, @as(?bcs.String, bcs.String.init("hi"))));
    emit(a, "opt_none_string", try bcs.serialize(a, @as(?bcs.String, null)));
    emit(a, "opt_opt_some", try bcs.serialize(a, @as(??u8, @as(?u8, 99))));
    emit(a, "opt_opt_none_inner", try bcs.serialize(a, @as(??u8, @as(?u8, null))));
    emit(a, "opt_opt_none_outer", try bcs.serialize(a, @as(??u8, null)));

    // ── Structs ───────────────────────────────────────────────────
    emit(a, "simple_struct", try bcs.serialize(a, SimpleStruct{
        .a = 42,
        .b = true,
        .c = .{0xab} ** 32,
    }));

    emit(a, "nested_struct", try bcs.serialize(a, NestedStruct{
        .inner = .{ .x = 100, .y = 200 },
        .flag = false,
    }));

    emit(a, "complex_struct", try bcs.serialize(a, ComplexStruct{
        .id = 999999,
        .name = bcs.String.init("hello_world_test"),
        .scores = &[_]u32{ 100, 200, 300, 400, 500 },
        .active = true,
        .metadata = "METATAG\x00".*,
    }));

    emit(a, "with_option_some", try bcs.serialize(a, WithOption{
        .a = 10,
        .b = 20,
        .c = 30,
    }));

    emit(a, "with_option_none", try bcs.serialize(a, WithOption{
        .a = 10,
        .b = null,
        .c = 30,
    }));

    // ── Enums ─────────────────────────────────────────────────────
    emit(a, "enum_unit", try bcs.serialize(a, TestEnum.Unit));
    emit(a, "enum_with_u64", try bcs.serialize(a, TestEnum{ .WithU64 = 0x1234 }));
    emit(a, "enum_with_bytes", try bcs.serialize(a, TestEnum{ .WithBytes = .{ 0xAA, 0xBB, 0xCC, 0xDD } }));
    emit(a, "enum_with_struct", try bcs.serialize(a, TestEnum{ .WithStruct = .{ .a = 1000, .b = 42 } }));

    // ── Tuples ────────────────────────────────────────────────────
    emit(a, "tuple_i8_string", try bcs.serialize(a, TupleStruct{ @as(i8, -1), bcs.String.init("diem") }));
    emit(a, "tuple_pair", try bcs.serialize(a, .{ @as(u32, 42), true }));

    // ── Maps ──────────────────────────────────────────────────────
    {
        // Map(u8, u16) with entries {1:100, 3:300, 2:200} — should sort to 1,2,3
        const MapU8U16 = bcs.Map(u8, u16);
        const entries = [_]MapU8U16.Entry{
            .{ .key = 1, .value = 100 },
            .{ .key = 3, .value = 300 },
            .{ .key = 2, .value = 200 },
        };
        emit(a, "map_u8_u16", try bcs.serialize(a, MapU8U16.from(&entries)));
    }

    {
        const MapU8U8 = bcs.Map(u8, u8);
        const entries = [_]MapU8U8.Entry{};
        emit(a, "map_empty", try bcs.serialize(a, MapU8U8.from(&entries)));
    }

    {
        const MapStrU32 = bcs.Map(bcs.String, u32);
        const entries = [_]MapStrU32.Entry{
            .{ .key = bcs.String.init("b"), .value = 2 },
            .{ .key = bcs.String.init("a"), .value = 1 },
            .{ .key = bcs.String.init("c"), .value = 3 },
        };
        emit(a, "map_string_u32", try bcs.serialize(a, MapStrU32.from(&entries)));
    }

    {
        const MapU8U16 = bcs.Map(u8, u16);
        const entries = [_]MapU8U16.Entry{
            .{ .key = 2, .value = 200 },
            .{ .key = 1, .value = 100 },
            .{ .key = 1, .value = 999 },
        };
        emit(a, "map_u8_u16_dupe_keep_first", try bcs.serialize(a, MapU8U16.from(&entries)));
    }

    {
        const MapStrU32 = bcs.Map(bcs.String, u32);
        const entries = [_]MapStrU32.Entry{
            .{ .key = bcs.String.init("b"), .value = 2 },
            .{ .key = bcs.String.init("a"), .value = 1 },
            .{ .key = bcs.String.init("a"), .value = 9 },
        };
        emit(a, "map_string_u32_dupe_keep_first", try bcs.serialize(a, MapStrU32.from(&entries)));
    }

    // ── Boundary values ───────────────────────────────────────────
    emit(a, "u64_deadbeef", try bcs.serialize(a, @as(u64, 0xDEADBEEFCAFEBABE)));

    emit(a, "sui_addr_zeros", try bcs.serialize(a, [32]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }));
    emit(a, "sui_addr_ones", try bcs.serialize(a, .{@as(u8, 0xFF)} ** 32));
    {
        var addr: [32]u8 = undefined;
        for (&addr, 0..) |*b, i| b.* = @intCast(i);
        emit(a, "sui_addr_sequential", try bcs.serialize(a, addr));
    }

    // Large vector
    {
        var arr: [100]u32 = undefined;
        for (&arr, 0..) |*v, i| v.* = @intCast(i);
        const slice: []const u32 = &arr;
        emit(a, "vec_u32_100", try bcs.serialize(a, slice));
    }
}
