const std = @import("std");
const Allocator = std.mem.Allocator;

// ── BCS Constants ──────────────────────────────────────────────────────

pub const max_sequence_length: u32 = (1 << 31) - 1;
pub const max_container_depth: u32 = 500;

// ── Errors ─────────────────────────────────────────────────────────────

pub const Error = error{
    InvalidBool,
    NonCanonicalUleb128,
    Uleb128Overflow,
    SequenceTooLong,
    ContainerTooDeep,
    UnexpectedEndOfInput,
    TrailingBytes,
    InvalidEnumTag,
    InvalidOptionTag,
    NonCanonicalMap,
    OutOfMemory,
};

// ── Map Type ───────────────────────────────────────────────────────────

/// A BCS-compatible sorted map. Entries are serialized in lexicographic
/// order of their BCS-encoded keys (canonical encoding).
pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const bcs_map = true;
        pub const Key = K;
        pub const Value = V;
        pub const Entry = struct { key: K, value: V };

        entries: []const Entry,

        pub fn from(entries: []const Entry) Self {
            return .{ .entries = entries };
        }
    };
}

// ── Public API ─────────────────────────────────────────────────────────

/// Serialize any BCS-compatible value to bytes.
pub fn serialize(allocator: Allocator, value: anytype) Error![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);
    try serializeValue(allocator, &list, value, 0);
    return list.toOwnedSlice(allocator) catch Error.OutOfMemory;
}

/// Deserialize bytes into a typed value.
/// Pass an allocator for types containing slices; unused for fixed-size types.
pub fn deserialize(comptime T: type, allocator: Allocator, bytes: []const u8) Error!T {
    var reader = Reader{ .data = bytes, .pos = 0 };
    const value = try deserializeValue(T, allocator, &reader, 0);
    if (reader.pos != reader.data.len) {
        freeDeserialized(T, allocator, value);
        return Error.TrailingBytes;
    }
    return value;
}

/// Deserialize without checking for trailing bytes. Returns value and bytes consumed.
pub fn deserializePartial(comptime T: type, allocator: Allocator, bytes: []const u8) Error!struct { value: T, bytes_read: usize } {
    var reader = Reader{ .data = bytes, .pos = 0 };
    const value = try deserializeValue(T, allocator, &reader, 0);
    return .{ .value = value, .bytes_read = reader.pos };
}

/// Free all heap-allocated memory within a deserialized value.
pub fn freeDeserialized(comptime T: type, allocator: Allocator, value: T) void {
    const info = @typeInfo(T);
    switch (info) {
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice) {
                if (ptr_info.child != u8) {
                    for (value) |elem| freeDeserialized(ptr_info.child, allocator, elem);
                }
                allocator.free(value);
            }
        },
        .optional => |opt_info| {
            if (value) |v| freeDeserialized(opt_info.child, allocator, v);
        },
        .@"struct" => |struct_info| {
            if (@hasDecl(T, "bcs_map") and T.bcs_map) {
                for (value.entries) |entry| {
                    freeDeserialized(T.Key, allocator, entry.key);
                    freeDeserialized(T.Value, allocator, entry.value);
                }
                allocator.free(value.entries);
            } else {
                inline for (struct_info.fields) |field| {
                    freeDeserialized(field.type, allocator, @field(value, field.name));
                }
            }
        },
        .@"union" => |union_info| {
            if (union_info.tag_type != null) {
                const tag = std.meta.activeTag(value);
                inline for (union_info.fields) |field| {
                    if (comptime std.meta.stringToEnum(std.meta.Tag(T), field.name)) |this_tag| {
                        if (tag == this_tag and field.type != void) {
                            freeDeserialized(field.type, allocator, @field(value, field.name));
                        }
                    }
                }
            }
        },
        else => {},
    }
}

// ── ULEB128 ────────────────────────────────────────────────────────────

fn uleb128Append(allocator: Allocator, list: *std.ArrayList(u8), value: u32) Error!void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(v & 0x7f);
        v >>= 7;
        if (v == 0) {
            list.append(allocator, byte) catch return Error.OutOfMemory;
            return;
        }
        list.append(allocator, byte | 0x80) catch return Error.OutOfMemory;
    }
}

fn uleb128Read(reader: *Reader) Error!u32 {
    var result: u64 = 0;
    var shift: u6 = 0;
    for (0..5) |i| {
        const byte = try reader.readByte();
        const payload: u64 = byte & 0x7f;
        result |= payload << shift;
        if (byte & 0x80 == 0) {
            if (i > 0 and byte == 0) return Error.NonCanonicalUleb128;
            if (result > std.math.maxInt(u32)) return Error.Uleb128Overflow;
            return @intCast(result);
        }
        shift += 7;
    }
    return Error.Uleb128Overflow;
}

// ── Reader ─────────────────────────────────────────────────────────────

