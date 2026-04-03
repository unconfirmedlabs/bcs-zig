// BCS Zig throughput benchmark
// Tests: serialize + deserialize across multiple data shapes
// Reports: ops/sec, ns/op, throughput MB/s
const bcs = @import("bcs");
const std = @import("std");

const iterations: u64 = 1_000_000;

// ── Test types ────────────────────────────────────────────────────────

const SimpleStruct = struct {
    a: u64,
    b: bool,
    c: [32]u8,
};

const NestedStruct = struct {
    id: u64,
    name: []const u8,
    scores: []const u32,
    active: bool,
    metadata: InnerMeta,
};

const InnerMeta = struct {
    version: u16,
    flags: u64,
    tag: [8]u8,
};

const MoveCall = struct {
    sender: [32]u8,
    package: [32]u8,
    module_name: []const u8,
    function_name: []const u8,
    type_args: []const []const u8,
    args: []const []const u8,
    gas_budget: u64,
    gas_price: u64,
};

const Enum = union(enum) {
    unit,
    with_u64: u64,
    with_bytes: [32]u8,
    with_string: []const u8,
};

// ── Optimization barrier ──────────────────────────────────────────────

// ── Benchmark harness ─────────────────────────────────────────────────

// Volatile sink — compiler cannot optimize away writes to this
var sink: u64 = 0;
fn volatileSink() *volatile u64 {
    return @ptrCast(&sink);
}

fn benchSerialize(comptime T: type, value: T, allocator: std.mem.Allocator) !struct { ns: u64, bytes: u64 } {
    var total_bytes: u64 = 0;

    // Warm up
    for (0..1000) |_| {
        const bytes = try bcs.serialize(allocator, value);
        allocator.free(bytes);
    }

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const bytes = try bcs.serialize(allocator, value);
        total_bytes += bytes.len;
        allocator.free(bytes);
    }
    const elapsed = timer.read();
    return .{ .ns = elapsed, .bytes = total_bytes };
}

fn benchDeserialize(comptime T: type, data: []const u8, allocator: std.mem.Allocator) !u64 {
    const vs = volatileSink();

    // Warm up
    for (0..1000) |_| {
        var decoded = try bcs.deserialize(T, allocator, data);
        vs.* = @as(*const u64, @alignCast(@ptrCast(&decoded))).*;
        bcs.freeDeserialized(T, allocator, decoded);
    }

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        var decoded = try bcs.deserialize(T, allocator, data);
        vs.* = @as(*const u64, @alignCast(@ptrCast(&decoded))).*;
        bcs.freeDeserialized(T, allocator, decoded);
    }
    return timer.read();
}

fn report(name: []const u8, ser_ns: u64, de_ns: u64, total_bytes: u64) void {
    const fiter: f64 = @floatFromInt(iterations);
    const fser: f64 = @floatFromInt(ser_ns);
    const fde: f64 = @floatFromInt(de_ns);
    const fbytes: f64 = @floatFromInt(total_bytes);
    const bytes_per_op = total_bytes / iterations;

    const ser_ns_per_op = fser / fiter;
    const de_ns_per_op = fde / fiter;
    const ser_mbs = if (ser_ns > 0) fbytes / fser * 1000.0 else 0;
    const de_mbs = if (de_ns > 0) fbytes / fde * 1000.0 else 0;

    std.debug.print("  {s:<24} ser: {d:>8.1} ns/op ({d:>6.0} MB/s)  de: {d:>8.1} ns/op ({d:>6.0} MB/s)  [{d} bytes]\n", .{
        name, ser_ns_per_op, ser_mbs, de_ns_per_op, de_mbs, bytes_per_op,
    });
}

