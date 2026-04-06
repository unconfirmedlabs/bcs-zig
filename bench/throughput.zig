// BCS Zig throughput benchmark
// Tests: serialize + deserialize across multiple data shapes
// Reports: ops/sec, ns/op, throughput MB/s
const bcs = @import("bcs");
const std = @import("std");

fn str(bytes: []const u8) bcs.String {
    return bcs.String.init(bytes);
}

const iterations: u64 = 250_000;
const warmup_iterations: u64 = 5_000;
const sample_count: usize = 7;

// ── Test types ────────────────────────────────────────────────────────

const SimpleStruct = struct {
    a: u64,
    b: bool,
    c: [32]u8,
};

const NestedStruct = struct {
    id: u64,
    name: bcs.String,
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

const SampleResult = struct {
    ns_samples: [sample_count]u64,
    bytes: u64,
};

const Stats = struct {
    min: u64,
    median: u64,
    max: u64,
};

// ── Optimization barrier ──────────────────────────────────────────────

var sink: u64 = 0;

fn consumeBytes(bytes: []const u8) void {
    sink +%= bytes.len;
    if (bytes.len > 0) {
        sink +%= bytes[0];
        sink +%= @as(u64, bytes[bytes.len - 1]) << 8;
    }
    std.mem.doNotOptimizeAway(bytes);
    std.mem.doNotOptimizeAway(sink);
}

fn consumeValue(value: anytype) void {
    std.mem.doNotOptimizeAway(value);
    sink +%= 1;
    std.mem.doNotOptimizeAway(sink);
}

fn serializeCall(comptime T: type, allocator: std.mem.Allocator, value: T) ![]u8 {
    return @call(.never_inline, bcs.serialize, .{ allocator, value });
}

fn deserializeCall(comptime T: type, allocator: std.mem.Allocator, data: []const u8) !T {
    return @call(.never_inline, bcs.deserialize, .{ T, allocator, data });
}

fn serializeIntoCall(buf: []u8, value: anytype) !usize {
    return @call(.never_inline, bcs.serializeInto, .{ buf, value });
}

fn summarize(samples: [sample_count]u64) Stats {
    var sorted = samples;
    for (1..sorted.len) |i| {
        var j = i;
        while (j > 0 and sorted[j - 1] > sorted[j]) : (j -= 1) {
            std.mem.swap(u64, &sorted[j - 1], &sorted[j]);
        }
    }

    return .{
        .min = sorted[0],
        .median = sorted[sorted.len / 2],
        .max = sorted[sorted.len - 1],
    };
}

// ── Benchmark harness ─────────────────────────────────────────────────

fn benchSerialize(comptime T: type, value: T, allocator: std.mem.Allocator) !SampleResult {
    // Warm up
    for (0..warmup_iterations) |_| {
        const bytes = try serializeCall(T, allocator, value);
        consumeBytes(bytes);
        allocator.free(bytes);
    }

    var ns_samples: [sample_count]u64 = undefined;
    var total_bytes: u64 = 0;

    for (0..sample_count) |sample_idx| {
        var sample_bytes: u64 = 0;
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            const bytes = try serializeCall(T, allocator, value);
            sample_bytes += bytes.len;
            consumeBytes(bytes);
            allocator.free(bytes);
        }
        ns_samples[sample_idx] = timer.read();
        if (sample_idx == 0) total_bytes = sample_bytes;
    }

    return .{ .ns_samples = ns_samples, .bytes = total_bytes };
}

fn benchDeserialize(comptime T: type, data: []const u8, allocator: std.mem.Allocator) ![sample_count]u64 {
    // Warm up
    for (0..warmup_iterations) |_| {
        const decoded = try deserializeCall(T, allocator, data);
        consumeValue(decoded);
        bcs.freeDeserialized(T, allocator, decoded);
    }

    var ns_samples: [sample_count]u64 = undefined;
    for (0..sample_count) |sample_idx| {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            const decoded = try deserializeCall(T, allocator, data);
            consumeValue(decoded);
            bcs.freeDeserialized(T, allocator, decoded);
        }
        ns_samples[sample_idx] = timer.read();
    }
    return ns_samples;
}