pub const Reader = struct {
    data: []const u8,
    pos: usize,

    pub fn readByte(self: *Reader) Error!u8 {
        if (self.pos >= self.data.len) return Error.UnexpectedEndOfInput;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readBytes(self: *Reader, n: usize) Error![]const u8 {
        if (self.pos + n > self.data.len) return Error.UnexpectedEndOfInput;
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }
};

// ── Integer Helpers ────────────────────────────────────────────────────

fn writeIntLittle(allocator: Allocator, list: *std.ArrayList(u8), comptime T: type, value: T) Error!void {
    const info = @typeInfo(T).int;
    const byte_count = comptime @divExact(info.bits, 8);
    const U = @Type(.{ .int = .{ .signedness = .unsigned, .bits = info.bits } });
    const uvalue: U = @bitCast(value);
    var buf: [byte_count]u8 = undefined;
    inline for (0..byte_count) |i| {
        buf[i] = @truncate(uvalue >> @intCast(i * 8));
    }
    list.appendSlice(allocator, &buf) catch return Error.OutOfMemory;
}

fn readIntLittle(comptime T: type, reader: *Reader) Error!T {
    const info = @typeInfo(T).int;
    const byte_count = comptime @divExact(info.bits, 8);
    const U = @Type(.{ .int = .{ .signedness = .unsigned, .bits = info.bits } });

    if (reader.pos + byte_count > reader.data.len) return Error.UnexpectedEndOfInput;
    var result: U = 0;
    inline for (0..byte_count) |i| {
        result |= @as(U, reader.data[reader.pos + i]) << @intCast(i * 8);
    }
    reader.pos += byte_count;
    return @bitCast(result);
}

// ── Helpers ────────────────────────────────────────────────────────────

fn serializeToBytes(allocator: Allocator, value: anytype, depth: u32) Error![]u8 {
    var temp: std.ArrayList(u8) = .{};
    errdefer temp.deinit(allocator);
    try serializeValue(allocator, &temp, value, depth);
    return temp.toOwnedSlice(allocator) catch Error.OutOfMemory;
}

// ── Map Serialize/Deserialize ──────────────────────────────────────────

fn serializeMap(comptime K: type, comptime V: type, allocator: Allocator, list: *std.ArrayList(u8), entries: anytype, depth: u32) Error!void {
    const count: u32 = @intCast(entries.len);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const SortItem = struct { key_bytes: []u8, index: usize };
    const sort_items = allocator.alloc(SortItem, count) catch return Error.OutOfMemory;
    var initialized: usize = 0;
    defer {
        for (sort_items[0..initialized]) |item| allocator.free(item.key_bytes);
        allocator.free(sort_items);
    }

    for (entries, 0..) |entry, i| {
        sort_items[i] = .{
            .key_bytes = try serializeToBytes(allocator, entry.key, depth),
            .index = i,
        };
        initialized = i + 1;
    }

    std.mem.sort(SortItem, sort_items, {}, struct {
        fn order(_: void, a: SortItem, b: SortItem) bool {
            return std.mem.order(u8, a.key_bytes, b.key_bytes) == .lt;
        }
    }.order);

    try uleb128Append(allocator, list, count);
    for (sort_items) |item| {
        list.appendSlice(allocator, item.key_bytes) catch return Error.OutOfMemory;
        try serializeValue(allocator, list, entries[item.index].value, depth);
    }
    _ = K;
    _ = V;
}

fn deserializeMap(comptime K: type, comptime V: type, allocator: Allocator, reader: *Reader, depth: u32) Error!Map(K, V) {
    const count = try uleb128Read(reader);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const EntryType = Map(K, V).Entry;
    const entries = allocator.alloc(EntryType, count) catch return Error.OutOfMemory;

    var prev_key_end: usize = 0;
    var prev_key_start: usize = 0;

    for (entries, 0..) |*entry, i| {
        const key_start = reader.pos;
        entry.key = try deserializeValue(K, allocator, reader, depth);
        const key_end = reader.pos;

        if (i > 0) {
            const prev = reader.data[prev_key_start..prev_key_end];
            const curr = reader.data[key_start..key_end];
            if (std.mem.order(u8, prev, curr) != .lt) {
                // Free what we've allocated so far
                for (entries[0 .. i + 1]) |e| freeDeserialized(K, allocator, e.key);
                allocator.free(entries);
                return Error.NonCanonicalMap;
            }
        }

        prev_key_start = key_start;
        prev_key_end = key_end;

        entry.value = try deserializeValue(V, allocator, reader, depth);
    }

    return Map(K, V){ .entries = entries };
}

// ── Serialize ──────────────────────────────────────────────────────────

fn serializeValue(allocator: Allocator, list: *std.ArrayList(u8), value: anytype, depth: u32) Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .bool => list.append(allocator, if (value) @as(u8, 1) else @as(u8, 0)) catch return Error.OutOfMemory,

        .int => try writeIntLittle(allocator, list, T, value),

        .optional => {
            if (value) |v| {
                list.append(allocator, 0x01) catch return Error.OutOfMemory;
                try serializeValue(allocator, list, v, depth);
            } else {
                list.append(allocator, 0x00) catch return Error.OutOfMemory;
            }
        },

        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    if (value.len > max_sequence_length) return Error.SequenceTooLong;
                    try uleb128Append(allocator, list, @intCast(value.len));
                    if (ptr_info.child == u8) {
                        list.appendSlice(allocator, value) catch return Error.OutOfMemory;
                    } else {
                        for (value) |elem| {
                            try serializeValue(allocator, list, elem, depth);
                        }
                    }
                },
                .one => try serializeValue(allocator, list, value.*, depth),
                else => @compileError("BCS: unsupported pointer type " ++ @typeName(T)),
            }
        },

        .array => |arr_info| {
            if (arr_info.child == u8) {
                list.appendSlice(allocator, &value) catch return Error.OutOfMemory;
            } else {
                for (value) |elem| {
                    try serializeValue(allocator, list, elem, depth);
                }
            }
        },

        .@"struct" => |struct_info| {
            if (@hasDecl(T, "bcs_map") and T.bcs_map) {
                try serializeMap(T.Key, T.Value, allocator, list, value.entries, depth);
            } else if (struct_info.is_tuple) {
                inline for (struct_info.fields) |field| {
                    try serializeValue(allocator, list, @field(value, field.name), depth);
                }
            } else {
                const new_depth = depth + 1;
                if (new_depth > max_container_depth) return Error.ContainerTooDeep;
                inline for (struct_info.fields) |field| {
                    try serializeValue(allocator, list, @field(value, field.name), new_depth);
                }
            }
        },

        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("BCS: untagged unions not supported — use a tagged union");
            }
            const new_depth = depth + 1;
            if (new_depth > max_container_depth) return Error.ContainerTooDeep;

            const tag = std.meta.activeTag(value);
            const index: u32 = @intFromEnum(tag);
            try uleb128Append(allocator, list, index);

            inline for (union_info.fields) |field| {
                if (comptime std.meta.stringToEnum(std.meta.Tag(T), field.name)) |this_tag| {
                    if (tag == this_tag) {
                        if (field.type != void) {
                            try serializeValue(allocator, list, @field(value, field.name), new_depth);
                        }
                        return;
                    }
                }
            }
        },

        .@"enum" => {
            const index: u32 = @intFromEnum(value);
            try uleb128Append(allocator, list, index);
        },

        .void => {},

        else => @compileError("BCS: unsupported type " ++ @typeName(T)),
    }
}

// ── Deserialize ────────────────────────────────────────────────────────

