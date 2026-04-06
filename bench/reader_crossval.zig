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

fn emitHex(name: []const u8, bytes: []const u8) void {
    std.debug.print("{s}=ok:", .{name});
    for (bytes) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
}

fn emitErr(name: []const u8) void {
    std.debug.print("{s}=err\n", .{name});
}

fn emitStatus(comptime T: type, allocator: std.mem.Allocator, name: []const u8, raw: []const u8) void {
    var stream = std.io.fixedBufferStream(raw);
    const value = bcs.deserializeReader(T, allocator, stream.reader()) catch {
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

fn emitStatusWithLimit(comptime T: type, allocator: std.mem.Allocator, name: []const u8, raw: []const u8, limit: usize) void {
    var stream = std.io.fixedBufferStream(raw);
    const value = bcs.deserializeReaderWithLimit(T, allocator, stream.reader(), limit) catch {
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

const ChunkedReader = struct {
    bytes: []const u8,
    pos: usize = 0,
    chunk: usize,

    pub fn readByte(self: *@This()) error{EndOfStream}!u8 {
        if (self.pos >= self.bytes.len) return error.EndOfStream;
        const byte = self.bytes[self.pos];
        self.pos += 1;
        return byte;
    }
};

fn emitChunkedStatus(comptime T: type, allocator: std.mem.Allocator, name: []const u8, raw: []const u8, chunk: usize) void {
    var reader = ChunkedReader{
        .bytes = raw,
        .chunk = chunk,
    };
    _ = reader.chunk;
    const value = bcs.deserializeReader(T, allocator, &reader) catch {
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

fn s(bytes: []const u8) bcs.String {
    return bcs.String.init(bytes);
}

pub fn main() void {
    const allocator = std.heap.c_allocator;
    const KeySet = bcs.Map(u8, void);
    const StringMap = bcs.Map(bcs.String, u8);

    emitStatus(bool, allocator, "reader_bool_true", &.{0x01});
    emitStatus(bool, allocator, "reader_bool_invalid", &.{0x02});
    emitStatus(u8, allocator, "reader_u8_trailing", &.{ 0x01, 0x02 });

    emitStatus(?u8, allocator, "reader_opt_some_u8", &.{ 0x01, 0x2a });
    emitStatus(?u8, allocator, "reader_opt_invalid_tag", &.{0x05});

    emitStatus(bcs.String, allocator, "reader_string_utf8", &.{ 0x05, 'h', 'e', 'l', 'l', 'o' });
    emitStatus(bcs.String, allocator, "reader_string_invalid_utf8", &.{ 0x02, 0xc0, 0x80 });
    emitStatus([]const u8, allocator, "reader_bytes_invalid_utf8", &.{ 0x02, 0xc0, 0x80 });

    emitStatus(TinyEnum, allocator, "reader_enum_unit", &.{0x00});
    emitStatus(TinyEnum, allocator, "reader_enum_value", &.{ 0x01, 0x34, 0x12, 0, 0, 0, 0, 0, 0 });
    emitStatus(TinyEnum, allocator, "reader_enum_invalid_tag", &.{0x02});

    emitStatus([]const u16, allocator, "reader_vec_u16_ok", &.{ 0x02, 0x01, 0x00, 0x02, 0x00 });
    emitStatus([]const u16, allocator, "reader_vec_u16_short", &.{ 0x02, 0x01, 0x00 });

    emitStatus(struct { u32, bool }, allocator, "reader_tuple_pair", &.{ 0x2a, 0x00, 0x00, 0x00, 0x01 });

    {
        const bytes = bcs.serialize(allocator, Nested{
            .id = 7,
            .names = &.{ s("hi"), s("there") },
            .flag = true,
        }) catch {
            emitErr("reader_nested");
            return;
        };
        defer allocator.free(bytes);
        emitStatus(Nested, allocator, "reader_nested", bytes);
    }

    emitStatus(KeySet, allocator, "reader_map_empty", &.{0x00});
    emitStatus(KeySet, allocator, "reader_map_canonical", &.{ 0x02, 0x04, 0x05 });
    emitStatus(KeySet, allocator, "reader_map_out_of_order", &.{ 0x02, 0x05, 0x04 });

    {
        const entries = [_]StringMap.Entry{
            .{ .key = s("alpha"), .value = 1 },
            .{ .key = s("beta"), .value = 2 },
        };
        const bytes = bcs.serialize(allocator, StringMap.from(&entries)) catch {
            emitErr("reader_map_string");
            return;
        };
        defer allocator.free(bytes);
        emitStatus(StringMap, allocator, "reader_map_string", bytes);
    }

    {
        const bytes = bcs.serialize(allocator, Nested{
            .id = 9,
            .names = &.{ s("a"), s("bb"), s("ccc") },
            .flag = false,
        }) catch {
            emitErr("reader_chunked_nested");
            return;
        };
        defer allocator.free(bytes);
        emitChunkedStatus(Nested, allocator, "reader_chunked_nested", bytes, 2);
    }

    {
        const entries = [_]StringMap.Entry{
            .{ .key = s("eta"), .value = 7 },
            .{ .key = s("theta"), .value = 8 },
        };
        const bytes = bcs.serialize(allocator, StringMap.from(&entries)) catch {
            emitErr("reader_chunked_map_string");
            return;
        };
        defer allocator.free(bytes);
        emitChunkedStatus(StringMap, allocator, "reader_chunked_map_string", bytes, 3);
    }

    {
        const bytes = bcs.serialize(allocator, Nested{
            .id = 11,
            .names = &.{s("x")},
            .flag = true,
        }) catch {
            emitErr("reader_limit_ok");
            emitErr("reader_limit_fail");
            return;
        };
        defer allocator.free(bytes);
        emitStatusWithLimit(Nested, allocator, "reader_limit_ok", bytes, 2);
        emitStatusWithLimit(Nested, allocator, "reader_limit_fail", bytes, 0);
    }
}
