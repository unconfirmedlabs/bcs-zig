const bcs = @import("bcs");
const std = @import("std");

const RawNested = struct {
    id: u16,
    name: bcs.String,
    flag: bool,
};

const RawDeep = struct {
    inner: RawNested,
};

const MultiplySeed = struct {
    factor: u64,
    pub const Value = u64;

    pub fn deserialize(self: @This(), de: *bcs.SeedDeserializer) bcs.Error!u64 {
        return (try de.deserialize(u64)) * self.factor;
    }
};

const PrefixSeed = struct {
    prefix: []const u8,
    pub const Value = struct { text: []const u8 };

    pub fn deserialize(self: @This(), de: *bcs.SeedDeserializer) bcs.Error!Value {
        const input = try de.deserialize(bcs.String);
        errdefer bcs.freeDeserialized(bcs.String, de.allocator, input);

        const out = try de.allocator.alloc(u8, self.prefix.len + input.bytes.len);
        @memcpy(out[0..self.prefix.len], self.prefix);
        @memcpy(out[self.prefix.len..], input.bytes);
        bcs.freeDeserialized(bcs.String, de.allocator, input);
        return .{ .text = out };
    }

    pub fn free(_: @This(), allocator: std.mem.Allocator, value: Value) void {
        allocator.free(value.text);
    }
};

const NestedSeed = struct {
    scale: u32,
    prefix: []const u8,
    pub const Value = struct {
        scaled: u32,
        label: []const u8,
        flag: bool,
    };

    pub fn deserialize(self: @This(), de: *bcs.SeedDeserializer) bcs.Error!Value {
        const raw = try de.deserialize(RawNested);
        errdefer bcs.freeDeserialized(RawNested, de.allocator, raw);

        const label = try de.allocator.alloc(u8, self.prefix.len + raw.name.bytes.len);
        @memcpy(label[0..self.prefix.len], self.prefix);
        @memcpy(label[self.prefix.len..], raw.name.bytes);
        bcs.freeDeserialized(RawNested, de.allocator, raw);

        return .{
            .scaled = raw.id * self.scale,
            .label = label,
            .flag = raw.flag,
        };
    }

    pub fn free(_: @This(), allocator: std.mem.Allocator, value: Value) void {
        allocator.free(value.label);
    }
};

const DeepSeed = struct {
    prefix: []const u8,
    pub const Value = struct { text: []const u8 };

    pub fn deserialize(self: @This(), de: *bcs.SeedDeserializer) bcs.Error!Value {
        const raw = try de.deserialize(RawDeep);
        errdefer bcs.freeDeserialized(RawDeep, de.allocator, raw);

        const out = try de.allocator.alloc(u8, self.prefix.len + raw.inner.name.bytes.len);
        @memcpy(out[0..self.prefix.len], self.prefix);
        @memcpy(out[self.prefix.len..], raw.inner.name.bytes);
        bcs.freeDeserialized(RawDeep, de.allocator, raw);
        return .{ .text = out };
    }

    pub fn free(_: @This(), allocator: std.mem.Allocator, value: Value) void {
        allocator.free(value.text);
    }
};

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

fn s(bytes: []const u8) bcs.String {
    return bcs.String.init(bytes);
}

fn emitOk(name: []const u8, value: []const u8) void {
    std.debug.print("{s}=ok:{s}\n", .{ name, value });
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    {
        const bytes = try bcs.serialize(allocator, @as(u64, 42));
        defer allocator.free(bytes);
        const value = try bcs.deserializeSeed(MultiplySeed{ .factor = 3 }, allocator, bytes);
        std.debug.print("seed_u64=ok:{d}\n", .{value});
    }

    {
        const bytes = try bcs.serialize(allocator, s("coin"));
        defer allocator.free(bytes);
        const value = try bcs.deserializeSeed(PrefixSeed{ .prefix = "mod:" }, allocator, bytes);
        defer allocator.free(value.text);
        emitOk("seed_string", value.text);
    }

    {
        const bytes = try bcs.serialize(allocator, RawNested{
            .id = 7,
            .name = s("hello"),
            .flag = false,
        });
        defer allocator.free(bytes);
        const value = try bcs.deserializeSeed(NestedSeed{ .scale = 10, .prefix = "evt:" }, allocator, bytes);
        defer allocator.free(value.label);
        std.debug.print("seed_nested=ok:{d}:{s}:{d}\n", .{ value.scaled, value.label, @as(u8, if (value.flag) 1 else 0) });
    }

    blk: {
        const bytes = &[_]u8{ 42, 0, 0, 0, 0, 0, 0, 0, 0xff };
        _ = bcs.deserializeSeed(MultiplySeed{ .factor = 2 }, allocator, bytes) catch {
            std.debug.print("seed_trailing=err\n", .{});
            break :blk;
        };
        std.debug.print("seed_trailing=ok:unexpected\n", .{});
    }

    blk: {
        const bytes = try bcs.serialize(allocator, RawDeep{
            .inner = .{
                .id = 11,
                .name = s("x"),
                .flag = true,
            },
        });
        defer allocator.free(bytes);

        const ok = try bcs.deserializeSeedWithLimit(DeepSeed{ .prefix = "ctx:" }, allocator, bytes, 2);
        defer allocator.free(ok.text);
        emitOk("seed_limit_ok", ok.text);

        _ = bcs.deserializeSeedWithLimit(DeepSeed{ .prefix = "ctx:" }, allocator, bytes, 1) catch {
            std.debug.print("seed_limit_fail=err\n", .{});
            break :blk;
        };
        std.debug.print("seed_limit_fail=ok:unexpected\n", .{});
    }

    {
        const bytes = try bcs.serialize(allocator, s("coin"));
        defer allocator.free(bytes);
        var stream = std.io.fixedBufferStream(bytes);
        const value = try bcs.deserializeReaderSeed(PrefixSeed{ .prefix = "mod:" }, allocator, stream.reader());
        defer allocator.free(value.text);
        emitOk("seed_reader_string", value.text);
    }

    {
        const bytes = try bcs.serialize(allocator, RawNested{
            .id = 7,
            .name = s("hello"),
            .flag = false,
        });
        defer allocator.free(bytes);
        var reader = ChunkedReader{
            .bytes = bytes,
            .chunk = 2,
        };
        const value = try bcs.deserializeReaderSeed(NestedSeed{ .scale = 10, .prefix = "evt:" }, allocator, &reader);
        defer allocator.free(value.label);
        std.debug.print("seed_reader_nested=ok:{d}:{s}:{d}\n", .{ value.scaled, value.label, @as(u8, if (value.flag) 1 else 0) });
    }

    blk: {
        const bytes = try bcs.serialize(allocator, RawDeep{
            .inner = .{
                .id = 11,
                .name = s("x"),
                .flag = true,
            },
        });
        defer allocator.free(bytes);

        var ok_stream = std.io.fixedBufferStream(bytes);
        const ok = try bcs.deserializeReaderSeedWithLimit(DeepSeed{ .prefix = "ctx:" }, allocator, ok_stream.reader(), 2);
        defer allocator.free(ok.text);
        emitOk("seed_reader_limit_ok", ok.text);

        var fail_stream = std.io.fixedBufferStream(bytes);
        _ = bcs.deserializeReaderSeedWithLimit(DeepSeed{ .prefix = "ctx:" }, allocator, fail_stream.reader(), 1) catch {
            std.debug.print("seed_reader_limit_fail=err\n", .{});
            break :blk;
        };
        std.debug.print("seed_reader_limit_fail=ok:unexpected\n", .{});
    }
}