fn deserializeValue(comptime T: type, allocator: Allocator, reader: *Reader, depth: u32) Error!T {
    const info = @typeInfo(T);

    switch (info) {
        .bool => {
            const byte = try reader.readByte();
            return switch (byte) {
                0x00 => false,
                0x01 => true,
                else => Error.InvalidBool,
            };
        },

        .int => return readIntLittle(T, reader),

        .optional => |opt_info| {
            const tag = try reader.readByte();
            return switch (tag) {
                0x00 => null,
                0x01 => try deserializeValue(opt_info.child, allocator, reader, depth),
                else => Error.InvalidOptionTag,
            };
        },

        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    const len = try uleb128Read(reader);
                    if (len > max_sequence_length) return Error.SequenceTooLong;
                    if (ptr_info.child == u8) {
                        const bytes = try reader.readBytes(len);
                        return allocator.dupe(u8, bytes) catch Error.OutOfMemory;
                    } else {
                        const slice = allocator.alloc(ptr_info.child, len) catch return Error.OutOfMemory;
                        for (slice) |*elem| {
                            elem.* = try deserializeValue(ptr_info.child, allocator, reader, depth);
                        }
                        return slice;
                    }
                },
                else => @compileError("BCS: cannot deserialize pointer type " ++ @typeName(T)),
            }
        },

        .array => |arr_info| {
            if (arr_info.child == u8) {
                const bytes = try reader.readBytes(arr_info.len);
                return bytes[0..arr_info.len].*;
            } else {
                var result: T = undefined;
                for (&result) |*elem| {
                    elem.* = try deserializeValue(arr_info.child, allocator, reader, depth);
                }
                return result;
            }
        },

        .@"struct" => |struct_info| {
            if (@hasDecl(T, "bcs_map") and T.bcs_map) {
                return deserializeMap(T.Key, T.Value, allocator, reader, depth);
            } else if (struct_info.is_tuple) {
                var result: T = undefined;
                inline for (struct_info.fields) |field| {
                    @field(result, field.name) = try deserializeValue(field.type, allocator, reader, depth);
                }
                return result;
            } else {
                const new_depth = depth + 1;
                if (new_depth > max_container_depth) return Error.ContainerTooDeep;
                var result: T = undefined;
                inline for (struct_info.fields) |field| {
                    @field(result, field.name) = try deserializeValue(field.type, allocator, reader, new_depth);
                }
                return result;
            }
        },

        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("BCS: untagged unions not supported");
            }
            const new_depth = depth + 1;
            if (new_depth > max_container_depth) return Error.ContainerTooDeep;

            const index = try uleb128Read(reader);

            inline for (union_info.fields, 0..) |field, i| {
                if (index == i) {
                    if (field.type == void) {
                        return @unionInit(T, field.name, {});
                    } else {
                        const val = try deserializeValue(field.type, allocator, reader, new_depth);
                        return @unionInit(T, field.name, val);
                    }
                }
            }
            return Error.InvalidEnumTag;
        },

        .@"enum" => {
            const index = try uleb128Read(reader);
            inline for (@typeInfo(T).@"enum".fields, 0..) |field, i| {
                if (index == i) return @enumFromInt(field.value);
            }
            return Error.InvalidEnumTag;
        },

        .void => return {},

        else => @compileError("BCS: unsupported type " ++ @typeName(T)),
    }
}

// ════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════

const testing = std.testing;
const t_alloc = testing.allocator;

// ── Primitives ─────────────────────────────────────────────────────────

test "bool serialization" {
    const t = try serialize(t_alloc, true);
    defer t_alloc.free(t);
    try testing.expectEqualSlices(u8, &.{1}, t);

    const f = try serialize(t_alloc, false);
    defer t_alloc.free(f);
    try testing.expectEqualSlices(u8, &.{0}, f);
}

test "bool deserialization" {
    try testing.expectEqual(true, try deserialize(bool, t_alloc, &.{1}));
    try testing.expectEqual(false, try deserialize(bool, t_alloc, &.{0}));
    try testing.expectError(Error.InvalidBool, deserialize(bool, t_alloc, &.{2}));
}

test "u8" {
    const bytes = try serialize(t_alloc, @as(u8, 255));
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{0xff}, bytes);
}

test "u16 little-endian" {
    const bytes = try serialize(t_alloc, @as(u16, 0x0102));
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x01 }, bytes);
}

test "u32 little-endian" {
    const bytes = try serialize(t_alloc, @as(u32, 305419896));
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, bytes);
}

test "u64 little-endian" {
    const bytes = try serialize(t_alloc, @as(u64, 0x0102030405060708));
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 }, bytes);
}

test "u128 little-endian" {
    const bytes = try serialize(t_alloc, @as(u128, 1));
    defer t_alloc.free(bytes);
    var expected: [16]u8 = .{0} ** 16;
    expected[0] = 1;
    try testing.expectEqualSlices(u8, &expected, bytes);
}

test "u256 little-endian" {
    const bytes = try serialize(t_alloc, @as(u256, 0xff));
    defer t_alloc.free(bytes);
    var expected: [32]u8 = .{0} ** 32;
    expected[0] = 0xff;
    try testing.expectEqualSlices(u8, &expected, bytes);
}

test "i8 signed" {
    const bytes = try serialize(t_alloc, @as(i8, -1));
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{0xff}, bytes);
}

test "i16 signed little-endian" {
    const bytes = try serialize(t_alloc, @as(i16, -4660));
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0xcc, 0xed }, bytes);
}

test "i32 signed" {
    const bytes = try serialize(t_alloc, @as(i32, -1));
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, bytes);
}

test "integer round-trip" {
    inline for (.{ u8, u16, u32, u64, u128, i8, i16, i32, i64, i128 }) |T| {
        const original: T = if (@typeInfo(T).int.signedness == .signed) -1 else std.math.maxInt(T);
        const bytes = try serialize(t_alloc, original);
        defer t_alloc.free(bytes);
        const decoded = try deserialize(T, t_alloc, bytes);
        try testing.expectEqual(original, decoded);
    }
}

// ── Strings ────────────────────────────────────────────────────────────

test "string serialization" {
    const bytes = try serialize(t_alloc, @as([]const u8, "diem"));
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 4, 'd', 'i', 'e', 'm' }, bytes);
}

test "empty string" {
    const bytes = try serialize(t_alloc, @as([]const u8, ""));
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{0}, bytes);
}