fn benchSerializeWriter(comptime T: type, value: T, allocator: std.mem.Allocator) !?SampleResult {
    comptime if (!@hasDecl(bcs, "serializeWriter")) return null;

    const initial = try serializeCall(T, allocator, value);
    defer allocator.free(initial);

    var list = try std.ArrayList(u8).initCapacity(allocator, initial.len);
    defer list.deinit(allocator);

    for (0..warmup_iterations) |_| {
        list.clearRetainingCapacity();
        const writer = list.writer(allocator);
        try bcs.serializeWriter(allocator, writer, value);
        consumeBytes(list.items);
    }

    var ns_samples: [sample_count]u64 = undefined;
    for (0..sample_count) |sample_idx| {
        var sample_bytes: u64 = 0;
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            list.clearRetainingCapacity();
            const writer = list.writer(allocator);
            try bcs.serializeWriter(allocator, writer, value);
            sample_bytes += list.items.len;
            consumeBytes(list.items);
        }
        ns_samples[sample_idx] = timer.read();
        if (sample_idx == 0) std.mem.doNotOptimizeAway(sample_bytes);
    }

    return .{ .ns_samples = ns_samples, .bytes = @as(u64, initial.len) * iterations };
}

fn report(name: []const u8, ser_samples: [sample_count]u64, de_samples: [sample_count]u64, total_bytes: u64) void {
    const fiter: f64 = @floatFromInt(iterations);
    const fbytes: f64 = @floatFromInt(total_bytes);
    const bytes_per_op = total_bytes / iterations;

    const ser = summarize(ser_samples);
    const de = summarize(de_samples);

    const ser_ns_per_op = @as(f64, @floatFromInt(ser.median)) / fiter;
    const de_ns_per_op = @as(f64, @floatFromInt(de.median)) / fiter;
    const ser_mbs = if (ser.median > 0) fbytes / @as(f64, @floatFromInt(ser.median)) * 1000.0 else 0;
    const de_mbs = if (de.median > 0) fbytes / @as(f64, @floatFromInt(de.median)) * 1000.0 else 0;
    const ser_min = @as(f64, @floatFromInt(ser.min)) / fiter;
    const ser_max = @as(f64, @floatFromInt(ser.max)) / fiter;
    const de_min = @as(f64, @floatFromInt(de.min)) / fiter;
    const de_max = @as(f64, @floatFromInt(de.max)) / fiter;

    std.debug.print("  {s:<24} ser: {d:>8.1} ns/op [{d:>6.1}-{d:>6.1}] ({d:>6.0} MB/s)  de: {d:>8.1} ns/op [{d:>6.1}-{d:>6.1}] ({d:>6.0} MB/s)  [{d} bytes]\n", .{
        name, ser_ns_per_op, ser_min, ser_max, ser_mbs, de_ns_per_op, de_min, de_max, de_mbs, bytes_per_op,
    });
}

fn reportSerializeOnly(name: []const u8, ser_samples: [sample_count]u64, total_bytes: u64) void {
    const fiter: f64 = @floatFromInt(iterations);
    const fbytes: f64 = @floatFromInt(total_bytes);
    const bytes_per_op = total_bytes / iterations;
    const ser = summarize(ser_samples);
    const ser_ns_per_op = @as(f64, @floatFromInt(ser.median)) / fiter;
    const ser_mbs = if (ser.median > 0) fbytes / @as(f64, @floatFromInt(ser.median)) * 1000.0 else 0;
    const ser_min = @as(f64, @floatFromInt(ser.min)) / fiter;
    const ser_max = @as(f64, @floatFromInt(ser.max)) / fiter;

    std.debug.print("  {s:<24} ser: {d:>8.1} ns/op [{d:>6.1}-{d:>6.1}] ({d:>6.0} MB/s)  [{d} bytes]\n", .{
        name, ser_ns_per_op, ser_min, ser_max, ser_mbs, bytes_per_op,
    });
}

