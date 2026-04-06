const bcs = @import("bcs");
const std = @import("std");

const corpus = @embedFile("malformed_corpus.txt");

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

fn decodeHex(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;

    const bytes = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(bytes);

    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const hi = try std.fmt.charToDigit(hex[i * 2], 16);
        const lo = try std.fmt.charToDigit(hex[i * 2 + 1], 16);
        bytes[i] = @as(u8, @intCast((hi << 4) | lo));
    }
    return bytes;
}

fn dispatch(name: []const u8, ty: []const u8, raw: []const u8) void {
    if (std.mem.eql(u8, ty, "bool")) {
        emitStatus(bool, name, raw);
    } else if (std.mem.eql(u8, ty, "opt_u8")) {
        emitStatus(?u8, name, raw);
    } else if (std.mem.eql(u8, ty, "string")) {
        emitStatus(bcs.String, name, raw);
    } else if (std.mem.eql(u8, ty, "bytes")) {
        emitStatus([]const u8, name, raw);
    } else if (std.mem.eql(u8, ty, "vec_u16")) {
        emitStatus([]const u16, name, raw);
    } else if (std.mem.eql(u8, ty, "tuple_u32_bool")) {
        emitStatus(struct { u32, bool }, name, raw);
    } else if (std.mem.eql(u8, ty, "mut_enum")) {
        emitStatus(MutationEnum, name, raw);
    } else if (std.mem.eql(u8, ty, "nested")) {
        emitStatus(Nested, name, raw);
    } else if (std.mem.eql(u8, ty, "map_u8_unit")) {
        emitStatus(bcs.Map(u8, void), name, raw);
    } else if (std.mem.eql(u8, ty, "map_string_u32")) {
        emitStatus(bcs.Map(bcs.String, u32), name, raw);
    } else {
        unreachable;
    }
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        var parts = std.mem.splitScalar(u8, line, '|');
        const name = parts.next() orelse return error.InvalidCorpus;
        const ty = parts.next() orelse return error.InvalidCorpus;
        const hex = parts.next() orelse return error.InvalidCorpus;
        if (parts.next() != null) return error.InvalidCorpus;

        const bytes = try decodeHex(allocator, hex);
        defer allocator.free(bytes);

        dispatch(name, ty, bytes);
    }
}