test "string round-trip" {
    const original: []const u8 = "hello world";
    const bytes = try serialize(t_alloc, original);
    defer t_alloc.free(bytes);
    const decoded = try deserialize([]const u8, t_alloc, bytes);
    defer t_alloc.free(decoded);
    try testing.expectEqualStrings(original, decoded);
}

// ── Vectors ────────────────────────────────────────────────────────────

test "vector of u16" {
    const vec: []const u16 = &.{ 1, 2 };
    const bytes = try serialize(t_alloc, vec);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x00, 0x02, 0x00 }, bytes);
}

test "empty vector" {
    const vec: []const u32 = &.{};
    const bytes = try serialize(t_alloc, vec);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{0}, bytes);
}

test "vector round-trip" {
    const original: []const u32 = &.{ 10, 20, 30 };
    const bytes = try serialize(t_alloc, original);
    defer t_alloc.free(bytes);
    const decoded = try deserialize([]const u32, t_alloc, bytes);
    defer t_alloc.free(decoded);
    try testing.expectEqualSlices(u32, original, decoded);
}

// ── Fixed Arrays ───────────────────────────────────────────────────────

test "fixed array no length prefix" {
    const arr: [3]u16 = .{ 1, 2, 3 };
    const bytes = try serialize(t_alloc, arr);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x02, 0x00, 0x03, 0x00 }, bytes);
}

test "fixed byte array" {
    const arr: [4]u8 = .{ 0xde, 0xad, 0xbe, 0xef };
    const bytes = try serialize(t_alloc, arr);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, bytes);
}

test "fixed array round-trip" {
    const original: [4]u32 = .{ 1, 2, 3, 4 };
    const bytes = try serialize(t_alloc, original);
    defer t_alloc.free(bytes);
    const decoded = try deserialize([4]u32, t_alloc, bytes);
    try testing.expectEqual(original, decoded);
}

// ── Optionals ──────────────────────────────────────────────────────────

test "option some" {
    const val: ?u8 = 8;
    const bytes = try serialize(t_alloc, val);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x08 }, bytes);
}

test "option none" {
    const val: ?u8 = null;
    const bytes = try serialize(t_alloc, val);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{0x00}, bytes);
}

test "option round-trip" {
    {
        const original: ?u32 = 42;
        const bytes = try serialize(t_alloc, original);
        defer t_alloc.free(bytes);
        try testing.expectEqual(original, try deserialize(?u32, t_alloc, bytes));
    }
    {
        const original: ?u32 = null;
        const bytes = try serialize(t_alloc, original);
        defer t_alloc.free(bytes);
        try testing.expectEqual(original, try deserialize(?u32, t_alloc, bytes));
    }
}

test "option of option" {
    const val: ??u8 = @as(?u8, 42);
    const bytes = try serialize(t_alloc, val);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x01, 42 }, bytes);
    try testing.expectEqual(val, try deserialize(??u8, t_alloc, bytes));
}

// ── Structs ────────────────────────────────────────────────────────────

test "struct serialization" {
    const MyStruct = struct { a: u8, b: u16, c: u32 };
    const val = MyStruct{ .a = 1, .b = 2, .c = 3 };
    const bytes = try serialize(t_alloc, val);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{
        0x01,
        0x02, 0x00,
        0x03, 0x00, 0x00, 0x00,
    }, bytes);
}

test "struct round-trip" {
    const MyStruct = struct { a: u8, b: u16, c: u32 };
    const original = MyStruct{ .a = 1, .b = 2, .c = 3 };
    const bytes = try serialize(t_alloc, original);
    defer t_alloc.free(bytes);
    try testing.expectEqual(original, try deserialize(MyStruct, t_alloc, bytes));
}

test "nested struct" {
    const Inner = struct { x: u8 };
    const Outer = struct { inner: Inner, y: u16 };
    const val = Outer{ .inner = .{ .x = 42 }, .y = 100 };
    const bytes = try serialize(t_alloc, val);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 42, 100, 0 }, bytes);
    try testing.expectEqual(val, try deserialize(Outer, t_alloc, bytes));
}

test "struct with string field" {
    const Event = struct { sender: [32]u8, name: []const u8, amount: u64 };
    var addr: [32]u8 = .{0} ** 32;
    addr[0] = 0x01;
    const val = Event{ .sender = addr, .name = "test", .amount = 1000 };

    const bytes = try serialize(t_alloc, val);
    defer t_alloc.free(bytes);

    const decoded = try deserialize(Event, t_alloc, bytes);
    defer t_alloc.free(decoded.name);
    try testing.expectEqual(val.sender, decoded.sender);
    try testing.expectEqualStrings(val.name, decoded.name);
    try testing.expectEqual(val.amount, decoded.amount);
}

// ── Enums / Unions ─────────────────────────────────────────────────────

test "tagged union serialization" {
    const MyEnum = union(enum) { variant0: u16, variant1: u8, variant2: []const u8 };

    {
        const val = MyEnum{ .variant0 = 8000 };
        const bytes = try serialize(t_alloc, val);
        defer t_alloc.free(bytes);
        try testing.expectEqualSlices(u8, &.{ 0x00, 0x40, 0x1f }, bytes);
    }
    {
        const val = MyEnum{ .variant1 = 255 };
        const bytes = try serialize(t_alloc, val);
        defer t_alloc.free(bytes);
        try testing.expectEqualSlices(u8, &.{ 0x01, 0xff }, bytes);
    }
}

test "tagged union round-trip" {
    const MyEnum = union(enum) { variant0: u16, variant1: u8, variant2: void };
    inline for (.{
        MyEnum{ .variant0 = 8000 },
        MyEnum{ .variant1 = 255 },
        MyEnum{ .variant2 = {} },
    }) |original| {
        const bytes = try serialize(t_alloc, original);
        defer t_alloc.free(bytes);
        try testing.expectEqual(original, try deserialize(MyEnum, t_alloc, bytes));
    }
}

test "unit enum" {
    const Color = enum { red, green, blue };
    {
        const bytes = try serialize(t_alloc, Color.red);
        defer t_alloc.free(bytes);
        try testing.expectEqualSlices(u8, &.{0x00}, bytes);
    }
    {
        const bytes = try serialize(t_alloc, Color.blue);
        defer t_alloc.free(bytes);
        try testing.expectEqualSlices(u8, &.{0x02}, bytes);
    }
}

