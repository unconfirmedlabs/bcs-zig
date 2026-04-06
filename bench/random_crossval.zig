const bcs = @import("bcs");
const std = @import("std");

comptime {
    @setEvalBranchQuota(10_000);
}

const ser_cases = 128;
const de_cases = 256;
const seed: u64 = 0x5eed_cafe_d00d_f00d;
const ascii = "abcxyz012_";

const FuzzStruct = struct {
    a: u64,
    b: bool,
    c: []const u16,
    d: ?[4]u8,
};

const FuzzEnum = union(enum) {
    Unit,
    U64: u64,
    Bytes: [4]u8,
    Pair: struct { a: u16, b: u8 },
};

const DeepStruct = struct {
    label: bcs.String,
    nested: FuzzStruct,
    variant: FuzzEnum,
    tags: []const bcs.String,
};

const Rng = struct {
    state: u64,

    fn init(s: u64) Rng {
        return .{ .state = s };
    }

    fn nextU64(self: *Rng) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545_F491_4F6C_DD1D;
    }

    fn nextBool(self: *Rng) bool {
        return self.nextU64() & 1 == 1;
    }

    fn nextU8(self: *Rng) u8 {
        return @truncate(self.nextU64());
    }

    fn nextU16(self: *Rng) u16 {
        return @truncate(self.nextU64());
    }

    fn nextU32(self: *Rng) u32 {
        return @truncate(self.nextU64());
    }

    fn range(self: *Rng, limit: usize) usize {
        if (limit == 0) return 0;
        return @intCast(self.nextU64() % limit);
    }
};

fn emitBytes(name: []const u8, bytes: []const u8) void {
    std.debug.print("{s}=", .{name});
    for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}

fn emitSerialized(name: []const u8, value: anytype) !void {
    const allocator = std.heap.c_allocator;
    const bytes = try bcs.serialize(allocator, value);
    defer allocator.free(bytes);
    emitBytes(name, bytes);
}

fn emitStatus(comptime T: type, name: []const u8, raw: []const u8) void {
    const allocator = std.heap.c_allocator;
    const value = bcs.deserialize(T, allocator, raw) catch {
        std.debug.print("{s}=err\n", .{name});
        return;
    };
    defer bcs.freeDeserialized(T, allocator, value);

    const encoded = bcs.serialize(allocator, value) catch {
        std.debug.print("{s}=err\n", .{name});
        return;
    };
    defer allocator.free(encoded);
    std.debug.print("{s}=ok:", .{name});
    for (encoded) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}

fn allocBytes(allocator: std.mem.Allocator, rng: *Rng, max_len: usize) ![]const u8 {
    const len = rng.range(max_len + 1);
    const bytes = try allocator.alloc(u8, len);
    for (bytes) |*byte| byte.* = rng.nextU8();
    return bytes;
}

fn allocAsciiString(allocator: std.mem.Allocator, rng: *Rng, max_len: usize) !bcs.String {
    const len = rng.range(max_len + 1);
    const bytes = try allocator.alloc(u8, len);
    for (bytes) |*byte| byte.* = ascii[rng.range(ascii.len)];
    return bcs.String.init(bytes);
}

fn allocU16Vec(allocator: std.mem.Allocator, rng: *Rng, max_len: usize) ![]const u16 {
    const len = rng.range(max_len + 1);
    const values = try allocator.alloc(u16, len);
    for (values) |*value| value.* = rng.nextU16();
    return values;
}

fn allocVecVecU8(allocator: std.mem.Allocator, rng: *Rng, max_outer: usize, max_inner: usize) ![]const []const u8 {
    const len = rng.range(max_outer + 1);
    const values = try allocator.alloc([]const u8, len);
    for (values) |*value| value.* = try allocBytes(allocator, rng, max_inner);
    return values;
}

fn allocStringVec(allocator: std.mem.Allocator, rng: *Rng, max_len: usize, max_str_len: usize) ![]const bcs.String {
    const len = rng.range(max_len + 1);
    const values = try allocator.alloc(bcs.String, len);
    for (values) |*value| value.* = try allocAsciiString(allocator, rng, max_str_len);
    return values;
}

fn genOptU64(rng: *Rng) ?u64 {
    if (rng.nextBool()) return rng.nextU64();
    return null;
}

fn genArr4(rng: *Rng) [4]u8 {
    return .{ rng.nextU8(), rng.nextU8(), rng.nextU8(), rng.nextU8() };
}

fn allocFuzzStruct(allocator: std.mem.Allocator, rng: *Rng) !FuzzStruct {
    return .{
        .a = rng.nextU64(),
        .b = rng.nextBool(),
        .c = try allocU16Vec(allocator, rng, 6),
        .d = if (rng.nextBool()) genArr4(rng) else null,
    };
}

fn allocDeepStruct(allocator: std.mem.Allocator, rng: *Rng) !DeepStruct {
    return .{
        .label = try allocAsciiString(allocator, rng, 10),
        .nested = try allocFuzzStruct(allocator, rng),
        .variant = genFuzzEnum(rng),
        .tags = try allocStringVec(allocator, rng, 5, 6),
    };
}

