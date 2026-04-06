const bcs = @import("bcs");
const std = @import("std");

const cases = 48;
const seed: u64 = 0x1234_5678_9abc_def0;
const ascii = "abcxyz012_";

const MutationEnum = union(enum) {
    Unit,
    U64: u64,
    Bytes: [4]u8,
    Pair: struct { a: u16, b: u8 },
};

const Nested = struct {
    id: u16,
    names: []const bcs.String,
    flag: bool,
};

const DeepStruct = struct {
    label: bcs.String,
    nested: Nested,
    variant: MutationEnum,
    payload: []const u16,
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

    fn nextU8(self: *Rng) u8 {
        return @truncate(self.nextU64());
    }

    fn nextU16(self: *Rng) u16 {
        return @truncate(self.nextU64());
    }

    fn nextU32(self: *Rng) u32 {
        return @truncate(self.nextU64());
    }

    fn nextBool(self: *Rng) bool {
        return self.nextU64() & 1 == 1;
    }

    fn range(self: *Rng, limit: usize) usize {
        if (limit == 0) return 0;
        return @intCast(self.nextU64() % limit);
    }
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

fn emitStatus(comptime T: type, name: []const u8, raw: []const u8) void {
    const allocator = std.heap.c_allocator;
    const value = bcs.deserialize(T, allocator, raw) catch |err| {
        std.debug.print("{s}=err:{s}\n", .{ name, errName(err) });
        return;
    };
    defer bcs.freeDeserialized(T, allocator, value);

    const encoded = bcs.serialize(allocator, value) catch |err| {
        std.debug.print("{s}=err:{s}\n", .{ name, errName(err) });
        return;
    };
    defer allocator.free(encoded);

    std.debug.print("{s}=ok:", .{name});
    for (encoded) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}

fn emitMutations(comptime T: type, base_name: []const u8, value: T, rng: *Rng) !void {
    const allocator = std.heap.c_allocator;
    const bytes = try bcs.serialize(allocator, value);
    defer allocator.free(bytes);

    {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_base", .{base_name});
        emitStatus(T, name, bytes);
    }

    if (bytes.len > 0) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_cut1", .{base_name});
        emitStatus(T, name, bytes[0 .. bytes.len - 1]);
    }

    if (bytes.len > 0) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_cutm", .{base_name});
        emitStatus(T, name, bytes[0 .. bytes.len / 2]);
    }

    {
        var appended = try allocator.alloc(u8, bytes.len + 1);
        defer allocator.free(appended);
        @memcpy(appended[0..bytes.len], bytes);
        appended[bytes.len] = rng.nextU8();

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_app", .{base_name});
        emitStatus(T, name, appended);
    }

    {
        const insert_pos = rng.range(bytes.len + 1);
        var inserted = try allocator.alloc(u8, bytes.len + 1);
        defer allocator.free(inserted);
        @memcpy(inserted[0..insert_pos], bytes[0..insert_pos]);
        inserted[insert_pos] = rng.nextU8();
        @memcpy(inserted[insert_pos + 1 ..], bytes[insert_pos..]);

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_ins", .{base_name});
        emitStatus(T, name, inserted);
    }

    if (bytes.len > 0) {
        const xor_pos = rng.range(bytes.len);
        var xored = try allocator.dupe(u8, bytes);
        defer allocator.free(xored);
        var mask: u8 = @as(u8, 1) << @intCast(rng.range(8));
        if (mask == 0) mask = 1;
        xored[xor_pos] ^= mask;

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_xor", .{base_name});
        emitStatus(T, name, xored);
    }

    if (bytes.len > 0) {
        const zero_pos = rng.range(bytes.len);
        var zeroed = try allocator.dupe(u8, bytes);
        defer allocator.free(zeroed);
        zeroed[zero_pos] = 0;

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_zero", .{base_name});
        emitStatus(T, name, zeroed);
    }

    if (bytes.len > 0) {
        const dup_pos = rng.range(bytes.len);
        var duplicated = try allocator.alloc(u8, bytes.len + 1);
        defer allocator.free(duplicated);
        @memcpy(duplicated[0..dup_pos], bytes[0..dup_pos]);
        duplicated[dup_pos] = bytes[dup_pos];
        @memcpy(duplicated[dup_pos + 1 ..], bytes[dup_pos..]);

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_dup", .{base_name});
        emitStatus(T, name, duplicated);
    }

    if (bytes.len > 0) {
        const del_pos = rng.range(bytes.len);
        var deleted = try allocator.alloc(u8, bytes.len - 1);
        defer allocator.free(deleted);
        @memcpy(deleted[0..del_pos], bytes[0..del_pos]);
        @memcpy(deleted[del_pos..], bytes[del_pos + 1 ..]);

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{s}_del", .{base_name});
        emitStatus(T, name, deleted);
    }
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