test "enum round-trip" {
    const Color = enum { red, green, blue };
    inline for (.{ Color.red, Color.green, Color.blue }) |original| {
        const bytes = try serialize(t_alloc, original);
        defer t_alloc.free(bytes);
        try testing.expectEqual(original, try deserialize(Color, t_alloc, bytes));
    }
}

// ── Tuples ─────────────────────────────────────────────────────────────

test "tuple serialization" {
    const val: struct { i8, []const u8 } = .{ -1, "diem" };
    const bytes = try serialize(t_alloc, val);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x04, 'd', 'i', 'e', 'm' }, bytes);
}

// ── ULEB128 ────────────────────────────────────────────────────────────

test "ULEB128 encoding" {
    {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(t_alloc);
        try uleb128Append(t_alloc, &list, 0);
        try testing.expectEqualSlices(u8, &.{0x00}, list.items);
    }
    {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(t_alloc);
        try uleb128Append(t_alloc, &list, 128);
        try testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, list.items);
    }
    {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(t_alloc);
        try uleb128Append(t_alloc, &list, 16384);
        try testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x01 }, list.items);
    }
}

test "ULEB128 round-trip" {
    const test_values = [_]u32{ 0, 1, 127, 128, 255, 256, 16383, 16384, 2097151, std.math.maxInt(u32) };
    for (test_values) |original| {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(t_alloc);
        try uleb128Append(t_alloc, &list, original);
        var reader = Reader{ .data = list.items, .pos = 0 };
        try testing.expectEqual(original, try uleb128Read(&reader));
    }
}

test "ULEB128 non-canonical rejected" {
    var reader = Reader{ .data = &.{ 0x80, 0x00 }, .pos = 0 };
    try testing.expectError(Error.NonCanonicalUleb128, uleb128Read(&reader));
}

// ── Edge Cases ─────────────────────────────────────────────────────────

test "void serialization" {
    const bytes = try serialize(t_alloc, {});
    defer t_alloc.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);
}

test "trailing bytes rejected" {
    try testing.expectError(Error.TrailingBytes, deserialize(u8, t_alloc, &.{ 0x01, 0x02 }));
}

test "unexpected end of input" {
    try testing.expectError(Error.UnexpectedEndOfInput, deserialize(u32, t_alloc, &.{0x01}));
}

test "invalid enum tag rejected" {
    const Color = enum { red, green, blue };
    try testing.expectError(Error.InvalidEnumTag, deserialize(Color, t_alloc, &.{0x03}));
}

test "Sui address (32-byte array)" {
    const addr: [32]u8 = .{0x42} ** 32;
    const bytes = try serialize(t_alloc, addr);
    defer t_alloc.free(bytes);
    try testing.expectEqual(@as(usize, 32), bytes.len);
    try testing.expectEqual(@as(u8, 0x42), bytes[0]);
    try testing.expectEqual(addr, try deserialize([32]u8, t_alloc, bytes));
}

test "deserializePartial" {
    const bytes = &[_]u8{ 0x42, 0xff };
    const result = try deserializePartial(u8, t_alloc, bytes);
    try testing.expectEqual(@as(u8, 0x42), result.value);
    try testing.expectEqual(@as(usize, 1), result.bytes_read);
}

test "complex nested type" {
    const Inner = struct { flag: bool, value: u64 };
    const Outer = struct { tag: u8, inner: ?Inner, data: [4]u8 };
    const original = Outer{
        .tag = 1,
        .inner = Inner{ .flag = true, .value = 999 },
        .data = .{ 0xde, 0xad, 0xbe, 0xef },
    };
    const bytes = try serialize(t_alloc, original);
    defer t_alloc.free(bytes);
    try testing.expectEqual(original, try deserialize(Outer, t_alloc, bytes));
}

// ════════════════════════════════════════════════════════════════════════
// Rust BCS parity tests (ported from diem/bcs tests/serde.rs)
// ════════════════════════════════════════════════════════════════════════

// Corresponds to Rust enum E { Unit, Newtype(u16), Tuple(u16, u16), Struct { a: u32 } }
// In Zig, Tuple variants are modeled as a struct-valued variant.
const E = union(enum) {
    unit: void,
    newtype: u16,
    tuple: struct { u16, u16 },
    @"struct": struct { a: u32 },
};

test "rust parity: test_enum" {
    // E::Unit => variant 0, no data
    {
        const bytes = try serialize(t_alloc, E{ .unit = {} });
        defer t_alloc.free(bytes);
        try testing.expectEqualSlices(u8, &.{0}, bytes);
        try testing.expectEqual(E{ .unit = {} }, try deserialize(E, t_alloc, bytes));
    }
    // E::Newtype(1) => variant 1, u16(1)
    {
        const bytes = try serialize(t_alloc, E{ .newtype = 1 });
        defer t_alloc.free(bytes);
        try testing.expectEqualSlices(u8, &.{ 1, 1, 0 }, bytes);
        try testing.expectEqual(E{ .newtype = 1 }, try deserialize(E, t_alloc, bytes));
    }
    // E::Tuple(1, 2) => variant 2, u16(1), u16(2)
    {
        const bytes = try serialize(t_alloc, E{ .tuple = .{ 1, 2 } });
        defer t_alloc.free(bytes);
        try testing.expectEqualSlices(u8, &.{ 2, 1, 0, 2, 0 }, bytes);
        try testing.expectEqual(E{ .tuple = .{ 1, 2 } }, try deserialize(E, t_alloc, bytes));
    }
    // E::Struct { a: 1 } => variant 3, u32(1)
    {
        const bytes = try serialize(t_alloc, E{ .@"struct" = .{ .a = 1 } });
        defer t_alloc.free(bytes);
        try testing.expectEqualSlices(u8, &.{ 3, 1, 0, 0, 0 }, bytes);
        try testing.expectEqual(E{ .@"struct" = .{ .a = 1 } }, try deserialize(E, t_alloc, bytes));
    }
}

// Corresponds to Rust struct Addr([u8; 32])
const Addr = struct { inner: [32]u8 };

// Corresponds to Rust struct Bar { a: u64, b: Vec<u8>, c: Addr, d: u32 }
const Bar = struct {
    a: u64,
    b: []const u8,
    c: Addr,
    d: u32,
};