fn genFuzzEnum(rng: *Rng) FuzzEnum {
    return switch (rng.range(4)) {
        0 => .Unit,
        1 => .{ .U64 = rng.nextU64() },
        2 => .{ .Bytes = genArr4(rng) },
        else => .{ .Pair = .{ .a = rng.nextU16(), .b = rng.nextU8() } },
    };
}

fn allocMapU8U16(allocator: std.mem.Allocator, rng: *Rng, max_len: usize) !bcs.Map(u8, u16) {
    const M = bcs.Map(u8, u16);
    const len = rng.range(max_len + 1);
    const entries = try allocator.alloc(M.Entry, len);
    for (entries) |*entry| {
        entry.* = .{
            .key = rng.nextU8() % 5,
            .value = rng.nextU16(),
        };
    }
    return M.from(entries);
}

fn allocMapStringU32(allocator: std.mem.Allocator, rng: *Rng, max_len: usize) !bcs.Map(bcs.String, u32) {
    const M = bcs.Map(bcs.String, u32);
    const len = rng.range(max_len + 1);
    const entries = try allocator.alloc(M.Entry, len);
    for (entries) |*entry| {
        entry.* = .{
            .key = try allocAsciiString(allocator, rng, 4),
            .value = rng.nextU32(),
        };
    }
    return M.from(entries);
}

pub fn main() !void {
    var ser_rng = Rng.init(seed);

    for (0..ser_cases) |i| {
        {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_bool_{d:0>3}", .{i});
            try emitSerialized(name, ser_rng.nextBool());
        }
        {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_u64_{d:0>3}", .{i});
            try emitSerialized(name, ser_rng.nextU64());
        }
        {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_i64_{d:0>3}", .{i});
            try emitSerialized(name, @as(i64, @bitCast(ser_rng.nextU64())));
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_string_{d:0>3}", .{i});
            try emitSerialized(name, try allocAsciiString(arena.allocator(), &ser_rng, 12));
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_bytes_{d:0>3}", .{i});
            try emitSerialized(name, try allocBytes(arena.allocator(), &ser_rng, 16));
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_vec_u16_{d:0>3}", .{i});
            try emitSerialized(name, try allocU16Vec(arena.allocator(), &ser_rng, 8));
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_vec_vec_u8_{d:0>3}", .{i});
            try emitSerialized(name, try allocVecVecU8(arena.allocator(), &ser_rng, 4, 8));
        }
        {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_opt_u64_{d:0>3}", .{i});
            try emitSerialized(name, genOptU64(&ser_rng));
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_struct_{d:0>3}", .{i});
            try emitSerialized(name, try allocFuzzStruct(arena.allocator(), &ser_rng));
        }
        {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_enum_{d:0>3}", .{i});
            try emitSerialized(name, genFuzzEnum(&ser_rng));
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [36]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_map_u8_u16_{d:0>3}", .{i});
            try emitSerialized(name, try allocMapU8U16(arena.allocator(), &ser_rng, 6));
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [40]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_map_string_u32_{d:0>3}", .{i});
            try emitSerialized(name, try allocMapStringU32(arena.allocator(), &ser_rng, 6));
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [40]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "ser_deep_struct_{d:0>3}", .{i});
            try emitSerialized(name, try allocDeepStruct(arena.allocator(), &ser_rng));
        }
    }

    var de_rng = Rng.init(seed ^ 0x9e37_79b9_7f4a_7c15);

    for (0..de_cases) |i| {
        var raw_buf: [24]u8 = undefined;
        const raw_len = de_rng.range(raw_buf.len + 1);
        for (raw_buf[0..raw_len]) |*byte| byte.* = de_rng.nextU8();
        const raw = raw_buf[0..raw_len];

        {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_bool_{d:0>3}", .{i});
            emitStatus(bool, name, raw);
        }
        {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_opt_u8_{d:0>3}", .{i});
            emitStatus(?u8, name, raw);
        }
        {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_string_{d:0>3}", .{i});
            emitStatus(bcs.String, name, raw);
        }
        {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_vec_u8_{d:0>3}", .{i});
            emitStatus([]const u8, name, raw);
        }
        {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_vec_u16_{d:0>3}", .{i});
            emitStatus([]const u16, name, raw);
        }
        {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_enum_{d:0>3}", .{i});
            emitStatus(FuzzEnum, name, raw);
        }
        {
            var name_buf: [36]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_tuple_pair_{d:0>3}", .{i});
            emitStatus(struct { u32, bool }, name, raw);
        }
        {
            var name_buf: [40]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_map_u8_unit_{d:0>3}", .{i});
            emitStatus(bcs.Map(u8, void), name, raw);
        }
        {
            var name_buf: [36]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_struct_{d:0>3}", .{i});
            emitStatus(FuzzStruct, name, raw);
        }
        {
            var name_buf: [40]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_deep_struct_{d:0>3}", .{i});
            emitStatus(DeepStruct, name, raw);
        }
        {
            var name_buf: [36]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_map_u8_u16_{d:0>3}", .{i});
            emitStatus(bcs.Map(u8, u16), name, raw);
        }
        {
            var name_buf: [40]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "de_map_string_u32_{d:0>3}", .{i});
            emitStatus(bcs.Map(bcs.String, u32), name, raw);
        }
    }
}