// ── Main ──────────────────────────────────────────────────────────────

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== BCS-Zig Throughput Benchmark ({d} iterations) ===\n\n", .{iterations});

    // 1. SimpleStruct (41 bytes — fixed size, no heap allocs on deser)
    {
        const val = SimpleStruct{ .a = 42, .b = true, .c = .{0xab} ** 32 };
        const data = try bcs.serialize(allocator, val);
        defer allocator.free(data);
        const ser = try benchSerialize(SimpleStruct, val, allocator);
        const de_ns = try benchDeserialize(SimpleStruct, data, allocator);
        report("simple_struct", ser.ns, de_ns, ser.bytes);
    }

    // 2. NestedStruct (with heap-allocated slices)
    {
        const val = NestedStruct{
            .id = 999999,
            .name = "hello_world_test",
            .scores = &[_]u32{ 100, 200, 300, 400, 500 },
            .active = true,
            .metadata = .{ .version = 3, .flags = 0xDEADBEEF, .tag = "METATAG\x00".* },
        };
        const data = try bcs.serialize(allocator, val);
        defer allocator.free(data);
        const ser = try benchSerialize(NestedStruct, val, allocator);
        const de_ns = try benchDeserialize(NestedStruct, data, allocator);
        report("nested_struct", ser.ns, de_ns, ser.bytes);
    }

    // 3. MoveCall-like (simulates real Sui transaction data)
    {
        const val = MoveCall{
            .sender = .{0x01} ** 32,
            .package = .{0x02} ** 32,
            .module_name = "coin",
            .function_name = "transfer",
            .type_args = &[_][]const u8{ "0x2::sui::SUI", "0x2::coin::Coin" },
            .args = &[_][]const u8{ &(.{0xaa} ** 32), &(.{0xbb} ** 16) },
            .gas_budget = 50_000_000,
            .gas_price = 1000,
        };
        const data = try bcs.serialize(allocator, val);
        defer allocator.free(data);
        const ser = try benchSerialize(MoveCall, val, allocator);
        const de_ns = try benchDeserialize(MoveCall, data, allocator);
        report("move_call", ser.ns, de_ns, ser.bytes);
    }

    // 4. Enum variants
    {
        const val = Enum{ .with_bytes = .{0xff} ** 32 };
        const data = try bcs.serialize(allocator, val);
        defer allocator.free(data);
        const ser = try benchSerialize(Enum, val, allocator);
        const de_ns = try benchDeserialize(Enum, data, allocator);
        report("enum_variant", ser.ns, de_ns, ser.bytes);
    }

    // 5. u64 (raw primitive baseline)
    {
        const val: u64 = 0xDEADBEEFCAFEBABE;
        const data = try bcs.serialize(allocator, val);
        defer allocator.free(data);
        const ser = try benchSerialize(u64, val, allocator);
        const de_ns = try benchDeserialize(u64, data, allocator);
        report("u64", ser.ns, de_ns, ser.bytes);
    }

    // 6. Large vector (1000 u32s)
    {
        var arr: [1000]u32 = undefined;
        for (&arr, 0..) |*v, i| v.* = @intCast(i);
        const val: []const u32 = &arr;
        const data = try bcs.serialize(allocator, val);
        defer allocator.free(data);
        const ser_res = try benchSerialize([]const u32, val, allocator);
        const de_ns = try benchDeserialize([]const u32, data, allocator);
        report("vec_1000_u32", ser_res.ns, de_ns, ser_res.bytes);
    }

    // 7. [32]u8 address (very common in Sui)
    {
        const val: [32]u8 = .{0x42} ** 32;
        const data = try bcs.serialize(allocator, val);
        defer allocator.free(data);
        const ser = try benchSerialize([32]u8, val, allocator);
        const de_ns = try benchDeserialize([32]u8, data, allocator);
        report("address_32b", ser.ns, de_ns, ser.bytes);
    }

    // ── Zero-allocation path (serializeInto) ────────────────────────────
    std.debug.print("\n  --- serializeInto (zero-alloc) ---\n", .{});

    // u64 zero-alloc
    {
        const val: u64 = 0xDEADBEEFCAFEBABE;
        var buf: [8]u8 = undefined;
        const vs = volatileSink();
        for (0..1000) |_| {
            _ = try bcs.serializeInto(&buf, val);
            vs.* = @as(*const u64, @alignCast(@ptrCast(&buf))).*;
        }
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            _ = try bcs.serializeInto(&buf, val);
            vs.* = @as(*const u64, @alignCast(@ptrCast(&buf))).*;
        }
        const ns = timer.read();
        const fiter: f64 = @floatFromInt(iterations);
        const fns: f64 = @floatFromInt(ns);
        std.debug.print("  {s:<24} ser: {d:>8.1} ns/op ({d:>6.0} MB/s)  [8 bytes]\n", .{
            "u64 (no alloc)", fns / fiter, 8.0 * fiter / fns * 1000.0,
        });
    }

    // SimpleStruct zero-alloc
    {
        const val = SimpleStruct{ .a = 42, .b = true, .c = .{0xab} ** 32 };
        var buf: [41]u8 = undefined;
        const vs = volatileSink();
        for (0..1000) |_| {
            _ = try bcs.serializeInto(&buf, val);
            vs.* = @as(*const u64, @alignCast(@ptrCast(&buf))).*;
        }
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            _ = try bcs.serializeInto(&buf, val);
            vs.* = @as(*const u64, @alignCast(@ptrCast(&buf))).*;
        }
        const ns = timer.read();
        const fiter: f64 = @floatFromInt(iterations);
        const fns: f64 = @floatFromInt(ns);
        std.debug.print("  {s:<24} ser: {d:>8.1} ns/op ({d:>6.0} MB/s)  [41 bytes]\n", .{
            "simple_struct (no alloc)", fns / fiter, 41.0 * fiter / fns * 1000.0,
        });
    }

    // [32]u8 address zero-alloc
    {
        const val: [32]u8 = .{0x42} ** 32;
        var buf: [32]u8 = undefined;
        const vs = volatileSink();
        for (0..1000) |_| {
            _ = try bcs.serializeInto(&buf, val);
            vs.* = @as(*const u64, @alignCast(@ptrCast(&buf))).*;
        }
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            _ = try bcs.serializeInto(&buf, val);
            vs.* = @as(*const u64, @alignCast(@ptrCast(&buf))).*;
        }
        const ns = timer.read();
        const fiter: f64 = @floatFromInt(iterations);
        const fns: f64 = @floatFromInt(ns);
        std.debug.print("  {s:<24} ser: {d:>8.1} ns/op ({d:>6.0} MB/s)  [32 bytes]\n", .{
            "address_32b (no alloc)", fns / fiter, 32.0 * fiter / fns * 1000.0,
        });
    }

    // Prevent global sink from being optimized away
    std.debug.print("  (checksum: {x})\n\n", .{sink});
}