fn allocStringVec(allocator: std.mem.Allocator, rng: *Rng, max_len: usize, max_str_len: usize) ![]const bcs.String {
    const len = rng.range(max_len + 1);
    const values = try allocator.alloc(bcs.String, len);
    for (values) |*value| value.* = try allocAsciiString(allocator, rng, max_str_len);
    return values;
}

fn allocDeepStruct(allocator: std.mem.Allocator, rng: *Rng) !DeepStruct {
    return .{
        .label = try allocAsciiString(allocator, rng, 10),
        .nested = .{
            .id = rng.nextU16(),
            .names = try allocStringVec(allocator, rng, 4, 5),
            .flag = rng.nextBool(),
        },
        .variant = genEnum(rng),
        .payload = try allocU16Vec(allocator, rng, 10),
    };
}

fn allocMapU8U16(allocator: std.mem.Allocator, rng: *Rng, max_len: usize) !bcs.Map(u8, u16) {
    const M = bcs.Map(u8, u16);
    const len = rng.range(max_len + 1);
    const base = rng.nextU8();
    const entries = try allocator.alloc(M.Entry, len);
    for (entries, 0..) |*entry, i| {
        entry.* = .{
            .key = base +% (@as(u8, @intCast(i)) *% 17 +% 1),
            .value = rng.nextU16(),
        };
    }
    return M.from(entries);
}

fn allocMapStringU32(allocator: std.mem.Allocator, rng: *Rng, max_len: usize) !bcs.Map(bcs.String, u32) {
    const M = bcs.Map(bcs.String, u32);
    const len = rng.range(max_len + 1);
    const entries = try allocator.alloc(M.Entry, len);
    for (entries, 0..) |*entry, i| {
        const suffix = try allocAsciiString(allocator, rng, 5);
        const key_bytes = try allocator.alloc(u8, suffix.bytes.len + 1);
        key_bytes[0] = 'a' + @as(u8, @intCast(i));
        @memcpy(key_bytes[1..], suffix.bytes);
        entry.* = .{
            .key = bcs.String.init(key_bytes),
            .value = rng.nextU32(),
        };
    }
    return M.from(entries);
}

fn genEnum(rng: *Rng) MutationEnum {
    return switch (rng.range(4)) {
        0 => .Unit,
        1 => .{ .U64 = rng.nextU64() },
        2 => .{ .Bytes = .{ rng.nextU8(), rng.nextU8(), rng.nextU8(), rng.nextU8() } },
        else => .{ .Pair = .{ .a = rng.nextU16(), .b = rng.nextU8() } },
    };
}

pub fn main() !void {
    var rng = Rng.init(seed);

    for (0..cases) |i| {
        {
            var name_buf: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "mut_bool_{d:0>3}", .{i});
            try emitMutations(bool, name, rng.nextBool(), &rng);
        }
        {
            var name_buf: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "mut_opt_u64_{d:0>3}", .{i});
            const value: ?u64 = if (rng.nextBool()) rng.nextU64() else null;
            try emitMutations(?u64, name, value, &rng);
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "mut_string_{d:0>3}", .{i});
            try emitMutations(bcs.String, name, try allocAsciiString(arena.allocator(), &rng, 12), &rng);
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "mut_vec_u16_{d:0>3}", .{i});
            try emitMutations([]const u16, name, try allocU16Vec(arena.allocator(), &rng, 8), &rng);
        }
        {
            var name_buf: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "mut_enum_{d:0>3}", .{i});
            try emitMutations(MutationEnum, name, genEnum(&rng), &rng);
        }
        {
            var name_buf: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "mut_tuple_pair_{d:0>3}", .{i});
            try emitMutations(struct { u32, bool }, name, .{ rng.nextU32(), rng.nextBool() }, &rng);
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "mut_nested_{d:0>3}", .{i});
            try emitMutations(Nested, name, .{
                .id = rng.nextU16(),
                .names = try allocStringVec(arena.allocator(), &rng, 4, 5),
                .flag = rng.nextBool(),
            }, &rng);
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "mut_map_u8_u16_{d:0>3}", .{i});
            try emitMutations(bcs.Map(u8, u16), name, try allocMapU8U16(arena.allocator(), &rng, 6), &rng);
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [56]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "mut_map_string_u32_{d:0>3}", .{i});
            try emitMutations(bcs.Map(bcs.String, u32), name, try allocMapStringU32(arena.allocator(), &rng, 6), &rng);
        }
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
            defer arena.deinit();
            var name_buf: [56]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "mut_deep_struct_{d:0>3}", .{i});
            try emitMutations(DeepStruct, name, try allocDeepStruct(arena.allocator(), &rng), &rng);
        }
    }
}