test "rust parity: serde_known_vector (Bar)" {
    const b = Bar{
        .a = 100,
        .b = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
        .c = Addr{ .inner = .{5} ** 32 },
        .d = 99,
    };

    const bytes = try serialize(t_alloc, b);
    defer t_alloc.free(bytes);

    // Bar portion of the known test vector from Rust:
    // a=100 (u64 LE) + b=[0..8] (len=9 + 9 bytes) + c=Addr([5;32]) + d=99 (u32 LE)
    const expected = &[_]u8{
        0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // a: 100
        0x09, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // b: [0..8]
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, // c: Addr
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x63, 0x00, 0x00, 0x00, // d: 99
    };
    try testing.expectEqualSlices(u8, expected, bytes);

    // Round-trip
    const decoded = try deserialize(Bar, t_alloc, bytes);
    defer t_alloc.free(decoded.b);
    try testing.expectEqual(b.a, decoded.a);
    try testing.expectEqualSlices(u8, b.b, decoded.b);
    try testing.expectEqual(b.c, decoded.c);
    try testing.expectEqual(b.d, decoded.d);
}

test "rust parity: uleb_encoding_and_variant" {
    const TestEnum = enum { one, two };

    // Valid variant
    try testing.expectEqual(TestEnum.two, try deserialize(TestEnum, t_alloc, &.{1}));

    // Invalid variant index (5 > 1)
    try testing.expectError(Error.InvalidEnumTag, deserialize(TestEnum, t_alloc, &.{5}));

    // Truncated ULEB128 (continuation bits set, then EOF)
    try testing.expectError(Error.UnexpectedEndOfInput, deserialize(TestEnum, t_alloc, &.{ 0x80, 0x80, 0x80, 0x80 }));

    // ULEB128 too long (5 continuation bytes)
    try testing.expectError(Error.Uleb128Overflow, deserialize(TestEnum, t_alloc, &.{ 0x80, 0x80, 0x80, 0x80, 0x80 }));

    // ULEB128 value overflow (0x1f in 5th byte = value > u32 max)
    try testing.expectError(Error.Uleb128Overflow, deserialize(TestEnum, t_alloc, &.{ 0x80, 0x80, 0x80, 0x80, 0x1f }));

    // Valid large ULEB128 but invalid variant (0x0f in 5th byte = 4026531840)
    try testing.expectError(Error.InvalidEnumTag, deserialize(TestEnum, t_alloc, &.{ 0x80, 0x80, 0x80, 0x80, 0x0f }));

    // Non-canonical ULEB128 (trailing zero continuation byte)
    try testing.expectError(Error.NonCanonicalUleb128, deserialize(TestEnum, t_alloc, &.{ 0x80, 0x80, 0x80, 0x00 }));
}

test "rust parity: invalid_option" {
    // Option tag must be 0 or 1
    try testing.expectError(Error.InvalidOptionTag, deserialize(?u8, t_alloc, &.{ 5, 0 }));
}

test "rust parity: invalid_bool" {
    try testing.expectError(Error.InvalidBool, deserialize(bool, t_alloc, &.{9}));
}

test "rust parity: variable_lengths" {
    // vec![(); 1] => ULEB128(1)
    {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(t_alloc);
        try uleb128Append(t_alloc, &list, 1);
        try testing.expectEqualSlices(u8, &.{0x01}, list.items);
    }
    // vec![(); 128] => ULEB128(128)
    {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(t_alloc);
        try uleb128Append(t_alloc, &list, 128);
        try testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, list.items);
    }
    // vec![(); 255] => ULEB128(255)
    {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(t_alloc);
        try uleb128Append(t_alloc, &list, 255);
        try testing.expectEqualSlices(u8, &.{ 0xff, 0x01 }, list.items);
    }
    // vec![(); 786_432] => ULEB128(786432)
    {
        var list: std.ArrayList(u8) = .{};
        defer list.deinit(t_alloc);
        try uleb128Append(t_alloc, &list, 786_432);
        try testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x30 }, list.items);
    }
}

test "rust parity: sequence_not_long_enough" {
    // Claims 5 elements but only has 4 bytes
    try testing.expectError(Error.UnexpectedEndOfInput, deserialize([]const u8, t_alloc, &.{ 5, 1, 2, 3, 4 }));
}

test "rust parity: leftover_bytes" {
    // 5 elements followed by 5 extra bytes
    try testing.expectError(Error.TrailingBytes, deserialize([]const u8, t_alloc, &.{ 5, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }));
}

test "rust parity: zero_copy_parse" {
    const ZeroCopyFoo = struct { borrowed_str: []const u8, borrowed_bytes: []const u8 };
    const f = ZeroCopyFoo{ .borrowed_str = "hi", .borrowed_bytes = &.{ 0, 1, 2, 3 } };

    const expected = &[_]u8{ 2, 'h', 'i', 4, 0, 1, 2, 3 };
    const encoded = try serialize(t_alloc, f);
    defer t_alloc.free(encoded);
    try testing.expectEqualSlices(u8, expected, encoded);

    const out = try deserialize(ZeroCopyFoo, t_alloc, encoded);
    defer t_alloc.free(out.borrowed_str);
    defer t_alloc.free(out.borrowed_bytes);
    try testing.expectEqualStrings(f.borrowed_str, out.borrowed_str);
    try testing.expectEqualSlices(u8, f.borrowed_bytes, out.borrowed_bytes);
}

// Recursive linked list for depth testing (mirrors Rust's List<T>)
fn ListOf(comptime T: type) type {
    return struct {
        value: T,
        next: ?*const @This(),
    };
}