fn reportDeserializeOnly(name: []const u8, de_samples: [sample_count]u64, total_bytes: u64) void {
    const fiter: f64 = @floatFromInt(iterations);
    const fbytes: f64 = @floatFromInt(total_bytes);
    const bytes_per_op = total_bytes / iterations;
    const de = summarize(de_samples);
    const de_ns_per_op = @as(f64, @floatFromInt(de.median)) / fiter;
    const de_mbs = if (de.median > 0) fbytes / @as(f64, @floatFromInt(de.median)) * 1000.0 else 0;
    const de_min = @as(f64, @floatFromInt(de.min)) / fiter;
    const de_max = @as(f64, @floatFromInt(de.max)) / fiter;

    std.debug.print("  {s:<24} de: {d:>8.1} ns/op [{d:>6.1}-{d:>6.1}] ({d:>6.0} MB/s)  [{d} bytes]\n", .{
        name, de_ns_per_op, de_min, de_max, de_mbs, bytes_per_op,
    });
}

// ── Main ──────────────────────────────────────────────────────────────

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== BCS-Zig Throughput Benchmark ({d} iterations/sample, {d} samples, median shown) ===\n\n", .{
        iterations,
        sample_count,
    });

    // 1. SimpleStruct (41 bytes — fixed size, no heap allocs on deser)
    {
        const val = SimpleStruct{ .a = 42, .b = true, .c = .{0xab} ** 32 };
        const data = try serializeCall(SimpleStruct, allocator, val);
        defer allocator.free(data);
        const de = try benchDeserialize(SimpleStruct, data, allocator);
        const ser = try benchSerialize(SimpleStruct, val, allocator);
        report("simple_struct", ser.ns_samples, de, ser.bytes);
    }

    // 2. NestedStruct (with heap-allocated slices)
    {
        const val = NestedStruct{
            .id = 999999,
            .name = str("hello_world_test"),
            .scores = &[_]u32{ 100, 200, 300, 400, 500 },
            .active = true,
            .metadata = .{ .version = 3, .flags = 0xDEADBEEF, .tag = "METATAG\x00".* },
        };
        const data = try serializeCall(NestedStruct, allocator, val);
        defer allocator.free(data);
        const de = try benchDeserialize(NestedStruct, data, allocator);
        const ser = try benchSerialize(NestedStruct, val, allocator);
        report("nested_struct", ser.ns_samples, de, ser.bytes);
    }

    // 3. MoveCall-like (simulates real Sui transaction data)
    {
        const val = MoveCall{
            .sender = .{0x01} ** 32,
            .package = .{0x02} ** 32,
            .module_name = str("coin"),
            .function_name = str("transfer"),
            .type_args = &[_]bcs.String{ str("0x2::sui::SUI"), str("0x2::coin::Coin") },
            .args = &[_][]const u8{ &(.{0xaa} ** 32), &(.{0xbb} ** 16) },
            .gas_budget = 50_000_000,
            .gas_price = 1000,
        };
        const data = try serializeCall(MoveCall, allocator, val);
        defer allocator.free(data);
        const de = try benchDeserialize(MoveCall, data, allocator);
        const ser = try benchSerialize(MoveCall, val, allocator);
        report("move_call", ser.ns_samples, de, ser.bytes);
    }

    // 4. Enum variants
    {
        const val = Enum{ .with_bytes = .{0xff} ** 32 };
        const data = try serializeCall(Enum, allocator, val);
        defer allocator.free(data);
        const de = try benchDeserialize(Enum, data, allocator);
        const ser = try benchSerialize(Enum, val, allocator);
        report("enum_variant", ser.ns_samples, de, ser.bytes);
    }

    // 5. u64 (raw primitive baseline)
    {
        const val: u64 = 0xDEADBEEFCAFEBABE;
        const data = try serializeCall(u64, allocator, val);
        defer allocator.free(data);
        const de = try benchDeserialize(u64, data, allocator);
        const ser = try benchSerialize(u64, val, allocator);
        report("u64", ser.ns_samples, de, ser.bytes);
    }

    // 6. Large vector (1000 u32s)
    {
        var arr: [1000]u32 = undefined;
        for (&arr, 0..) |*v, i| v.* = @intCast(i);
        const val: []const u32 = &arr;
        const data = try serializeCall([]const u32, allocator, val);
        defer allocator.free(data);
        const de = try benchDeserialize([]const u32, data, allocator);
        const ser_res = try benchSerialize([]const u32, val, allocator);
        report("vec_1000_u32", ser_res.ns_samples, de, ser_res.bytes);
    }

    // 7. [32]u8 address (very common in Sui)
    {
        const val: [32]u8 = .{0x42} ** 32;
        const data = try serializeCall([32]u8, allocator, val);
        defer allocator.free(data);
        const de = try benchDeserialize([32]u8, data, allocator);
        const ser = try benchSerialize([32]u8, val, allocator);
        report("address_32b", ser.ns_samples, de, ser.bytes);
    }

    // 8. Map<u64, u64> x64 (fixed-size keys, sort on every serialization)
    {
        const M = bcs.Map(u64, u64);
        var entries: [64]M.Entry = undefined;
        for (&entries, 0..) |*entry, i| {
            const permuted = (i * 17) % entries.len;
            entry.* = .{
                .key = @intCast(permuted * 3 + 1),
                .value = @intCast(i * 101),
            };
        }
        const val = M.from(&entries);
        const data = try serializeCall(M, allocator, val);
        defer allocator.free(data);
        const de = try benchDeserialize(M, data, allocator);
        const ser = try benchSerialize(M, val, allocator);
        report("map_u64_u64_x64", ser.ns_samples, de, ser.bytes);
    }

    // 9. Map<string, u64> x8 (variable-size keys)
    {
        const M = bcs.Map(bcs.String, u64);
        const keys = [_]bcs.String{
            str("kappa"), str("alpha"), str("theta"), str("beta"),
            str("gamma"), str("delta"), str("omega"), str("eta"),
        };
        var entries: [keys.len]M.Entry = undefined;
        for (keys, 0..) |key, i| {
            entries[i] = .{
                .key = key,
                .value = @intCast((i + 1) * 111),
            };
        }
        const val = M.from(&entries);
        const data = try serializeCall(M, allocator, val);
        defer allocator.free(data);
        const de = try benchDeserialize(M, data, allocator);
        const ser = try benchSerialize(M, val, allocator);
        report("map_str_u64_x8", ser.ns_samples, de, ser.bytes);
    }

    // 10. Map<address, u64> x64 ([32]u8 fixed byte keys)
    {
        const M = bcs.Map([32]u8, u64);
        var entries: [64]M.Entry = undefined;
        for (&entries, 0..) |*entry, i| {
            const permuted = (i * 17) % entries.len;
            var key: [32]u8 = .{0} ** 32;
            key[0] = @intCast(permuted);
            key[31] = @intCast(permuted ^ 0x5a);
            entry.* = .{
                .key = key,
                .value = @intCast(i * 131),
            };
        }
        const val = M.from(&entries);
        const data = try serializeCall(M, allocator, val);
        defer allocator.free(data);
        const de = try benchDeserialize(M, data, allocator);
        const ser = try benchSerialize(M, val, allocator);
        report("map_addr_u64_x64", ser.ns_samples, de, ser.bytes);
    }

    if (comptime @hasDecl(bcs, "CanonicalMap")) {
        std.debug.print("\n  --- canonical maps (pre-sorted, linear validation) ---\n", .{});

        {
            const M = bcs.CanonicalMap(u64, u64);
            var entries: [64]M.Entry = undefined;
            for (&entries, 0..) |*entry, i| {
                entry.* = .{
                    .key = @intCast(i * 3 + 1),
                    .value = @intCast(i * 101),
                };
            }
            const val = M.from(&entries);
            const ser = try benchSerialize(M, val, allocator);
            reportSerializeOnly("cmap_u64_u64_x64", ser.ns_samples, ser.bytes);
        }

        {
            const M = bcs.CanonicalMap(bcs.String, u64);
            const sorted_keys = [_]bcs.String{
                str("eta"),   str("beta"),  str("alpha"), str("delta"),
                str("gamma"), str("kappa"), str("omega"), str("theta"),
            };
            var entries: [sorted_keys.len]M.Entry = undefined;
            for (sorted_keys, 0..) |key, i| {
                entries[i] = .{
                    .key = key,
                    .value = @intCast((i + 1) * 111),
                };
            }
            const val = M.from(&entries);
            const ser = try benchSerialize(M, val, allocator);
            reportSerializeOnly("cmap_str_u64_x8", ser.ns_samples, ser.bytes);
        }

        {
            const M = bcs.CanonicalMap([32]u8, u64);
            var entries: [64]M.Entry = undefined;
            for (&entries, 0..) |*entry, i| {
                var key: [32]u8 = .{0} ** 32;
                key[0] = @intCast(i);
                key[31] = @intCast(i ^ 0x5a);
                entry.* = .{
                    .key = key,
                    .value = @intCast(i * 131),
                };
            }
            const val = M.from(&entries);
            const ser = try benchSerialize(M, val, allocator);
            reportSerializeOnly("cmap_addr_u64_x64", ser.ns_samples, ser.bytes);
        }
    }

    // ── Zero-allocation path (serializeInto) ────────────────────────────
    std.debug.print("\n  --- serializeInto (zero-alloc) ---\n", .{});

    // u64 zero-alloc
    {
        const val: u64 = 0xDEADBEEFCAFEBABE;
        var buf: [8]u8 = undefined;
        for (0..warmup_iterations) |_| {
            const n = try serializeIntoCall(&buf, val);
            consumeBytes(buf[0..n]);
        }
        var samples: [sample_count]u64 = undefined;
        for (0..sample_count) |sample_idx| {
            var timer = try std.time.Timer.start();
            for (0..iterations) |_| {
                const n = try serializeIntoCall(&buf, val);
                consumeBytes(buf[0..n]);
            }
            samples[sample_idx] = timer.read();
        }
        const stats = summarize(samples);
        const fiter: f64 = @floatFromInt(iterations);
        const median: f64 = @floatFromInt(stats.median);
        const min: f64 = @floatFromInt(stats.min);
        const max: f64 = @floatFromInt(stats.max);
        std.debug.print("  {s:<24} ser: {d:>8.1} ns/op [{d:>6.1}-{d:>6.1}] ({d:>6.0} MB/s)  [8 bytes]\n", .{
            "u64 (no alloc)", median / fiter, min / fiter, max / fiter, 8.0 * fiter / median * 1000.0,
        });
    }

    // SimpleStruct zero-alloc
    {
        const val = SimpleStruct{ .a = 42, .b = true, .c = .{0xab} ** 32 };
        var buf: [41]u8 = undefined;
        for (0..warmup_iterations) |_| {
            const n = try serializeIntoCall(&buf, val);
            consumeBytes(buf[0..n]);
        }
        var samples: [sample_count]u64 = undefined;
        for (0..sample_count) |sample_idx| {
            var timer = try std.time.Timer.start();
            for (0..iterations) |_| {
                const n = try serializeIntoCall(&buf, val);
                consumeBytes(buf[0..n]);
            }
            samples[sample_idx] = timer.read();
        }
        const stats = summarize(samples);
        const fiter: f64 = @floatFromInt(iterations);
        const median: f64 = @floatFromInt(stats.median);
        const min: f64 = @floatFromInt(stats.min);
        const max: f64 = @floatFromInt(stats.max);
        std.debug.print("  {s:<24} ser: {d:>8.1} ns/op [{d:>6.1}-{d:>6.1}] ({d:>6.0} MB/s)  [41 bytes]\n", .{
            "simple_struct (no alloc)", median / fiter, min / fiter, max / fiter, 41.0 * fiter / median * 1000.0,
        });
    }

    // [32]u8 address zero-alloc
    {
        const val: [32]u8 = .{0x42} ** 32;
        var buf: [32]u8 = undefined;
        for (0..warmup_iterations) |_| {
            const n = try serializeIntoCall(&buf, val);
            consumeBytes(buf[0..n]);
        }
        var samples: [sample_count]u64 = undefined;
        for (0..sample_count) |sample_idx| {
            var timer = try std.time.Timer.start();
            for (0..iterations) |_| {
                const n = try serializeIntoCall(&buf, val);
                consumeBytes(buf[0..n]);
            }
            samples[sample_idx] = timer.read();
        }
        const stats = summarize(samples);
        const fiter: f64 = @floatFromInt(iterations);
        const median: f64 = @floatFromInt(stats.median);
        const min: f64 = @floatFromInt(stats.min);
        const max: f64 = @floatFromInt(stats.max);
        std.debug.print("  {s:<24} ser: {d:>8.1} ns/op [{d:>6.1}-{d:>6.1}] ({d:>6.0} MB/s)  [32 bytes]\n", .{
            "address_32b (no alloc)", median / fiter, min / fiter, max / fiter, 32.0 * fiter / median * 1000.0,
        });
    }

    if (comptime @hasDecl(bcs, "serializeWriter")) {
        std.debug.print("\n  --- serializeWriter (reused buffer) ---\n", .{});

        {
            const val = NestedStruct{
                .id = 999999,
                .name = str("hello_world_test"),
                .scores = &[_]u32{ 100, 200, 300, 400, 500 },
                .active = true,
                .metadata = .{ .version = 3, .flags = 0xDEADBEEF, .tag = "METATAG\x00".* },
            };
            if (try benchSerializeWriter(NestedStruct, val, allocator)) |ser| {
                reportSerializeOnly("nested_struct (writer)", ser.ns_samples, ser.bytes);
            }
        }

        {
            const val = MoveCall{
                .sender = .{0x01} ** 32,
                .package = .{0x02} ** 32,
                .module_name = str("coin"),
                .function_name = str("transfer"),
                .type_args = &[_]bcs.String{ str("0x2::sui::SUI"), str("0x2::coin::Coin") },
                .args = &[_][]const u8{ &(.{0xaa} ** 32), &(.{0xbb} ** 16) },
                .gas_budget = 50_000_000,
                .gas_price = 1000,
            };
            if (try benchSerializeWriter(MoveCall, val, allocator)) |ser| {
                reportSerializeOnly("move_call (writer)", ser.ns_samples, ser.bytes);
            }
        }

        {
            var arr: [1000]u32 = undefined;
            for (&arr, 0..) |*v, i| v.* = @intCast(i);
            const val: []const u32 = &arr;
            if (try benchSerializeWriter([]const u32, val, allocator)) |ser| {
                reportSerializeOnly("vec_1000_u32 (writer)", ser.ns_samples, ser.bytes);
            }
        }

        {
            const M = bcs.Map(u64, u64);
            var entries: [64]M.Entry = undefined;
            for (&entries, 0..) |*entry, i| {
                const permuted = (i * 17) % entries.len;
                entry.* = .{
                    .key = @intCast(permuted * 3 + 1),
                    .value = @intCast(i * 101),
                };
            }
            const val = M.from(&entries);
            if (try benchSerializeWriter(M, val, allocator)) |ser| {
                reportSerializeOnly("map_u64_u64_x64 (writer)", ser.ns_samples, ser.bytes);
            }
        }

        {
            const M = bcs.Map(bcs.String, u64);
            const keys = [_]bcs.String{
                str("kappa"), str("alpha"), str("theta"), str("beta"),
                str("gamma"), str("delta"), str("omega"), str("eta"),
            };
            var entries: [keys.len]M.Entry = undefined;
            for (keys, 0..) |key, i| {
                entries[i] = .{
                    .key = key,
                    .value = @intCast((i + 1) * 111),
                };
            }
            const val = M.from(&entries);
            if (try benchSerializeWriter(M, val, allocator)) |ser| {
                reportSerializeOnly("map_str_u64_x8 (writer)", ser.ns_samples, ser.bytes);
            }
        }

        {
            const M = bcs.Map([32]u8, u64);
            var entries: [64]M.Entry = undefined;
            for (&entries, 0..) |*entry, i| {
                const permuted = (i * 17) % entries.len;
                var key: [32]u8 = .{0} ** 32;
                key[0] = @intCast(permuted);
                key[31] = @intCast(permuted ^ 0x5a);
                entry.* = .{
                    .key = key,
                    .value = @intCast(i * 131),
                };
            }
            const val = M.from(&entries);
            if (try benchSerializeWriter(M, val, allocator)) |ser| {
                reportSerializeOnly("map_addr_u64_x64 (writer)", ser.ns_samples, ser.bytes);
            }
        }

        if (comptime @hasDecl(bcs, "CanonicalMap")) {
            {
                const M = bcs.CanonicalMap(u64, u64);
                var entries: [64]M.Entry = undefined;
                for (&entries, 0..) |*entry, i| {
                    entry.* = .{
                        .key = @intCast(i * 3 + 1),
                        .value = @intCast(i * 101),
                    };
                }
                const val = M.from(&entries);
                if (try benchSerializeWriter(M, val, allocator)) |ser| {
                    reportSerializeOnly("cmap_u64_u64_x64 (writer)", ser.ns_samples, ser.bytes);
                }
            }

            {
                const M = bcs.CanonicalMap(bcs.String, u64);
                const sorted_keys = [_]bcs.String{
                    str("eta"),   str("beta"),  str("alpha"), str("delta"),
                    str("gamma"), str("kappa"), str("omega"), str("theta"),
                };
                var entries: [sorted_keys.len]M.Entry = undefined;
                for (sorted_keys, 0..) |key, i| {
                    entries[i] = .{
                        .key = key,
                        .value = @intCast((i + 1) * 111),
                    };
                }
                const val = M.from(&entries);
                if (try benchSerializeWriter(M, val, allocator)) |ser| {
                    reportSerializeOnly("cmap_str_u64_x8 (writer)", ser.ns_samples, ser.bytes);
                }
            }

            {
                const M = bcs.CanonicalMap([32]u8, u64);
                var entries: [64]M.Entry = undefined;
                for (&entries, 0..) |*entry, i| {
                    var key: [32]u8 = .{0} ** 32;
                    key[0] = @intCast(i);
                    key[31] = @intCast(i ^ 0x5a);
                    entry.* = .{
                        .key = key,
                        .value = @intCast(i * 131),
                    };
                }
                const val = M.from(&entries);
                if (try benchSerializeWriter(M, val, allocator)) |ser| {
                    reportSerializeOnly("cmap_addr_u64_x64 (writer)", ser.ns_samples, ser.bytes);
                }
            }
        }
    }

    // Prevent global sink from being optimized away
    std.debug.print("  (checksum: {x})\n\n", .{sink});
}
