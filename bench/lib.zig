// Zig BCS benchmark — WASM library
// Exports roundtrip functions for browser benchmark arena.
//
// Build (from project root):
//   zig build-exe -target wasm32-freestanding -OReleaseSmall --dep bcs \
//     -Mroot=bench/lib.zig -Mbcs=src/bcs.zig -rdynamic \
//     --cache-dir /tmp/zig-cache --global-cache-dir /tmp/zig-global-cache
//   mv root.wasm zig-out/bench.wasm
const bcs = @import("bcs");
const std = @import("std");

fn str(bytes: []const u8) bcs.String {
    return bcs.String.init(bytes);
}

// ── Types (matching throughput.zig exactly) ──────────────────────────

const SimpleStruct = struct {
    a: u64,
    b: bool,
    c: [32]u8,
};

const InnerMeta = struct {
    version: u16,
    flags: u64,
    tag: [8]u8,
};

const NestedStruct = struct {
    id: u64,
    name: bcs.String,
    scores: []const u32,
    active: bool,
    metadata: InnerMeta,
};

const MoveCall = struct {
    sender: [32]u8,
    package: [32]u8,
    module_name: bcs.String,
    function_name: bcs.String,
    type_args: []const bcs.String,
    args: []const []const u8,
    gas_budget: u64,
    gas_price: u64,
};

const Enum = union(enum) {
    unit,
    with_u64: u64,
    with_bytes: [32]u8,
    with_string: bcs.String,
};

// ── Allocator (32KB fixed buffer, reset per call) ────────────────────

var buf: [32768]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buf);

// ── Test data (comptime, matching throughput.zig values) ─────────────

const simple_val = SimpleStruct{ .a = 42, .b = true, .c = .{0xab} ** 32 };

const nested_scores = [_]u32{ 100, 200, 300, 400, 500 };
const nested_meta_tag: [8]u8 = "METATAG\x00".*;
const nested_val = NestedStruct{
    .id = 999999,
    .name = str("hello_world_test"),
    .scores = &nested_scores,
    .active = true,
    .metadata = .{ .version = 3, .flags = 0xDEADBEEF, .tag = nested_meta_tag },
};

const move_type_arg_0: bcs.String = str("0x2::sui::SUI");
const move_type_arg_1: bcs.String = str("0x2::coin::Coin");
const move_type_args: []const bcs.String = &.{ move_type_arg_0, move_type_arg_1 };
const move_arg_0: []const u8 = &(.{0xaa} ** 32);
const move_arg_1: []const u8 = &(.{0xbb} ** 16);
const move_args: []const []const u8 = &.{ move_arg_0, move_arg_1 };
const move_val = MoveCall{
    .sender = .{0x01} ** 32,
    .package = .{0x02} ** 32,
    .module_name = str("coin"),
    .function_name = str("transfer"),
    .type_args = move_type_args,
    .args = move_args,
    .gas_budget = 50_000_000,
    .gas_price = 1000,
};

const enum_val = Enum{ .with_bytes = .{0xff} ** 32 };

const vec_data = blk: {
    var arr: [1000]u32 = undefined;
    for (&arr, 0..) |*v, i| v.* = @intCast(i);
    break :blk arr;
};

const address_val: [32]u8 = .{0x42} ** 32;

const u128_val: u128 = 0xDEADBEEFCAFEBABE_0123456789ABCDEF;
const u256_val: u256 = 0xDEADBEEFCAFEBABE_0123456789ABCDEF_FEDCBA9876543210_BAADF00DCAFEBABE;
const option_val: ?SimpleStruct = SimpleStruct{ .a = 42, .b = true, .c = .{0xab} ** 32 };

// ── Roundtrip exports ────────────────────────────────────────────────

export fn roundtrip_simple_struct() u64 {
    fba.reset();
    const a = fba.allocator();
    const bytes = bcs.serialize(a, simple_val) catch return 0;
    const decoded = bcs.deserialize(SimpleStruct, a, bytes) catch return 0;
    return decoded.a;
}

export fn roundtrip_nested_struct() u64 {
    fba.reset();
    const a = fba.allocator();
    const bytes = bcs.serialize(a, nested_val) catch return 0;
    const decoded = bcs.deserialize(NestedStruct, a, bytes) catch return 0;
    return decoded.id;
}

export fn roundtrip_move_call() u64 {
    fba.reset();
    const a = fba.allocator();
    const bytes = bcs.serialize(a, move_val) catch return 0;
    const decoded = bcs.deserialize(MoveCall, a, bytes) catch return 0;
    return decoded.gas_budget;
}

export fn roundtrip_enum() u64 {
    fba.reset();
    const a = fba.allocator();
    const bytes = bcs.serialize(a, enum_val) catch return 0;
    const decoded = bcs.deserialize(Enum, a, bytes) catch return 0;
    return switch (decoded) {
        .with_bytes => |b| b[0],
        else => 0,
    };
}

export fn roundtrip_u64() u64 {
    fba.reset();
    const a = fba.allocator();
    const val: u64 = 0xDEADBEEFCAFEBABE;
    const bytes = bcs.serialize(a, val) catch return 0;
    const decoded = bcs.deserialize(u64, a, bytes) catch return 0;
    return decoded;
}

export fn roundtrip_vec_1000_u32() u64 {
    fba.reset();
    const a = fba.allocator();
    const val: []const u32 = &vec_data;
    const bytes = bcs.serialize(a, val) catch return 0;
    const decoded = bcs.deserialize([]const u32, a, bytes) catch return 0;
    return decoded.len;
}

export fn roundtrip_address_32b() u64 {
    fba.reset();
    const a = fba.allocator();
    const bytes = bcs.serialize(a, address_val) catch return 0;
    const decoded = bcs.deserialize([32]u8, a, bytes) catch return 0;
    return decoded[0];
}

export fn roundtrip_option_struct() u64 {
    fba.reset();
    const a = fba.allocator();
    const bytes = bcs.serialize(a, option_val) catch return 0;
    const decoded = bcs.deserialize(?SimpleStruct, a, bytes) catch return 0;
    return if (decoded) |s| s.a else 0;
}

export fn roundtrip_u128() u64 {
    fba.reset();
    const a = fba.allocator();
    const bytes = bcs.serialize(a, u128_val) catch return 0;
    const decoded = bcs.deserialize(u128, a, bytes) catch return 0;
    return @truncate(decoded);
}

export fn roundtrip_u256() u64 {
    fba.reset();
    const a = fba.allocator();
    const bytes = bcs.serialize(a, u256_val) catch return 0;
    const decoded = bcs.deserialize(u256, a, bytes) catch return 0;
    return @truncate(decoded);
}

// Required for wasm32-freestanding build-exe target
pub fn main() void {}