test "rust parity: test_recursion_limit (linked list)" {
    // Build List { value: 4, next: List { value: 3, next: List { value: 2, ... List { value: 0, next: null }}}}
    const L = ListOf(u64);

    const l0 = L{ .value = 0, .next = null };
    const l1 = L{ .value = 1, .next = &l0 };
    const l2 = L{ .value = 2, .next = &l1 };
    const l3 = L{ .value = 3, .next = &l2 };
    const l4 = L{ .value = 4, .next = &l3 };

    const bytes = try serialize(t_alloc, l4);
    defer t_alloc.free(bytes);

    // Matches Rust's known output:
    // 4,0,0,0,0,0,0,0, 1, 3,0,0,0,0,0,0,0, 1, 2,0,0,0,0,0,0,0, 1, 1,0,0,0,0,0,0,0, 1, 0,0,0,0,0,0,0,0, 0
    const expected = &[_]u8{
        4, 0, 0, 0, 0, 0, 0, 0, 1, // value=4, next=Some
        3, 0, 0, 0, 0, 0, 0, 0, 1, // value=3, next=Some
        2, 0, 0, 0, 0, 0, 0, 0, 1, // value=2, next=Some
        1, 0, 0, 0, 0, 0, 0, 0, 1, // value=1, next=Some
        0, 0, 0, 0, 0, 0, 0, 0, 0, // value=0, next=None
    };
    try testing.expectEqualSlices(u8, expected, bytes);
}

test "rust parity: test_recursion_limit_enum (linked list with enum)" {
    const EnumA = enum { value_a };
    const L = ListOf(EnumA);

    // Build list of length 7: [ValueA, ValueA, ValueA, ValueA, ValueA, ValueA, ValueA(head)]
    const l0 = L{ .value = .value_a, .next = null };
    const l1 = L{ .value = .value_a, .next = &l0 };
    const l2 = L{ .value = .value_a, .next = &l1 };
    const l3 = L{ .value = .value_a, .next = &l2 };
    const l4 = L{ .value = .value_a, .next = &l3 };
    const l5 = L{ .value = .value_a, .next = &l4 };
    const l6 = L{ .value = .value_a, .next = &l5 };

    const bytes = try serialize(t_alloc, l6);
    defer t_alloc.free(bytes);

    // Each node: enum(0) + option(1) = 2 bytes, last node: enum(0) + option(0) = 2 bytes
    const expected = &[_]u8{ 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0 };
    try testing.expectEqualSlices(u8, expected, bytes);
}

// Corresponds to Rust struct S { int: u16, option: Option<u8>, seq: Vec<String>, boolean: bool }
const S = struct {
    int: u16,
    option: ?u8,
    seq: []const []const u8,
    boolean: bool,
};

test "rust parity: struct S round-trip" {
    const original = S{
        .int = 1000,
        .option = 42,
        .seq = &.{ "hello", "world" },
        .boolean = true,
    };
    const bytes = try serialize(t_alloc, original);
    defer t_alloc.free(bytes);

    // Manual verification:
    // int: 0xe8 0x03 (1000 LE)
    // option: 0x01 0x2a (Some(42))
    // seq: 0x02 (len=2) + "hello" (0x05 h e l l o) + "world" (0x05 w o r l d)
    // boolean: 0x01
    const expected = &[_]u8{
        0xe8, 0x03, // int: 1000
        0x01, 0x2a, // option: Some(42)
        0x02, // seq length: 2
        0x05, 'h', 'e', 'l', 'l', 'o', // "hello"
        0x05, 'w', 'o', 'r', 'l', 'd', // "world"
        0x01, // boolean: true
    };
    try testing.expectEqualSlices(u8, expected, bytes);

    const decoded = try deserialize(S, t_alloc, bytes);
    defer {
        for (decoded.seq) |s| t_alloc.free(s);
        t_alloc.free(decoded.seq);
    }
    try testing.expectEqual(original.int, decoded.int);
    try testing.expectEqual(original.option, decoded.option);
    try testing.expectEqual(original.boolean, decoded.boolean);
    try testing.expectEqual(original.seq.len, decoded.seq.len);
    for (original.seq, decoded.seq) |orig, dec| {
        try testing.expectEqualStrings(orig, dec);
    }
}

test "rust parity: struct S with none option" {
    const original = S{
        .int = 0,
        .option = null,
        .seq = &.{},
        .boolean = false,
    };
    const bytes = try serialize(t_alloc, original);
    defer t_alloc.free(bytes);

    const expected = &[_]u8{
        0x00, 0x00, // int: 0
        0x00, // option: None
        0x00, // seq: empty
        0x00, // boolean: false
    };
    try testing.expectEqualSlices(u8, expected, bytes);

    const decoded = try deserialize(S, t_alloc, bytes);
    defer {
        for (decoded.seq) |s| t_alloc.free(s);
        t_alloc.free(decoded.seq);
    }
    try testing.expectEqual(original.int, decoded.int);
    try testing.expectEqual(original.option, decoded.option);
    try testing.expectEqual(original.boolean, decoded.boolean);
    try testing.expectEqual(original.seq.len, decoded.seq.len);
}

test "rust parity: Addr round-trip" {
    const addr = Addr{ .inner = .{0xab} ** 32 };
    const bytes = try serialize(t_alloc, addr);
    defer t_alloc.free(bytes);
    try testing.expectEqual(@as(usize, 32), bytes.len);
    try testing.expectEqual(addr, try deserialize(Addr, t_alloc, bytes));
}

test "rust parity: Bar round-trip" {
    const b = Bar{
        .a = std.math.maxInt(u64),
        .b = &.{ 1, 2, 3 },
        .c = Addr{ .inner = .{0xff} ** 32 },
        .d = 42,
    };
    const bytes = try serialize(t_alloc, b);
    defer t_alloc.free(bytes);
    const decoded = try deserialize(Bar, t_alloc, bytes);
    defer t_alloc.free(decoded.b);
    try testing.expectEqual(b.a, decoded.a);
    try testing.expectEqualSlices(u8, b.b, decoded.b);
    try testing.expectEqual(b.c, decoded.c);
    try testing.expectEqual(b.d, decoded.d);
}

// ── Map Tests ──────────────────────────────────────────────────────────

test "map serialization — sorted by BCS key bytes" {
    const M = Map(u8, void);
    const map = M{ .entries = &.{
        .{ .key = 4, .value = {} },
        .{ .key = 5, .value = {} },
    } };
    const bytes = try serialize(t_alloc, map);
    defer t_alloc.free(bytes);
    // ULEB128(2) + key(4) + key(5) — already sorted
    try testing.expectEqualSlices(u8, &.{ 2, 4, 5 }, bytes);
}

test "map serialization — unsorted input gets sorted" {
    const M = Map(u8, void);
    // Intentionally out-of-order entries — serializer must sort them
    const map = M{ .entries = &.{
        .{ .key = 5, .value = {} },
        .{ .key = 4, .value = {} },
    } };
    const bytes = try serialize(t_alloc, map);
    defer t_alloc.free(bytes);
    // Must come out sorted: 4 before 5
    try testing.expectEqualSlices(u8, &.{ 2, 4, 5 }, bytes);
}

test "map deserialization — valid sorted keys" {
    const M = Map(u8, void);
    const decoded = try deserialize(M, t_alloc, &.{ 2, 4, 5 });
    defer t_alloc.free(decoded.entries);
    try testing.expectEqual(@as(usize, 2), decoded.entries.len);
    try testing.expectEqual(@as(u8, 4), decoded.entries[0].key);
    try testing.expectEqual(@as(u8, 5), decoded.entries[1].key);
}

test "rust parity: map_not_canonical — out-of-order keys rejected" {
    const M = Map(u8, void);
    try testing.expectError(Error.NonCanonicalMap, deserialize(M, t_alloc, &.{ 2, 5, 4 }));
}

test "rust parity: map_not_canonical — duplicate keys rejected" {
    const M = Map(u8, void);
    try testing.expectError(Error.NonCanonicalMap, deserialize(M, t_alloc, &.{ 2, 5, 5 }));
}

test "map with string keys — sorted by BCS bytes" {
    const M = Map([]const u8, []const u8);
    const map = M{ .entries = &.{
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "1" },
        .{ .key = "c", .value = "3" },
    } };
    const bytes = try serialize(t_alloc, map);
    defer t_alloc.free(bytes);
    // count=3, then sorted: "a"→"1", "b"→"2", "c"→"3"
    // Each string: ULEB128(1) + byte
    try testing.expectEqualSlices(u8, &.{
        3, // count
        1, 'a', 1, '1', // "a" → "1"
        1, 'b', 1, '2', // "b" → "2"
        1, 'c', 1, '3', // "c" → "3"
    }, bytes);
}

test "map round-trip" {
    const M = Map(u8, u16);
    const map = M{ .entries = &.{
        .{ .key = 10, .value = 100 },
        .{ .key = 20, .value = 200 },
        .{ .key = 30, .value = 300 },
    } };
    const bytes = try serialize(t_alloc, map);
    defer t_alloc.free(bytes);
    const decoded = try deserialize(M, t_alloc, bytes);
    defer t_alloc.free(decoded.entries);
    try testing.expectEqual(@as(usize, 3), decoded.entries.len);
    try testing.expectEqual(@as(u8, 10), decoded.entries[0].key);
    try testing.expectEqual(@as(u16, 100), decoded.entries[0].value);
    try testing.expectEqual(@as(u8, 20), decoded.entries[1].key);
    try testing.expectEqual(@as(u16, 200), decoded.entries[1].value);
}

test "empty map" {
    const M = Map(u8, u8);
    const map = M{ .entries = &.{} };
    const bytes = try serialize(t_alloc, map);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{0}, bytes);
    const decoded = try deserialize(M, t_alloc, bytes);
    defer t_alloc.free(decoded.entries);
    try testing.expectEqual(@as(usize, 0), decoded.entries.len);
}

// Corresponds to Rust struct Foo { a: u64, b: Vec<u8>, c: Bar, d: bool, e: BTreeMap<Vec<u8>, Vec<u8>> }
const Foo = struct {
    a: u64,
    b: []const u8,
    c: Bar,
    d: bool,
    e: Map([]const u8, []const u8),
};

test "rust parity: serde_known_vector (full Foo with BTreeMap)" {
    const f = Foo{
        .a = std.math.maxInt(u64),
        .b = &.{ 100, 99, 88, 77, 66, 55 },
        .c = Bar{
            .a = 100,
            .b = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
            .c = Addr{ .inner = .{5} ** 32 },
            .d = 99,
        },
        .d = true,
        .e = Map([]const u8, []const u8){ .entries = &.{
            .{ .key = &.{ 0, 56, 21 }, .value = &.{ 22, 10, 5 } },
            .{ .key = &.{1}, .value = &.{ 22, 21, 67 } },
            .{ .key = &.{ 20, 21, 89, 105 }, .value = &.{ 201, 23, 90 } },
        } },
    };

    const bytes = try serialize(t_alloc, f);
    defer t_alloc.free(bytes);

    // Exact test vector from Rust diem/bcs tests/serde.rs
    const test_vector = &[_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // a: u64::MAX
        0x06, 0x64, 0x63, 0x58, 0x4d, 0x42, 0x37, // b: [100,99,88,77,66,55]
        0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // c.a: 100
        0x09, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // c.b: [0..8]
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, // c.c: Addr([5;32])
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x63, 0x00, 0x00, 0x00, // c.d: 99
        0x01, // d: true
        0x03, // e: 3 map entries
        // Map entries sorted by BCS-encoded key bytes:
        // key=[1] (BCS: 0x01,0x01) → val=[22,21,67]
        0x01, 0x01, 0x03, 0x16, 0x15, 0x43,
        // key=[0,56,21] (BCS: 0x03,0x00,0x38,0x15) → val=[22,10,5]
        0x03, 0x00, 0x38, 0x15, 0x03, 0x16, 0x0a, 0x05,
        // key=[20,21,89,105] (BCS: 0x04,0x14,0x15,0x59,0x69) → val=[201,23,90]
        0x04, 0x14, 0x15, 0x59, 0x69, 0x03, 0xc9, 0x17, 0x5a,
    };

    // Exact byte-level parity with Rust reference implementation
    try testing.expectEqualSlices(u8, test_vector, bytes);

    // Deserialize and verify round-trip
    const decoded = try deserialize(Foo, t_alloc, test_vector);
    defer freeDeserialized(Foo, t_alloc, decoded);
    try testing.expectEqual(f.a, decoded.a);
    try testing.expectEqualSlices(u8, f.b, decoded.b);
    try testing.expectEqual(f.c.a, decoded.c.a);
    try testing.expectEqualSlices(u8, f.c.b, decoded.c.b);
    try testing.expectEqual(f.c.c, decoded.c.c);
    try testing.expectEqual(f.c.d, decoded.c.d);
    try testing.expectEqual(f.d, decoded.d);
    try testing.expectEqual(f.e.entries.len, decoded.e.entries.len);
}
