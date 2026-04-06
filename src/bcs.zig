const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const native_endian = builtin.cpu.arch.endian();

// ── BCS Constants ──────────────────────────────────────────────────────

pub const max_sequence_length: u32 = (1 << 31) - 1;
pub const max_container_depth: u32 = 500;

// ── Errors ─────────────────────────────────────────────────────────────

pub const Error = error{
    InvalidBool,
    NonCanonicalUleb128,
    Uleb128Overflow,
    Utf8,
    SequenceTooLong,
    ContainerTooDeep,
    NotSupported,
    UnexpectedEndOfInput,
    TrailingBytes,
    InvalidEnumTag,
    InvalidOptionTag,
    NonCanonicalMap,
    OutOfMemory,
};

/// BCS string with Rust `String` semantics: same wire format as `[]const u8`,
/// but serialization/deserialization validates UTF-8.
pub const String = struct {
    pub const bcs_string = true;

    bytes: []const u8,

    pub fn init(bytes: []const u8) @This() {
        return .{ .bytes = bytes };
    }

    pub fn initChecked(bytes: []const u8) Error!@This() {
        try validateUtf8(bytes);
        return .{ .bytes = bytes };
    }

    pub fn slice(self: @This()) []const u8 {
        return self.bytes;
    }

    pub fn eql(self: @This(), other: @This()) bool {
        return std.mem.eql(u8, self.bytes, other.bytes);
    }
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

/// A BCS-compatible map whose entries are already in canonical key order.
/// Serialization validates adjacent ordering but does not allocate or sort.
pub fn CanonicalMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const bcs_map = true;
        pub const bcs_map_canonical = true;
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

/// Exact serialized byte count for fixed-size types. Returns 0 for variable-length types.
/// Only returns nonzero when the output size is fully determined at comptime.
fn serializedSizeHint(comptime T: type) usize {
    @setEvalBranchQuota(10000);
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |info| @divExact(info.bits, 8),
        .array => |arr_info| blk: {
            const child = serializedSizeHint(arr_info.child);
            break :blk if (child > 0) arr_info.len * child else 0;
        },
        .@"struct" => |struct_info| blk: {
            if (@hasDecl(T, "bcs_map") and T.bcs_map) break :blk 0;
            var total: usize = 0;
            for (struct_info.fields) |field| {
                const fh = serializedSizeHint(field.type);
                if (fh == 0) break :blk 0;
                total += fh;
            }
            break :blk total;
        },
        else => 0,
    };
}

fn enumUsesOrdinalValues(comptime T: type) bool {
    inline for (@typeInfo(T).@"enum".fields, 0..) |field, i| {
        if (field.value != i) return false;
    }
    return true;
}

fn enumVariantIndex(comptime T: type, value: T) u32 {
    if (comptime enumUsesOrdinalValues(T)) {
        return @intFromEnum(value);
    }

    const raw = @intFromEnum(value);
    inline for (@typeInfo(T).@"enum".fields, 0..) |field, i| {
        if (raw == field.value) return i;
    }
    unreachable;
}

fn isCanonicalMapType(comptime T: type) bool {
    return @hasDecl(T, "bcs_map_canonical") and T.bcs_map_canonical;
}

fn isBcsStringType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "bcs_string") and T.bcs_string,
        .@"union" => @hasDecl(T, "bcs_string") and T.bcs_string,
        .@"enum" => @hasDecl(T, "bcs_string") and T.bcs_string,
        .@"opaque" => @hasDecl(T, "bcs_string") and T.bcs_string,
        else => false,
    };
}

fn ensureBcsStringType(comptime T: type) void {
    if (!isBcsStringType(T)) {
        @compileError("BCS: expected a bcs string type, got " ++ @typeName(T));
    }
    if (!@hasField(T, "bytes")) {
        @compileError("BCS: string type " ++ @typeName(T) ++ " must expose a `bytes` field");
    }
    const FieldT = @FieldType(T, "bytes");
    const field_info = @typeInfo(FieldT);
    if (field_info != .pointer or field_info.pointer.size != .slice or field_info.pointer.child != u8) {
        @compileError("BCS: string type " ++ @typeName(T) ++ " must use `[]const u8` for `bytes`");
    }
}

fn bcsStringBytes(value: anytype) []const u8 {
    const T = @TypeOf(value);
    comptime ensureBcsStringType(T);
    return @field(value, "bytes");
}

fn initBcsString(comptime T: type, bytes: []const u8) T {
    comptime ensureBcsStringType(T);
    return .{ .bytes = bytes };
}

fn needsFreeMode(comptime T: type) bool {
    @setEvalBranchQuota(10000);
    return switch (@typeInfo(T)) {
        .bool, .int, .@"enum", .void => false,
        .optional => |opt_info| needsFreeMode(opt_info.child),
        .pointer => |ptr_info| ptr_info.size == .slice,
        .array => |arr_info| needsFreeMode(arr_info.child),
        .@"struct" => |struct_info| blk: {
            if (@hasDecl(T, "bcs_map") and T.bcs_map) break :blk true;
            for (struct_info.fields) |field| {
                if (needsFreeMode(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |union_info| blk: {
            if (union_info.tag_type == null) break :blk false;
            for (union_info.fields) |field| {
                if (field.type != void and needsFreeMode(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn needsFree(comptime T: type) bool {
    return needsFreeMode(T);
}

fn PartialDeserializeResult(comptime T: type) type {
    return struct {
        value: T,
        bytes_read: usize,
    };
}

const BufferWriter = struct {
    buf: []u8,
    pos: usize = 0,
    pub const Error = error{};

    fn writeByte(self: *BufferWriter, byte: u8) void {
        self.buf[self.pos] = byte;
        self.pos += 1;
    }

    fn writeBytes(self: *BufferWriter, bytes: []const u8) void {
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    fn writeAll(self: *BufferWriter, bytes: []const u8) @This().Error!void {
        self.writeBytes(bytes);
    }
};

const ReservedListWriter = struct {
    list: *std.ArrayList(u8),
    pub const Error = error{};

    fn writeByte(self: *ReservedListWriter, byte: u8) @This().Error!void {
        self.list.appendAssumeCapacity(byte);
    }

    fn writeAll(self: *ReservedListWriter, bytes: []const u8) @This().Error!void {
        if (bytes.len == 0) return;
        @memcpy(self.list.addManyAsSliceAssumeCapacity(bytes.len), bytes);
    }
};

const CountingWriter = struct {
    count: usize = 0,
    pub const Error = error{OutOfMemory};

    fn writeAll(self: *CountingWriter, bytes: []const u8) @This().Error!void {
        self.count = std.math.add(usize, self.count, bytes.len) catch return @This().Error.OutOfMemory;
    }
};

/// Fast-path serializer for fixed-size types. Writes directly to a pre-allocated buffer.
fn serializeFixed(writer: *BufferWriter, value: anytype, depth: u32, depth_limit: u32) Error!void {
    @setEvalBranchQuota(10000);
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .bool => {
            writer.writeByte(if (value) 1 else 0);
        },
        .int => {
            const int_info = @typeInfo(T).int;
            const byte_count = comptime @divExact(int_info.bits, 8);
            if (comptime canBulkCopy(T)) {
                writer.writeBytes(std.mem.asBytes(&value));
            } else {
                const U = @Type(.{ .int = .{ .signedness = .unsigned, .bits = int_info.bits } });
                const uvalue: U = @bitCast(value);
                var buf: [byte_count]u8 = undefined;
                inline for (0..byte_count) |i| {
                    buf[i] = @truncate(uvalue >> @intCast(i * 8));
                }
                writer.writeBytes(&buf);
            }
        },
        .array => |arr_info| {
            if (arr_info.child == u8) {
                writer.writeBytes(&value);
            } else if (comptime canBulkCopy(arr_info.child)) {
                writer.writeBytes(std.mem.asBytes(&value));
            } else {
                for (value) |elem| {
                    try serializeFixed(writer, elem, depth, depth_limit);
                }
            }
        },
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                inline for (struct_info.fields) |field| {
                    try serializeFixed(writer, @field(value, field.name), depth, depth_limit);
                }
            } else {
                const new_depth = depth + 1;
                if (new_depth > depth_limit) return Error.ContainerTooDeep;
                inline for (struct_info.fields) |field| {
                    try serializeFixed(writer, @field(value, field.name), new_depth, depth_limit);
                }
            }
        },
        else => unreachable,
    }
}

/// Serialize a fixed-size value into a caller-provided buffer. Zero allocations.
/// Returns the number of bytes written. Compile error for variable-length types.
pub fn serializeInto(buf: []u8, value: anytype) Error!usize {
    return serializeIntoWithLimit(buf, value, max_container_depth);
}

fn normalizeDepthLimit(limit: usize) Error!u32 {
    if (limit > max_container_depth) return Error.NotSupported;
    return @intCast(limit);
}

/// Serialize a fixed-size value into a caller-provided buffer using a custom
/// container depth limit.
pub fn serializeIntoWithLimit(buf: []u8, value: anytype, limit: usize) Error!usize {
    const size = comptime serializedSizeHint(@TypeOf(value));
    if (size == 0) @compileError("serializeInto requires a fixed-size type; use serialize() for slices, optionals, maps, or unions");
    if (buf.len < size) return Error.UnexpectedEndOfInput;
    var writer = BufferWriter{ .buf = buf };
    try serializeFixed(&writer, value, 0, try normalizeDepthLimit(limit));
    return writer.pos;
}

/// Exact serialized byte count for a specific value, including variable-size types.
pub fn serializedSize(value: anytype) Error!usize {
    return serializedSizeWithLimit(value, max_container_depth);
}

/// Exact serialized byte count for a specific value, including variable-size
/// types, using a custom container depth limit.
pub fn serializedSizeWithLimit(value: anytype, limit: usize) Error!usize {
    return serializedSizeValue(value, 0, try normalizeDepthLimit(limit));
}

/// Serialize any BCS-compatible value to bytes.
pub fn serialize(allocator: Allocator, value: anytype) Error![]u8 {
    return serializeWithLimit(allocator, value, max_container_depth);
}

/// Serialize any BCS-compatible value to bytes using a custom container depth
/// limit.
pub fn serializeWithLimit(allocator: Allocator, value: anytype, limit: usize) Error![]u8 {
    const depth_limit = try normalizeDepthLimit(limit);
    const hint = comptime serializedSizeHint(@TypeOf(value));

    if (hint > 0) {
        const buf = allocator.alloc(u8, hint) catch return Error.OutOfMemory;
        errdefer allocator.free(buf);
        var writer = BufferWriter{ .buf = buf };
        try serializeFixed(&writer, value, 0, depth_limit);
        return buf;
    }

    const size = try serializedSizeValue(value, 0, depth_limit);
    const buf = allocator.alloc(u8, size) catch return Error.OutOfMemory;
    errdefer allocator.free(buf);
    var writer = BufferWriter{ .buf = buf };
    try serializeValueToWriter(allocator, &writer, value, 0, depth_limit);
    return buf;
}

/// Serialize a value into an existing byte buffer, appending to `list`.
/// This avoids the owned-slice allocation/copy performed by `serialize`.
pub fn serializeAppend(allocator: Allocator, list: *std.ArrayList(u8), value: anytype) Error!void {
    return serializeAppendWithLimit(allocator, list, value, max_container_depth);
}

/// Serialize a value into an existing byte buffer, appending to `list`, using
/// a custom container depth limit.
pub fn serializeAppendWithLimit(allocator: Allocator, list: *std.ArrayList(u8), value: anytype, limit: usize) Error!void {
    const depth_limit = try normalizeDepthLimit(limit);
    const additional = try serializedSizeValue(value, 0, depth_limit);
    list.ensureUnusedCapacity(allocator, additional) catch return Error.OutOfMemory;
    var writer = ReservedListWriter{ .list = list };
    try serializeValueToWriter(allocator, &writer, value, 0, depth_limit);
}

/// Serialize a value to any writer that supports `writeAll`.
/// Maps may still use the allocator for temporary key ordering scratch space.
pub fn serializeWriter(allocator: Allocator, writer: anytype, value: anytype) (WriterError(@TypeOf(writer)) || Error)!void {
    try serializeWriterWithLimit(allocator, writer, value, max_container_depth);
}

/// Serialize a value to any writer that supports `writeAll` using a custom
/// container depth limit.
pub fn serializeWriterWithLimit(allocator: Allocator, writer: anytype, value: anytype, limit: usize) (WriterError(@TypeOf(writer)) || Error)!void {
    try serializeValueToWriter(allocator, writer, value, 0, try normalizeDepthLimit(limit));
}

/// Deserialize bytes into a typed value.
/// Pass an allocator for types containing slices; unused for fixed-size types.
pub fn deserialize(comptime T: type, allocator: Allocator, bytes: []const u8) Error!T {
    return deserializeWithLimit(T, allocator, bytes, max_container_depth);
}

/// Deserialize bytes into a typed value using a custom container depth limit.
pub fn deserializeWithLimit(comptime T: type, allocator: Allocator, bytes: []const u8, limit: usize) Error!T {
    var reader = Reader{ .data = bytes, .pos = 0 };
    const value = try deserializeValue(T, allocator, &reader, 0, try normalizeDepthLimit(limit));
    if (reader.pos != reader.data.len) {
        freeDeserialized(T, allocator, value);
        return Error.TrailingBytes;
    }
    return value;
}

/// Deserialize a value from a Zig reader. The reader is drained to EOF and the
/// collected bytes are validated with the same logic as `deserialize`.
pub fn deserializeReader(comptime T: type, allocator: Allocator, reader: anytype) (ReaderReadByteError(@TypeOf(reader)) || Error)!T {
    return deserializeReaderWithLimit(T, allocator, reader, max_container_depth);
}

/// Same as `deserializeReader` but uses a custom container depth limit.
pub fn deserializeReaderWithLimit(comptime T: type, allocator: Allocator, reader: anytype, limit: usize) (ReaderReadByteError(@TypeOf(reader)) || Error)!T {
    const bytes = try readAllReader(allocator, reader);
    defer allocator.free(bytes);
    return deserializeWithLimit(T, allocator, bytes, limit);
}

/// Deserialize with an explicit seed object. Seeds provide a Zig-native
/// equivalent to Rust's `DeserializeSeed`: a seed type must declare
/// `pub const Value` and `pub fn deserialize(self, de: *SeedDeserializer)`.
pub fn deserializeSeed(seed: anytype, allocator: Allocator, bytes: []const u8) (SeedError(@TypeOf(seed)) || Error)!SeedValue(@TypeOf(seed)) {
    return deserializeSeedWithLimit(seed, allocator, bytes, max_container_depth);
}

/// Same as `deserializeSeed` but uses a custom container depth limit.
pub fn deserializeSeedWithLimit(seed: anytype, allocator: Allocator, bytes: []const u8, limit: usize) (SeedError(@TypeOf(seed)) || Error)!SeedValue(@TypeOf(seed)) {
    var reader = Reader{ .data = bytes, .pos = 0 };
    var de = SeedDeserializer{
        .allocator = allocator,
        .reader = &reader,
        .depth = 0,
        .depth_limit = try normalizeDepthLimit(limit),
    };
    const value = try seedDeserialize(seed, &de);
    if (reader.pos != reader.data.len) {
        freeSeedValue(seed, allocator, value);
        return Error.TrailingBytes;
    }
    return value;
}

/// Deserialize with a seed from a Zig reader.
pub fn deserializeReaderSeed(seed: anytype, allocator: Allocator, reader: anytype) (ReaderReadByteError(@TypeOf(reader)) || SeedError(@TypeOf(seed)) || Error)!SeedValue(@TypeOf(seed)) {
    return deserializeReaderSeedWithLimit(seed, allocator, reader, max_container_depth);
}

/// Same as `deserializeReaderSeed` but uses a custom container depth limit.
pub fn deserializeReaderSeedWithLimit(seed: anytype, allocator: Allocator, reader: anytype, limit: usize) (ReaderReadByteError(@TypeOf(reader)) || SeedError(@TypeOf(seed)) || Error)!SeedValue(@TypeOf(seed)) {
    const bytes = try readAllReader(allocator, reader);
    defer allocator.free(bytes);
    return deserializeSeedWithLimit(seed, allocator, bytes, limit);
}

/// Deserialize without checking for trailing bytes. Returns value and bytes consumed.
pub fn deserializePartial(comptime T: type, allocator: Allocator, bytes: []const u8) Error!PartialDeserializeResult(T) {
    return deserializePartialWithLimit(T, allocator, bytes, max_container_depth);
}

/// Deserialize without checking for trailing bytes using a custom container
/// depth limit. Returns value and bytes consumed.
pub fn deserializePartialWithLimit(comptime T: type, allocator: Allocator, bytes: []const u8, limit: usize) Error!PartialDeserializeResult(T) {
    var reader = Reader{ .data = bytes, .pos = 0 };
    const value = try deserializeValue(T, allocator, &reader, 0, try normalizeDepthLimit(limit));
    return .{ .value = value, .bytes_read = reader.pos };
}

/// Free all heap-allocated memory within a deserialized value.
pub fn freeDeserialized(comptime T: type, allocator: Allocator, value: T) void {
    freeDeserializedMode(T, allocator, value);
}

fn freeDeserializedMode(comptime T: type, allocator: Allocator, value: T) void {
    @setEvalBranchQuota(10000);
    if (comptime !needsFreeMode(T)) return;
    const info = @typeInfo(T);
    switch (info) {
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice) {
                if (comptime needsFreeMode(ptr_info.child)) {
                    for (value) |elem| freeDeserializedMode(ptr_info.child, allocator, elem);
                }
                allocator.free(value);
            }
        },
        .optional => |opt_info| {
            if (comptime needsFreeMode(opt_info.child)) {
                if (value) |v| freeDeserializedMode(opt_info.child, allocator, v);
            }
        },
        .@"struct" => |struct_info| {
            if (@hasDecl(T, "bcs_map") and T.bcs_map) {
                if (comptime needsFreeMode(T.Key) or needsFreeMode(T.Value)) {
                    for (value.entries) |entry| {
                        if (comptime needsFreeMode(T.Key)) {
                            freeDeserializedMode(T.Key, allocator, entry.key);
                        }
                        if (comptime needsFreeMode(T.Value)) {
                            freeDeserializedMode(T.Value, allocator, entry.value);
                        }
                    }
                }
                allocator.free(value.entries);
            } else {
                inline for (struct_info.fields) |field| {
                    if (comptime needsFreeMode(field.type)) {
                        freeDeserializedMode(field.type, allocator, @field(value, field.name));
                    }
                }
            }
        },
        .@"union" => |union_info| {
            if (union_info.tag_type != null) {
                const tag = std.meta.activeTag(value);
                inline for (union_info.fields) |field| {
                    if (comptime std.meta.stringToEnum(std.meta.Tag(T), field.name)) |this_tag| {
                        if (tag == this_tag and field.type != void and comptime needsFreeMode(field.type)) {
                            freeDeserializedMode(field.type, allocator, @field(value, field.name));
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
    var buf: [5]u8 = undefined;
    const len = uleb128Encode(&buf, value);
    list.appendSlice(allocator, buf[0..len]) catch return Error.OutOfMemory;
}

fn uleb128Size(value: u32) usize {
    var len: usize = 1;
    var v = value;
    while (v >= 0x80) {
        v >>= 7;
        len += 1;
    }
    return len;
}

fn uleb128Encode(buf: *[5]u8, value: u32) usize {
    var len: usize = 0;
    var v = value;
    while (true) {
        const byte: u8 = @truncate(v & 0x7f);
        v >>= 7;
        if (v == 0) {
            buf[len] = byte;
            len += 1;
            break;
        }
        buf[len] = byte | 0x80;
        len += 1;
    }
    return len;
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

pub const SeedDeserializer = struct {
    allocator: Allocator,
    reader: *Reader,
    depth: u32,
    depth_limit: u32,

    pub fn deserialize(self: *@This(), comptime T: type) Error!T {
        return deserializeValue(T, self.allocator, self.reader, self.depth, self.depth_limit);
    }

    pub fn deserializeSeed(self: *@This(), seed: anytype) (SeedError(@TypeOf(seed)) || Error)!SeedValue(@TypeOf(seed)) {
        return seedDeserialize(seed, self);
    }

    pub fn bytesRead(self: @This()) usize {
        return self.reader.pos;
    }
};

fn ReaderValueType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => std.meta.Child(T),
        else => T,
    };
}

fn ReaderReadByteError(comptime T: type) type {
    const read_byte_fn = @typeInfo(@TypeOf(ReaderValueType(T).readByte)).@"fn";
    const ret = read_byte_fn.return_type orelse @compileError("reader.readByte must return an error union");
    return @typeInfo(ret).error_union.error_set;
}

fn readAllReader(allocator: Allocator, reader: anytype) (ReaderReadByteError(@TypeOf(reader)) || Error)![]u8 {
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);

    var input = reader;
    while (true) {
        const byte = input.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try list.append(allocator, byte);
    }

    return list.toOwnedSlice(allocator);
}

fn SeedType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => std.meta.Child(T),
        else => T,
    };
}

fn SeedValue(comptime T: type) type {
    const SeedT = SeedType(T);
    if (!@hasDecl(SeedT, "Value")) @compileError("seed type must declare pub const Value");
    return SeedT.Value;
}

fn SeedReturnType(comptime T: type) type {
    const SeedT = SeedType(T);
    if (!@hasDecl(SeedT, "deserialize")) @compileError("seed type must declare pub fn deserialize(self, de: *SeedDeserializer)");
    const fn_info = @typeInfo(@TypeOf(SeedT.deserialize)).@"fn";
    const ret = fn_info.return_type orelse @compileError("seed deserialize must return an error union");
    const ret_info = @typeInfo(ret);
    if (ret_info != .error_union) @compileError("seed deserialize must return an error union");
    return ret_info.error_union.payload;
}

fn SeedError(comptime T: type) type {
    const SeedT = SeedType(T);
    if (!@hasDecl(SeedT, "deserialize")) @compileError("seed type must declare pub fn deserialize(self, de: *SeedDeserializer)");
    const fn_info = @typeInfo(@TypeOf(SeedT.deserialize)).@"fn";
    const ret = fn_info.return_type orelse @compileError("seed deserialize must return an error union");
    const ret_info = @typeInfo(ret);
    if (ret_info != .error_union) @compileError("seed deserialize must return an error union");
    if (SeedReturnType(T) != SeedValue(T)) @compileError("seed deserialize return type must match seed Value");
    return ret_info.error_union.error_set;
}

fn seedDeserialize(seed: anytype, de: *SeedDeserializer) (SeedError(@TypeOf(seed)) || Error)!SeedValue(@TypeOf(seed)) {
    return seed.deserialize(de);
}

fn freeSeedValue(seed: anytype, allocator: Allocator, value: anytype) void {
    const SeedT = SeedType(@TypeOf(seed));
    if (comptime @hasDecl(SeedT, "free")) {
        seed.free(allocator, value);
    } else {
        freeDeserialized(@TypeOf(value), allocator, value);
    }
}

// ── Integer Helpers ────────────────────────────────────────────────────

fn writeIntLittle(allocator: Allocator, list: *std.ArrayList(u8), comptime T: type, value: T) Error!void {
    if (comptime canBulkCopy(T)) {
        list.appendSlice(allocator, std.mem.asBytes(&value)) catch return Error.OutOfMemory;
        return;
    }

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

    if (comptime canBulkCopy(T)) {
        const bytes = try reader.readBytes(byte_count);
        var result: T = undefined;
        @memcpy(std.mem.asBytes(&result), bytes);
        return result;
    }

    if (reader.pos + byte_count > reader.data.len) return Error.UnexpectedEndOfInput;
    var result: U = 0;
    inline for (0..byte_count) |i| {
        result |= @as(U, reader.data[reader.pos + i]) << @intCast(i * 8);
    }
    reader.pos += byte_count;
    return @bitCast(result);
}

fn checkedSizeAdd(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch Error.OutOfMemory;
}

fn checkedSizeMul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch Error.OutOfMemory;
}

fn validateUtf8(bytes: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return Error.Utf8;
}

fn serializedSizeValue(value: anytype, depth: u32, depth_limit: u32) Error!usize {
    @setEvalBranchQuota(10000);
    const T = @TypeOf(value);
    if (comptime isBcsStringType(T)) {
        const bytes = bcsStringBytes(value);
        try validateUtf8(bytes);
        if (bytes.len > max_sequence_length) return Error.SequenceTooLong;
        return checkedSizeAdd(uleb128Size(@intCast(bytes.len)), bytes.len);
    }
    const info = @typeInfo(T);
    switch (info) {
        .bool => return 1,

        .int => |int_info| return @divExact(int_info.bits, 8),

        .optional => {
            if (value) |v| {
                const child_hint = comptime serializedSizeHint(@TypeOf(v));
                if (child_hint > 0) return checkedSizeAdd(1, child_hint);
                return checkedSizeAdd(1, try serializedSizeValue(v, depth, depth_limit));
            }
            return 1;
        },

        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    if (value.len > max_sequence_length) return Error.SequenceTooLong;
                    var total = uleb128Size(@intCast(value.len));
                    const child_hint = comptime serializedSizeHint(ptr_info.child);
                    if (ptr_info.child == u8) {
                        return checkedSizeAdd(total, value.len);
                    }
                    if (child_hint > 0) {
                        return checkedSizeAdd(total, try checkedSizeMul(value.len, child_hint));
                    }
                    if (comptime canBulkCopy(ptr_info.child)) {
                        return checkedSizeAdd(total, try checkedSizeMul(value.len, @sizeOf(ptr_info.child)));
                    }
                    for (value) |elem| {
                        total = try checkedSizeAdd(total, try serializedSizeValue(elem, depth, depth_limit));
                    }
                    return total;
                },
                .one => return serializedSizeValue(value.*, depth, depth_limit),
                else => @compileError("BCS: unsupported pointer type " ++ @typeName(T)),
            }
        },

        .array => |arr_info| {
            if (arr_info.child == u8) return arr_info.len;
            if (comptime canBulkCopy(arr_info.child)) {
                return checkedSizeMul(arr_info.len, @sizeOf(arr_info.child));
            }
            var total: usize = 0;
            for (value) |elem| {
                total = try checkedSizeAdd(total, try serializedSizeValue(elem, depth, depth_limit));
            }
            return total;
        },

        .@"struct" => |struct_info| {
            if (@hasDecl(T, "bcs_map") and T.bcs_map) {
                if (value.entries.len > max_sequence_length) return Error.SequenceTooLong;
                var writer = CountingWriter{};
                try serializeValueToWriter(std.heap.page_allocator, &writer, value, depth, depth_limit);
                return writer.count;
            }

            if (struct_info.is_tuple) {
                var total: usize = 0;
                inline for (struct_info.fields) |field| {
                    total = try checkedSizeAdd(total, try serializedSizeValue(@field(value, field.name), depth, depth_limit));
                }
                return total;
            }

            const new_depth = depth + 1;
            if (new_depth > depth_limit) return Error.ContainerTooDeep;
            var total: usize = 0;
            inline for (struct_info.fields) |field| {
                total = try checkedSizeAdd(total, try serializedSizeValue(@field(value, field.name), new_depth, depth_limit));
            }
            return total;
        },

        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("BCS: untagged unions not supported — use a tagged union");
            }

            const new_depth = depth + 1;
            if (new_depth > depth_limit) return Error.ContainerTooDeep;

            const tag = std.meta.activeTag(value);
            var total = uleb128Size(enumVariantIndex(std.meta.Tag(T), tag));
            inline for (union_info.fields) |field| {
                if (comptime std.meta.stringToEnum(std.meta.Tag(T), field.name)) |this_tag| {
                    if (tag == this_tag) {
                        if (field.type != void) {
                            total = try checkedSizeAdd(total, try serializedSizeValue(@field(value, field.name), new_depth, depth_limit));
                        }
                        return total;
                    }
                }
            }
            unreachable;
        },

        .@"enum" => return uleb128Size(enumVariantIndex(T, value)),

        .void => return 0,

        else => @compileError("BCS: unsupported type " ++ @typeName(T)),
    }
}

// ── Helpers ────────────────────────────────────────────────────────────

/// Returns true if a slice/array of T can be bulk-copied as raw bytes.
/// Only valid on little-endian platforms for integer types with byte-aligned widths.
fn canBulkCopy(comptime T: type) bool {
    if (native_endian != .little) return false;
    return switch (@typeInfo(T)) {
        .int => |info| info.bits % 8 == 0 and info.bits >= 8,
        else => false,
    };
}

fn intMapSortKeyType(comptime K: type) type {
    const info = @typeInfo(K).int;
    return @Type(.{ .int = .{ .signedness = .unsigned, .bits = info.bits } });
}

fn canUseIntMapFastPath(comptime K: type) bool {
    return switch (@typeInfo(K)) {
        .int => |info| info.bits % 8 == 0 and info.bits >= 8 and info.bits <= 128,
        else => false,
    };
}

fn isByteSliceMapKey(comptime K: type) bool {
    if (comptime isBcsStringType(K)) return true;
    return switch (@typeInfo(K)) {
        .pointer => |ptr_info| ptr_info.size == .slice and ptr_info.child == u8,
        else => false,
    };
}

fn byteSliceMapKeyBytes(value: anytype) []const u8 {
    const T = @TypeOf(value);
    if (comptime isBcsStringType(T)) return bcsStringBytes(value);
    return value;
}

fn validateByteSliceMapKey(value: anytype) Error![]const u8 {
    const T = @TypeOf(value);
    const bytes = byteSliceMapKeyBytes(value);
    if (comptime isBcsStringType(T)) try validateUtf8(bytes);
    return bytes;
}

fn deserializeByteSliceMapKey(comptime K: type, allocator: Allocator, bytes: []const u8) Error!K {
    if (comptime isBcsStringType(K)) {
        try validateUtf8(bytes);
        const owned = allocator.dupe(u8, bytes) catch return Error.OutOfMemory;
        return initBcsString(K, owned);
    }

    return allocator.dupe(u8, bytes) catch Error.OutOfMemory;
}

fn canUseArrayMapFastPath(comptime K: type) bool {
    return switch (@typeInfo(K)) {
        .array => |arr_info| arr_info.child == u8 or canBulkCopy(arr_info.child),
        else => false,
    };
}

fn arrayMapKeyBytes(value: anytype) []const u8 {
    return std.mem.asBytes(value);
}

fn fixedBytesPrefix(bytes: []const u8) u64 {
    if (bytes.len >= 8) {
        var raw: u64 = undefined;
        @memcpy(std.mem.asBytes(&raw), bytes[0..8]);
        return @byteSwap(raw);
    }

    var prefix: u64 = 0;
    for (bytes) |byte| {
        prefix = (prefix << 8) | byte;
    }
    prefix <<= @intCast((8 - bytes.len) * 8);
    return prefix;
}

fn fixedBytesOrder(comptime key_size: usize, a: []const u8, b: []const u8) std.math.Order {
    const full_chunks = comptime key_size / 8;
    inline for (0..full_chunks) |chunk_idx| {
        const offset = chunk_idx * 8;
        const a_chunk = fixedBytesPrefix(a[offset..][0..8]);
        const b_chunk = fixedBytesPrefix(b[offset..][0..8]);
        if (a_chunk < b_chunk) return .lt;
        if (a_chunk > b_chunk) return .gt;
    }

    const tail = comptime key_size % 8;
    if (tail != 0) {
        const offset = full_chunks * 8;
        const a_tail = fixedBytesPrefix(a[offset..][0..tail]);
        const b_tail = fixedBytesPrefix(b[offset..][0..tail]);
        if (a_tail < b_tail) return .lt;
        if (a_tail > b_tail) return .gt;
    }

    return .eq;
}

fn fixedBytesLessThan(comptime key_size: usize, a: []const u8, b: []const u8) bool {
    return fixedBytesOrder(key_size, a, b) == .lt;
}

fn fixedBytesOrderPrefixed(comptime key_size: usize, a_prefix: u64, a: []const u8, b_prefix: u64, b: []const u8) std.math.Order {
    if (a_prefix < b_prefix) return .lt;
    if (a_prefix > b_prefix) return .gt;
    if (comptime key_size <= 8) return .eq;
    return fixedBytesOrder(key_size, a, b);
}

fn fixedBytesLessThanPrefixed(comptime key_size: usize, a_prefix: u64, a: []const u8, b_prefix: u64, b: []const u8) bool {
    return fixedBytesOrderPrefixed(key_size, a_prefix, a, b_prefix, b) == .lt;
}

fn fixedBytesEqualPrefixed(comptime key_size: usize, a_prefix: u64, a: []const u8, b_prefix: u64, b: []const u8) bool {
    return fixedBytesOrderPrefixed(key_size, a_prefix, a, b_prefix, b) == .eq;
}

fn byteSliceKeyOrder(a_len_bytes: []const u8, a_key: []const u8, b_len_bytes: []const u8, b_key: []const u8) std.math.Order {
    const len_order = std.mem.order(u8, a_len_bytes, b_len_bytes);
    if (len_order != .eq) return len_order;
    return std.mem.order(u8, a_key, b_key);
}

fn byteSliceKeyLessThan(a_len_bytes: []const u8, a_key: []const u8, b_len_bytes: []const u8, b_key: []const u8) bool {
    return byteSliceKeyOrder(a_len_bytes, a_key, b_len_bytes, b_key) == .lt;
}

const inline_map_scratch_entries = 64;
const inline_map_scratch_bytes = 4096;

fn intMapSortKey(comptime K: type, value: K) intMapSortKeyType(K) {
    const U = intMapSortKeyType(K);
    const raw: U = @bitCast(value);
    return @byteSwap(raw);
}

// Compile-time proof: verify native memory layout matches BCS little-endian wire format.
// If this fires, the platform claims LE but stores integers differently — canBulkCopy is unsafe.
comptime {
    if (native_endian == .little) {
        const val: u32 = 0x04030201;
        const bytes = std.mem.asBytes(&val);
        if (bytes[0] != 0x01 or bytes[1] != 0x02 or bytes[2] != 0x03 or bytes[3] != 0x04)
            @compileError("BCS bulk copy requires native little-endian integer layout — " ++
                "platform reports LE but memory layout disagrees");
    }
}

fn serializeMapIntKeys(
    comptime K: type,
    allocator: Allocator,
    list: *std.ArrayList(u8),
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) Error!void {
    const count: u32 = @intCast(entries.len);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const SortKey = intMapSortKeyType(K);
    const SortItem = struct { sort_key: SortKey, index: usize };
    var stack_sort_items: [inline_map_scratch_entries]SortItem = undefined;
    const sort_items = if (entries.len <= inline_map_scratch_entries)
        stack_sort_items[0..entries.len]
    else
        allocator.alloc(SortItem, count) catch return Error.OutOfMemory;
    defer if (entries.len > inline_map_scratch_entries) allocator.free(sort_items);

    for (entries, 0..) |entry, i| {
        sort_items[i] = .{
            .sort_key = intMapSortKey(K, entry.key),
            .index = i,
        };
    }

    std.mem.sort(SortItem, sort_items, {}, struct {
        fn order(_: void, a: SortItem, b: SortItem) bool {
            if (a.sort_key != b.sort_key) return a.sort_key < b.sort_key;
            return a.index < b.index;
        }
    }.order);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_sort_key: SortKey = undefined;
    for (sort_items) |item| {
        if (!has_prev or prev_sort_key != item.sort_key) {
            unique_count += 1;
            prev_sort_key = item.sort_key;
            has_prev = true;
        }
    }

    try uleb128Append(allocator, list, @intCast(unique_count));
    has_prev = false;
    for (sort_items) |item| {
        if (has_prev and prev_sort_key == item.sort_key) continue;
        prev_sort_key = item.sort_key;
        has_prev = true;
        try writeIntLittle(allocator, list, K, entries[item.index].key);
        try serializeValue(allocator, list, entries[item.index].value, depth, depth_limit);
    }
}

fn serializeMapByteSliceKeys(allocator: Allocator, list: *std.ArrayList(u8), entries: anytype, depth: u32, depth_limit: u32) Error!void {
    const count: u32 = @intCast(entries.len);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const SortItem = struct {
        len_buf: [5]u8,
        len_len: u8,
        key: []const u8,
        index: usize,
    };
    var stack_sort_items: [inline_map_scratch_entries]SortItem = undefined;
    const sort_items = if (entries.len <= inline_map_scratch_entries)
        stack_sort_items[0..entries.len]
    else
        allocator.alloc(SortItem, count) catch return Error.OutOfMemory;
    defer if (entries.len > inline_map_scratch_entries) allocator.free(sort_items);

    for (entries, 0..) |entry, i| {
        const key = try validateByteSliceMapKey(entry.key);
        var len_buf: [5]u8 = undefined;
        const len_len = uleb128Encode(&len_buf, @intCast(key.len));
        sort_items[i] = .{
            .len_buf = len_buf,
            .len_len = @intCast(len_len),
            .key = key,
            .index = i,
        };
    }

    std.mem.sort(SortItem, sort_items, {}, struct {
        fn order(_: void, a: SortItem, b: SortItem) bool {
            const key_order = byteSliceKeyOrder(a.len_buf[0..a.len_len], a.key, b.len_buf[0..b.len_len], b.key);
            if (key_order != .eq) return key_order == .lt;
            return a.index < b.index;
        }
    }.order);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_len_buf: [5]u8 = undefined;
    var prev_len_len: u8 = 0;
    var prev_key: []const u8 = undefined;
    for (sort_items) |item| {
        const key = item.key;
        if (!has_prev or byteSliceKeyOrder(prev_len_buf[0..prev_len_len], prev_key, item.len_buf[0..item.len_len], key) != .eq) {
            unique_count += 1;
            @memcpy(prev_len_buf[0..item.len_len], item.len_buf[0..item.len_len]);
            prev_len_len = item.len_len;
            prev_key = key;
            has_prev = true;
        }
    }

    try uleb128Append(allocator, list, @intCast(unique_count));
    has_prev = false;
    for (sort_items) |item| {
        const key = item.key;
        if (has_prev and byteSliceKeyOrder(prev_len_buf[0..prev_len_len], prev_key, item.len_buf[0..item.len_len], key) == .eq) {
            continue;
        }

        @memcpy(prev_len_buf[0..item.len_len], item.len_buf[0..item.len_len]);
        prev_len_len = item.len_len;
        prev_key = key;
        has_prev = true;

        list.appendSlice(allocator, item.len_buf[0..item.len_len]) catch return Error.OutOfMemory;
        list.appendSlice(allocator, key) catch return Error.OutOfMemory;
        try serializeValue(allocator, list, entries[item.index].value, depth, depth_limit);
    }
}

fn serializeMapArrayKeys(comptime K: type, allocator: Allocator, list: *std.ArrayList(u8), entries: anytype, depth: u32, depth_limit: u32) Error!void {
    const count: u32 = @intCast(entries.len);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const key_size = comptime @sizeOf(K);
    const Entries = @TypeOf(entries);
    const SortItem = struct { prefix: u64, index: usize };
    var stack_sort_items: [inline_map_scratch_entries]SortItem = undefined;
    const sort_items = if (entries.len <= inline_map_scratch_entries)
        stack_sort_items[0..entries.len]
    else
        allocator.alloc(SortItem, count) catch return Error.OutOfMemory;
    defer if (entries.len > inline_map_scratch_entries) allocator.free(sort_items);

    for (entries, 0..) |entry, i| {
        sort_items[i] = .{
            .prefix = fixedBytesPrefix(arrayMapKeyBytes(&entry.key)),
            .index = i,
        };
    }

    std.mem.sort(SortItem, sort_items, entries, struct {
        fn order(ctx: Entries, a: SortItem, b: SortItem) bool {
            const key_order = fixedBytesOrderPrefixed(
                key_size,
                a.prefix,
                arrayMapKeyBytes(&ctx[a.index].key),
                b.prefix,
                arrayMapKeyBytes(&ctx[b.index].key),
            );
            if (key_order != .eq) return key_order == .lt;
            return a.index < b.index;
        }
    }.order);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_prefix: u64 = 0;
    var prev_key: []const u8 = undefined;
    for (sort_items) |item| {
        const key_bytes = arrayMapKeyBytes(&entries[item.index].key);
        if (!has_prev or fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, item.prefix, key_bytes) != .eq) {
            unique_count += 1;
            prev_prefix = item.prefix;
            prev_key = key_bytes;
            has_prev = true;
        }
    }

    try uleb128Append(allocator, list, @intCast(unique_count));
    has_prev = false;
    for (sort_items) |item| {
        const key_bytes = arrayMapKeyBytes(&entries[item.index].key);
        if (has_prev and fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, item.prefix, key_bytes) == .eq) continue;
        prev_prefix = item.prefix;
        prev_key = key_bytes;
        has_prev = true;
        list.appendSlice(allocator, key_bytes) catch return Error.OutOfMemory;
        try serializeValue(allocator, list, entries[item.index].value, depth, depth_limit);
    }
}

fn serializeMapFixedKeys(
    comptime key_size: usize,
    allocator: Allocator,
    list: *std.ArrayList(u8),
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) Error!void {
    const count: u32 = @intCast(entries.len);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const SortItem = struct { prefix: u64, offset: usize, index: usize };
    const SortContext = struct {
        key_storage: []const u8,
        key_size: usize,
    };
    var stack_sort_items: [inline_map_scratch_entries]SortItem = undefined;
    const sort_items = if (entries.len <= inline_map_scratch_entries)
        stack_sort_items[0..entries.len]
    else
        allocator.alloc(SortItem, count) catch return Error.OutOfMemory;
    defer if (entries.len > inline_map_scratch_entries) allocator.free(sort_items);

    const total_key_bytes = std.math.mul(usize, entries.len, key_size) catch return Error.OutOfMemory;
    var stack_key_storage: [inline_map_scratch_bytes]u8 = undefined;
    const key_storage = if (total_key_bytes <= inline_map_scratch_bytes)
        stack_key_storage[0..total_key_bytes]
    else
        allocator.alloc(u8, total_key_bytes) catch return Error.OutOfMemory;
    defer if (total_key_bytes > inline_map_scratch_bytes) allocator.free(key_storage);

    for (entries, 0..) |entry, i| {
        const offset = i * key_size;
        const key_bytes = key_storage[offset..][0..key_size];
        var writer = BufferWriter{ .buf = key_bytes };
        try serializeFixed(&writer, entry.key, depth, depth_limit);
        sort_items[i] = .{
            .prefix = fixedBytesPrefix(key_bytes),
            .offset = offset,
            .index = i,
        };
    }

    std.mem.sort(SortItem, sort_items, SortContext{ .key_storage = key_storage, .key_size = key_size }, struct {
        fn order(ctx: SortContext, a: SortItem, b: SortItem) bool {
            const key_order = fixedBytesOrderPrefixed(
                key_size,
                a.prefix,
                ctx.key_storage[a.offset..][0..ctx.key_size],
                b.prefix,
                ctx.key_storage[b.offset..][0..ctx.key_size],
            );
            if (key_order != .eq) return key_order == .lt;
            return a.index < b.index;
        }
    }.order);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_prefix: u64 = 0;
    var prev_key: []const u8 = undefined;
    for (sort_items) |item| {
        const key_bytes = key_storage[item.offset..][0..key_size];
        if (!has_prev or fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, item.prefix, key_bytes) != .eq) {
            unique_count += 1;
            prev_prefix = item.prefix;
            prev_key = key_bytes;
            has_prev = true;
        }
    }

    try uleb128Append(allocator, list, @intCast(unique_count));
    has_prev = false;
    for (sort_items) |item| {
        const key_bytes = key_storage[item.offset..][0..key_size];
        if (has_prev and fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, item.prefix, key_bytes) == .eq) continue;
        prev_prefix = item.prefix;
        prev_key = key_bytes;
        has_prev = true;
        list.appendSlice(allocator, key_bytes) catch return Error.OutOfMemory;
        try serializeValue(allocator, list, entries[item.index].value, depth, depth_limit);
    }
}

// ── Map Serialize/Deserialize ──────────────────────────────────────────

fn serializeCanonicalMapIntKeys(
    comptime K: type,
    allocator: Allocator,
    list: *std.ArrayList(u8),
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) Error!void {
    if (entries.len > max_sequence_length) return Error.SequenceTooLong;

    const SortKey = intMapSortKeyType(K);
    var unique_count: usize = 0;
    var has_prev = false;
    var prev_sort_key: SortKey = undefined;
    for (entries) |entry| {
        const sort_key = intMapSortKey(K, entry.key);
        if (has_prev and prev_sort_key > sort_key) return Error.NonCanonicalMap;
        if (!has_prev or prev_sort_key != sort_key) {
            unique_count += 1;
            prev_sort_key = sort_key;
            has_prev = true;
        }
    }

    try uleb128Append(allocator, list, @intCast(unique_count));
    has_prev = false;
    for (entries) |entry| {
        const sort_key = intMapSortKey(K, entry.key);
        if (has_prev and prev_sort_key == sort_key) continue;
        prev_sort_key = sort_key;
        has_prev = true;

        try writeIntLittle(allocator, list, K, entry.key);
        try serializeValue(allocator, list, entry.value, depth, depth_limit);
    }
}

fn serializeCanonicalMapByteSliceKeys(
    allocator: Allocator,
    list: *std.ArrayList(u8),
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) Error!void {
    if (entries.len > max_sequence_length) return Error.SequenceTooLong;

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_len_buf: [5]u8 = undefined;
    var prev_len_len: usize = 0;
    var prev_key: []const u8 = undefined;

    for (entries) |entry| {
        const key = try validateByteSliceMapKey(entry.key);
        var len_buf: [5]u8 = undefined;
        const len_len = uleb128Encode(&len_buf, @intCast(key.len));
        const len_bytes = len_buf[0..len_len];

        const key_order = if (has_prev)
            byteSliceKeyOrder(prev_len_buf[0..prev_len_len], prev_key, len_bytes, key)
        else
            std.math.Order.lt;
        if (has_prev and key_order == .gt) return Error.NonCanonicalMap;
        if (!has_prev or key_order != .eq) {
            unique_count += 1;
            @memcpy(prev_len_buf[0..len_len], len_bytes);
            prev_len_len = len_len;
            prev_key = key;
            has_prev = true;
        }
    }

    try uleb128Append(allocator, list, @intCast(unique_count));
    has_prev = false;
    for (entries) |entry| {
        const key = try validateByteSliceMapKey(entry.key);
        var len_buf: [5]u8 = undefined;
        const len_len = uleb128Encode(&len_buf, @intCast(key.len));
        const len_bytes = len_buf[0..len_len];
        if (has_prev and byteSliceKeyOrder(prev_len_buf[0..prev_len_len], prev_key, len_bytes, key) == .eq) continue;

        list.appendSlice(allocator, len_bytes) catch return Error.OutOfMemory;
        list.appendSlice(allocator, key) catch return Error.OutOfMemory;
        try serializeValue(allocator, list, entry.value, depth, depth_limit);

        @memcpy(prev_len_buf[0..len_len], len_bytes);
        prev_len_len = len_len;
        prev_key = key;
        has_prev = true;
    }
}

fn serializeCanonicalMapArrayKeys(
    comptime K: type,
    allocator: Allocator,
    list: *std.ArrayList(u8),
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) Error!void {
    if (entries.len > max_sequence_length) return Error.SequenceTooLong;
    const key_size = comptime @sizeOf(K);
    var unique_count: usize = 0;
    var has_prev = false;
    var prev_prefix: u64 = 0;
    var prev_key: []const u8 = undefined;

    for (entries) |entry| {
        const key_bytes = arrayMapKeyBytes(&entry.key);
        const prefix = fixedBytesPrefix(key_bytes);
        const key_order = if (has_prev)
            fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, prefix, key_bytes)
        else
            std.math.Order.lt;
        if (has_prev and key_order == .gt) return Error.NonCanonicalMap;
        if (!has_prev or key_order != .eq) {
            unique_count += 1;
            prev_prefix = prefix;
            prev_key = key_bytes;
            has_prev = true;
        }
    }

    try uleb128Append(allocator, list, @intCast(unique_count));
    has_prev = false;
    for (entries) |entry| {
        const key_bytes = arrayMapKeyBytes(&entry.key);
        const prefix = fixedBytesPrefix(key_bytes);
        if (has_prev and fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, prefix, key_bytes) == .eq) continue;

        list.appendSlice(allocator, key_bytes) catch return Error.OutOfMemory;
        try serializeValue(allocator, list, entry.value, depth, depth_limit);

        prev_prefix = prefix;
        prev_key = key_bytes;
        has_prev = true;
    }
}

fn serializeCanonicalMapFixedKeys(
    comptime key_size: usize,
    allocator: Allocator,
    list: *std.ArrayList(u8),
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) Error!void {
    if (entries.len > max_sequence_length) return Error.SequenceTooLong;

    var prev_stack: [inline_map_scratch_bytes]u8 = undefined;
    var curr_stack: [inline_map_scratch_bytes]u8 = undefined;
    const prev_buf = if (key_size <= inline_map_scratch_bytes)
        prev_stack[0..key_size]
    else
        allocator.alloc(u8, key_size) catch return Error.OutOfMemory;
    defer if (key_size > inline_map_scratch_bytes) allocator.free(prev_buf);
    const curr_buf = if (key_size <= inline_map_scratch_bytes)
        curr_stack[0..key_size]
    else
        allocator.alloc(u8, key_size) catch return Error.OutOfMemory;
    defer if (key_size > inline_map_scratch_bytes) allocator.free(curr_buf);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_prefix: u64 = 0;

    for (entries) |entry| {
        var writer = BufferWriter{ .buf = curr_buf };
        try serializeFixed(&writer, entry.key, depth, depth_limit);
        const prefix = fixedBytesPrefix(curr_buf);
        const key_order = if (has_prev)
            fixedBytesOrderPrefixed(key_size, prev_prefix, prev_buf, prefix, curr_buf)
        else
            std.math.Order.lt;
        if (has_prev and key_order == .gt) return Error.NonCanonicalMap;
        if (!has_prev or key_order != .eq) {
            unique_count += 1;
            prev_prefix = prefix;
            std.mem.copyForwards(u8, prev_buf, curr_buf);
            has_prev = true;
        }
    }

    try uleb128Append(allocator, list, @intCast(unique_count));
    has_prev = false;
    for (entries) |entry| {
        var writer = BufferWriter{ .buf = curr_buf };
        try serializeFixed(&writer, entry.key, depth, depth_limit);
        const prefix = fixedBytesPrefix(curr_buf);
        if (has_prev and fixedBytesOrderPrefixed(key_size, prev_prefix, prev_buf, prefix, curr_buf) == .eq) continue;

        list.appendSlice(allocator, curr_buf) catch return Error.OutOfMemory;
        try serializeValue(allocator, list, entry.value, depth, depth_limit);

        prev_prefix = prefix;
        std.mem.copyForwards(u8, prev_buf, curr_buf);
        has_prev = true;
    }
}

fn serializeCanonicalMapVariableKeys(
    comptime K: type,
    allocator: Allocator,
    list: *std.ArrayList(u8),
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) Error!void {
    _ = K;
    if (entries.len > max_sequence_length) return Error.SequenceTooLong;

    var prev_key_storage: std.ArrayList(u8) = .{};
    defer prev_key_storage.deinit(allocator);
    var curr_key_storage: std.ArrayList(u8) = .{};
    defer curr_key_storage.deinit(allocator);

    var unique_count: usize = 0;
    var has_prev = false;
    for (entries) |entry| {
        curr_key_storage.clearRetainingCapacity();
        const key_size = try serializedSizeValue(entry.key, depth, depth_limit);
        curr_key_storage.ensureTotalCapacityPrecise(allocator, key_size) catch return Error.OutOfMemory;
        var key_writer = ReservedListWriter{ .list = &curr_key_storage };
        try serializeValueToWriter(allocator, &key_writer, entry.key, depth, depth_limit);

        const key_order = if (has_prev)
            std.mem.order(u8, prev_key_storage.items, curr_key_storage.items)
        else
            std.math.Order.lt;
        if (has_prev and key_order == .gt) return Error.NonCanonicalMap;
        if (!has_prev or key_order != .eq) {
            unique_count += 1;
            has_prev = true;
            std.mem.swap(std.ArrayList(u8), &prev_key_storage, &curr_key_storage);
        }
    }

    try uleb128Append(allocator, list, @intCast(unique_count));
    prev_key_storage.clearRetainingCapacity();
    curr_key_storage.clearRetainingCapacity();
    has_prev = false;
    for (entries) |entry| {
        curr_key_storage.clearRetainingCapacity();
        const key_size = try serializedSizeValue(entry.key, depth, depth_limit);
        curr_key_storage.ensureTotalCapacityPrecise(allocator, key_size) catch return Error.OutOfMemory;
        var key_writer = ReservedListWriter{ .list = &curr_key_storage };
        try serializeValueToWriter(allocator, &key_writer, entry.key, depth, depth_limit);
        if (has_prev and std.mem.eql(u8, prev_key_storage.items, curr_key_storage.items)) continue;

        list.appendSlice(allocator, curr_key_storage.items) catch return Error.OutOfMemory;
        try serializeValue(allocator, list, entry.value, depth, depth_limit);

        std.mem.swap(std.ArrayList(u8), &prev_key_storage, &curr_key_storage);
        has_prev = true;
    }
}

fn serializeCanonicalMap(comptime K: type, allocator: Allocator, list: *std.ArrayList(u8), entries: anytype, depth: u32, depth_limit: u32) Error!void {
    const key_size = comptime serializedSizeHint(K);
    if (key_size > 0) {
        if (comptime canUseIntMapFastPath(K)) {
            return serializeCanonicalMapIntKeys(K, allocator, list, entries, depth, depth_limit);
        }
        if (comptime canUseArrayMapFastPath(K)) {
            return serializeCanonicalMapArrayKeys(K, allocator, list, entries, depth, depth_limit);
        }
        return serializeCanonicalMapFixedKeys(key_size, allocator, list, entries, depth, depth_limit);
    }

    if (comptime isByteSliceMapKey(K)) {
        return serializeCanonicalMapByteSliceKeys(allocator, list, entries, depth, depth_limit);
    }

    return serializeCanonicalMapVariableKeys(K, allocator, list, entries, depth, depth_limit);
}

fn serializeMap(comptime K: type, allocator: Allocator, list: *std.ArrayList(u8), entries: anytype, depth: u32, depth_limit: u32) Error!void {
    const key_size = comptime serializedSizeHint(K);
    if (key_size > 0) {
        if (comptime canUseIntMapFastPath(K)) {
            return serializeMapIntKeys(K, allocator, list, entries, depth, depth_limit);
        }
        if (comptime canUseArrayMapFastPath(K)) {
            return serializeMapArrayKeys(K, allocator, list, entries, depth, depth_limit);
        }
        return serializeMapFixedKeys(key_size, allocator, list, entries, depth, depth_limit);
    }

    if (comptime isByteSliceMapKey(K)) {
        return serializeMapByteSliceKeys(allocator, list, entries, depth, depth_limit);
    }

    const count: u32 = @intCast(entries.len);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const SortItem = struct { start: usize, end: usize, index: usize };
    var stack_sort_items: [inline_map_scratch_entries]SortItem = undefined;
    const sort_items = if (entries.len <= inline_map_scratch_entries)
        stack_sort_items[0..entries.len]
    else
        allocator.alloc(SortItem, count) catch return Error.OutOfMemory;
    defer if (entries.len > inline_map_scratch_entries) allocator.free(sort_items);

    var total_key_bytes: usize = 0;

    for (entries) |entry| {
        total_key_bytes = try checkedSizeAdd(total_key_bytes, try serializedSizeValue(entry.key, depth, depth_limit));
    }
    var stack_key_storage: [inline_map_scratch_bytes]u8 = undefined;
    const key_storage = if (total_key_bytes <= inline_map_scratch_bytes)
        stack_key_storage[0..total_key_bytes]
    else
        allocator.alloc(u8, total_key_bytes) catch return Error.OutOfMemory;
    defer if (total_key_bytes > inline_map_scratch_bytes) allocator.free(key_storage);
    var key_writer = BufferWriter{ .buf = key_storage };

    for (entries, 0..) |entry, i| {
        const start = key_writer.pos;
        try serializeValueToWriter(allocator, &key_writer, entry.key, depth, depth_limit);
        sort_items[i] = .{
            .start = start,
            .end = key_writer.pos,
            .index = i,
        };
    }

    std.mem.sort(SortItem, sort_items, key_storage, struct {
        fn order(key_bytes: []const u8, a: SortItem, b: SortItem) bool {
            const a_key = key_bytes[a.start..a.end];
            const b_key = key_bytes[b.start..b.end];
            const key_order = std.mem.order(u8, a_key, b_key);
            if (key_order != .eq) return key_order == .lt;
            return a.index < b.index;
        }
    }.order);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_key: []const u8 = undefined;
    for (sort_items) |item| {
        const key = key_storage[item.start..item.end];
        if (!has_prev or !std.mem.eql(u8, prev_key, key)) {
            unique_count += 1;
            prev_key = key;
            has_prev = true;
        }
    }

    try uleb128Append(allocator, list, @intCast(unique_count));
    has_prev = false;
    for (sort_items) |item| {
        const key = key_storage[item.start..item.end];
        if (has_prev and std.mem.eql(u8, prev_key, key)) continue;
        prev_key = key;
        has_prev = true;
        list.appendSlice(allocator, key) catch return Error.OutOfMemory;
        try serializeValue(allocator, list, entries[item.index].value, depth, depth_limit);
    }
}

fn deserializeMap(comptime M: type, allocator: Allocator, reader: *Reader, depth: u32, depth_limit: u32) Error!M {
    const K = M.Key;
    const V = M.Value;
    const key_size = comptime serializedSizeHint(K);
    if (key_size > 0) {
        if (comptime canUseIntMapFastPath(K)) {
            return deserializeMapIntKeys(M, allocator, reader, depth, depth_limit);
        }
        if (comptime canUseArrayMapFastPath(K)) {
            return deserializeMapArrayKeys(M, allocator, reader, depth, depth_limit);
        }
        return deserializeMapFixedKeys(M, key_size, allocator, reader, depth, depth_limit);
    }

    if (comptime isByteSliceMapKey(K)) {
        return deserializeMapByteSliceKeys(M, allocator, reader, depth, depth_limit);
    }

    const count = try uleb128Read(reader);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const EntryType = M.Entry;
    const entries = allocator.alloc(EntryType, count) catch return Error.OutOfMemory;

    var prev_key_end: usize = 0;
    var prev_key_start: usize = 0;

    for (entries, 0..) |*entry, i| {
        const key_start = reader.pos;
        entry.key = try deserializeValue(K, allocator, reader, depth, depth_limit);
        const key_end = reader.pos;

        if (i > 0) {
            const prev = reader.data[prev_key_start..prev_key_end];
            const curr = reader.data[key_start..key_end];
            if (!std.mem.lessThan(u8, prev, curr)) {
                // Free what we've allocated so far
                for (entries[0 .. i + 1]) |e| freeDeserializedMode(K, allocator, e.key);
                allocator.free(entries);
                return Error.NonCanonicalMap;
            }
        }

        prev_key_start = key_start;
        prev_key_end = key_end;

        entry.value = try deserializeValue(V, allocator, reader, depth, depth_limit);
    }

    return M{ .entries = entries };
}

fn deserializeMapByteSliceKeys(comptime M: type, allocator: Allocator, reader: *Reader, depth: u32, depth_limit: u32) Error!M {
    const K = M.Key;
    const V = M.Value;
    const count = try uleb128Read(reader);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const EntryType = M.Entry;
    const entries = allocator.alloc(EntryType, count) catch return Error.OutOfMemory;
    errdefer allocator.free(entries);

    var initialized_keys: usize = 0;
    var initialized_values: usize = 0;
    errdefer {
        for (entries[0..initialized_values]) |entry| {
            freeDeserializedMode(V, allocator, entry.value);
        }
        for (entries[0..initialized_keys]) |entry| freeDeserializedMode(K, allocator, entry.key);
    }

    var prev_key_end: usize = 0;
    var prev_key_start: usize = 0;

    for (entries, 0..) |*entry, i| {
        const key_start = reader.pos;
        const len = try uleb128Read(reader);
        if (len > max_sequence_length) return Error.SequenceTooLong;
        const key_bytes = try reader.readBytes(len);
        entry.key = try deserializeByteSliceMapKey(K, allocator, key_bytes);
        initialized_keys = i + 1;
        const key_end = reader.pos;

        if (i > 0) {
            const prev = reader.data[prev_key_start..prev_key_end];
            const curr = reader.data[key_start..key_end];
            if (!std.mem.lessThan(u8, prev, curr)) {
                return Error.NonCanonicalMap;
            }
        }

        prev_key_start = key_start;
        prev_key_end = key_end;
        entry.value = try deserializeValue(V, allocator, reader, depth, depth_limit);
        initialized_values = i + 1;
    }

    return M{ .entries = entries };
}

fn deserializeMapIntKeys(comptime M: type, allocator: Allocator, reader: *Reader, depth: u32, depth_limit: u32) Error!M {
    const K = M.Key;
    const V = M.Value;
    const count = try uleb128Read(reader);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const SortKey = intMapSortKeyType(K);
    const EntryType = M.Entry;
    const entries = allocator.alloc(EntryType, count) catch return Error.OutOfMemory;
    errdefer allocator.free(entries);

    var initialized_values: usize = 0;
    errdefer {
        for (entries[0..initialized_values]) |entry| {
            freeDeserializedMode(V, allocator, entry.value);
        }
    }

    var prev_sort_key: SortKey = undefined;
    for (entries, 0..) |*entry, i| {
        entry.key = try readIntLittle(K, reader);
        const sort_key = intMapSortKey(K, entry.key);

        if (i > 0 and prev_sort_key >= sort_key) {
            return Error.NonCanonicalMap;
        }

        prev_sort_key = sort_key;
        entry.value = try deserializeValue(V, allocator, reader, depth, depth_limit);
        initialized_values = i + 1;
    }

    return M{ .entries = entries };
}

fn deserializeMapArrayKeys(comptime M: type, allocator: Allocator, reader: *Reader, depth: u32, depth_limit: u32) Error!M {
    const K = M.Key;
    const V = M.Value;
    const count = try uleb128Read(reader);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const key_size = comptime @sizeOf(K);
    const EntryType = M.Entry;
    const entries = allocator.alloc(EntryType, count) catch return Error.OutOfMemory;
    errdefer allocator.free(entries);

    var initialized_values: usize = 0;
    errdefer {
        for (entries[0..initialized_values]) |entry| {
            freeDeserializedMode(V, allocator, entry.value);
        }
    }

    var prev_prefix: u64 = 0;
    for (entries, 0..) |*entry, i| {
        entry.key = try deserializeFixed(K, reader, depth, depth_limit);
        const key_bytes = arrayMapKeyBytes(&entry.key);
        const prefix = fixedBytesPrefix(key_bytes);

        if (i > 0 and !fixedBytesLessThanPrefixed(
            key_size,
            prev_prefix,
            arrayMapKeyBytes(&entries[i - 1].key),
            prefix,
            key_bytes,
        )) {
            return Error.NonCanonicalMap;
        }

        prev_prefix = prefix;
        entry.value = try deserializeValue(V, allocator, reader, depth, depth_limit);
        initialized_values = i + 1;
    }

    return M{ .entries = entries };
}

fn deserializeMapFixedKeys(comptime M: type, comptime key_size: usize, allocator: Allocator, reader: *Reader, depth: u32, depth_limit: u32) Error!M {
    const K = M.Key;
    const V = M.Value;
    const count = try uleb128Read(reader);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const EntryType = M.Entry;
    const entries = allocator.alloc(EntryType, count) catch return Error.OutOfMemory;
    errdefer allocator.free(entries);

    var initialized_values: usize = 0;
    errdefer {
        for (entries[0..initialized_values]) |entry| {
            freeDeserializedMode(V, allocator, entry.value);
        }
    }

    var prev_key_start: usize = 0;
    var prev_prefix: u64 = 0;
    for (entries, 0..) |*entry, i| {
        const key_start = reader.pos;
        entry.key = try deserializeValue(K, allocator, reader, depth, depth_limit);
        const curr = reader.data[key_start..][0..key_size];
        const prefix = fixedBytesPrefix(curr);

        if (i > 0) {
            const prev = reader.data[prev_key_start..][0..key_size];
            if (!fixedBytesLessThanPrefixed(key_size, prev_prefix, prev, prefix, curr)) {
                return Error.NonCanonicalMap;
            }
        }

        prev_prefix = prefix;
        prev_key_start = key_start;
        entry.value = try deserializeValue(V, allocator, reader, depth, depth_limit);
        initialized_values = i + 1;
    }

    return M{ .entries = entries };
}

// ── Serialize ──────────────────────────────────────────────────────────

fn serializeValue(allocator: Allocator, list: *std.ArrayList(u8), value: anytype, depth: u32, depth_limit: u32) Error!void {
    @setEvalBranchQuota(10000);
    const T = @TypeOf(value);
    if (comptime isBcsStringType(T)) {
        const bytes = bcsStringBytes(value);
        try validateUtf8(bytes);
        if (bytes.len > max_sequence_length) return Error.SequenceTooLong;
        try uleb128Append(allocator, list, @intCast(bytes.len));
        list.appendSlice(allocator, bytes) catch return Error.OutOfMemory;
        return;
    }
    const info = @typeInfo(T);

    switch (info) {
        .bool => list.append(allocator, if (value) @as(u8, 1) else @as(u8, 0)) catch return Error.OutOfMemory,

        .int => try writeIntLittle(allocator, list, T, value),

        .optional => {
            if (value) |v| {
                list.append(allocator, 0x01) catch return Error.OutOfMemory;
                try serializeValue(allocator, list, v, depth, depth_limit);
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
                    } else if (comptime canBulkCopy(ptr_info.child)) {
                        list.appendSlice(allocator, std.mem.sliceAsBytes(value)) catch return Error.OutOfMemory;
                    } else {
                        for (value) |elem| {
                            try serializeValue(allocator, list, elem, depth, depth_limit);
                        }
                    }
                },
                .one => try serializeValue(allocator, list, value.*, depth, depth_limit),
                else => @compileError("BCS: unsupported pointer type " ++ @typeName(T)),
            }
        },

        .array => |arr_info| {
            if (arr_info.child == u8) {
                list.appendSlice(allocator, &value) catch return Error.OutOfMemory;
            } else if (comptime canBulkCopy(arr_info.child)) {
                list.appendSlice(allocator, std.mem.asBytes(&value)) catch return Error.OutOfMemory;
            } else {
                for (value) |elem| {
                    try serializeValue(allocator, list, elem, depth, depth_limit);
                }
            }
        },

        .@"struct" => |struct_info| {
            if (@hasDecl(T, "bcs_map") and T.bcs_map) {
                if (comptime isCanonicalMapType(T)) {
                    try serializeCanonicalMap(T.Key, allocator, list, value.entries, depth, depth_limit);
                } else {
                    try serializeMap(T.Key, allocator, list, value.entries, depth, depth_limit);
                }
            } else if (struct_info.is_tuple) {
                inline for (struct_info.fields) |field| {
                    try serializeValue(allocator, list, @field(value, field.name), depth, depth_limit);
                }
            } else {
                const new_depth = depth + 1;
                if (new_depth > depth_limit) return Error.ContainerTooDeep;
                inline for (struct_info.fields) |field| {
                    try serializeValue(allocator, list, @field(value, field.name), new_depth, depth_limit);
                }
            }
        },

        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("BCS: untagged unions not supported — use a tagged union");
            }
            const new_depth = depth + 1;
            if (new_depth > depth_limit) return Error.ContainerTooDeep;

            const tag = std.meta.activeTag(value);
            const index = enumVariantIndex(std.meta.Tag(T), tag);
            try uleb128Append(allocator, list, index);

            inline for (union_info.fields) |field| {
                if (comptime std.meta.stringToEnum(std.meta.Tag(T), field.name)) |this_tag| {
                    if (tag == this_tag) {
                        if (field.type != void) {
                            try serializeValue(allocator, list, @field(value, field.name), new_depth, depth_limit);
                        }
                        return;
                    }
                }
            }
        },

        .@"enum" => {
            try uleb128Append(allocator, list, enumVariantIndex(T, value));
        },

        .void => {},

        else => @compileError("BCS: unsupported type " ++ @typeName(T)),
    }
}

fn WriterValueType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => std.meta.Child(T),
        else => T,
    };
}

fn WriterError(comptime T: type) type {
    return WriterValueType(T).Error;
}

fn writerWriteByte(writer: anytype, byte: u8) WriterError(@TypeOf(writer))!void {
    if (comptime @hasDecl(WriterValueType(@TypeOf(writer)), "writeByte")) {
        return writer.writeByte(byte);
    }

    const buf = [_]u8{byte};
    try writer.writeAll(&buf);
}

fn uleb128WriteWriter(writer: anytype, value: u32) WriterError(@TypeOf(writer))!void {
    var buf: [5]u8 = undefined;
    const len = uleb128Encode(&buf, value);
    try writer.writeAll(buf[0..len]);
}

fn writeIntLittleWriter(writer: anytype, comptime T: type, value: T) WriterError(@TypeOf(writer))!void {
    if (comptime canBulkCopy(T)) {
        try writer.writeAll(std.mem.asBytes(&value));
        return;
    }

    const info = @typeInfo(T).int;
    const byte_count = comptime @divExact(info.bits, 8);
    const U = @Type(.{ .int = .{ .signedness = .unsigned, .bits = info.bits } });
    const uvalue: U = @bitCast(value);
    var buf: [byte_count]u8 = undefined;
    inline for (0..byte_count) |i| {
        buf[i] = @truncate(uvalue >> @intCast(i * 8));
    }
    try writer.writeAll(&buf);
}

fn serializeFixedToWriter(writer: anytype, value: anytype, depth: u32, depth_limit: u32) (WriterError(@TypeOf(writer)) || Error)!void {
    @setEvalBranchQuota(10000);
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .bool => {
            try writerWriteByte(writer, if (value) 1 else 0);
        },
        .int => {
            try writeIntLittleWriter(writer, T, value);
        },
        .array => |arr_info| {
            if (arr_info.child == u8) {
                try writer.writeAll(&value);
            } else if (comptime canBulkCopy(arr_info.child)) {
                try writer.writeAll(std.mem.asBytes(&value));
            } else {
                for (value) |elem| {
                    try serializeFixedToWriter(writer, elem, depth, depth_limit);
                }
            }
        },
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                inline for (struct_info.fields) |field| {
                    try serializeFixedToWriter(writer, @field(value, field.name), depth, depth_limit);
                }
            } else {
                const new_depth = depth + 1;
                if (new_depth > depth_limit) return Error.ContainerTooDeep;
                inline for (struct_info.fields) |field| {
                    try serializeFixedToWriter(writer, @field(value, field.name), new_depth, depth_limit);
                }
            }
        },
        else => unreachable,
    }
}

fn serializeMapIntKeysToWriter(
    comptime K: type,
    allocator: Allocator,
    writer: anytype,
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) (WriterError(@TypeOf(writer)) || Error)!void {
    const count: u32 = @intCast(entries.len);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const SortKey = intMapSortKeyType(K);
    const SortItem = struct { sort_key: SortKey, index: usize };
    var stack_sort_items: [inline_map_scratch_entries]SortItem = undefined;
    const sort_items = if (entries.len <= inline_map_scratch_entries)
        stack_sort_items[0..entries.len]
    else
        allocator.alloc(SortItem, count) catch return Error.OutOfMemory;
    defer if (entries.len > inline_map_scratch_entries) allocator.free(sort_items);

    for (entries, 0..) |entry, i| {
        sort_items[i] = .{
            .sort_key = intMapSortKey(K, entry.key),
            .index = i,
        };
    }

    std.mem.sort(SortItem, sort_items, {}, struct {
        fn order(_: void, a: SortItem, b: SortItem) bool {
            if (a.sort_key != b.sort_key) return a.sort_key < b.sort_key;
            return a.index < b.index;
        }
    }.order);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_sort_key: SortKey = undefined;
    for (sort_items) |item| {
        if (!has_prev or prev_sort_key != item.sort_key) {
            unique_count += 1;
            prev_sort_key = item.sort_key;
            has_prev = true;
        }
    }

    try uleb128WriteWriter(writer, @intCast(unique_count));
    has_prev = false;
    for (sort_items) |item| {
        if (has_prev and prev_sort_key == item.sort_key) continue;
        prev_sort_key = item.sort_key;
        has_prev = true;
        try writeIntLittleWriter(writer, K, entries[item.index].key);
        try serializeValueToWriter(allocator, writer, entries[item.index].value, depth, depth_limit);
    }
}

fn serializeMapByteSliceKeysToWriter(
    allocator: Allocator,
    writer: anytype,
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) (WriterError(@TypeOf(writer)) || Error)!void {
    const count: u32 = @intCast(entries.len);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const SortItem = struct {
        len_buf: [5]u8,
        len_len: u8,
        key: []const u8,
        index: usize,
    };
    var stack_sort_items: [inline_map_scratch_entries]SortItem = undefined;
    const sort_items = if (entries.len <= inline_map_scratch_entries)
        stack_sort_items[0..entries.len]
    else
        allocator.alloc(SortItem, count) catch return Error.OutOfMemory;
    defer if (entries.len > inline_map_scratch_entries) allocator.free(sort_items);

    for (entries, 0..) |entry, i| {
        const key = try validateByteSliceMapKey(entry.key);
        var len_buf: [5]u8 = undefined;
        const len_len = uleb128Encode(&len_buf, @intCast(key.len));
        sort_items[i] = .{
            .len_buf = len_buf,
            .len_len = @intCast(len_len),
            .key = key,
            .index = i,
        };
    }

    std.mem.sort(SortItem, sort_items, {}, struct {
        fn order(_: void, a: SortItem, b: SortItem) bool {
            const key_order = byteSliceKeyOrder(a.len_buf[0..a.len_len], a.key, b.len_buf[0..b.len_len], b.key);
            if (key_order != .eq) return key_order == .lt;
            return a.index < b.index;
        }
    }.order);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_len_buf: [5]u8 = undefined;
    var prev_len_len: u8 = 0;
    var prev_key: []const u8 = undefined;
    for (sort_items) |item| {
        const key = item.key;
        if (!has_prev or byteSliceKeyOrder(prev_len_buf[0..prev_len_len], prev_key, item.len_buf[0..item.len_len], key) != .eq) {
            unique_count += 1;
            @memcpy(prev_len_buf[0..item.len_len], item.len_buf[0..item.len_len]);
            prev_len_len = item.len_len;
            prev_key = key;
            has_prev = true;
        }
    }

    try uleb128WriteWriter(writer, @intCast(unique_count));
    has_prev = false;
    for (sort_items) |item| {
        const key = item.key;
        if (has_prev and byteSliceKeyOrder(prev_len_buf[0..prev_len_len], prev_key, item.len_buf[0..item.len_len], key) == .eq) {
            continue;
        }

        @memcpy(prev_len_buf[0..item.len_len], item.len_buf[0..item.len_len]);
        prev_len_len = item.len_len;
        prev_key = key;
        has_prev = true;

        try writer.writeAll(item.len_buf[0..item.len_len]);
        try writer.writeAll(key);
        try serializeValueToWriter(allocator, writer, entries[item.index].value, depth, depth_limit);
    }
}

fn serializeMapArrayKeysToWriter(
    comptime K: type,
    allocator: Allocator,
    writer: anytype,
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) (WriterError(@TypeOf(writer)) || Error)!void {
    const count: u32 = @intCast(entries.len);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const key_size = comptime @sizeOf(K);
    const Entries = @TypeOf(entries);
    const SortItem = struct { prefix: u64, index: usize };
    var stack_sort_items: [inline_map_scratch_entries]SortItem = undefined;
    const sort_items = if (entries.len <= inline_map_scratch_entries)
        stack_sort_items[0..entries.len]
    else
        allocator.alloc(SortItem, count) catch return Error.OutOfMemory;
    defer if (entries.len > inline_map_scratch_entries) allocator.free(sort_items);

    for (entries, 0..) |entry, i| {
        sort_items[i] = .{
            .prefix = fixedBytesPrefix(arrayMapKeyBytes(&entry.key)),
            .index = i,
        };
    }

    std.mem.sort(SortItem, sort_items, entries, struct {
        fn order(ctx: Entries, a: SortItem, b: SortItem) bool {
            const key_order = fixedBytesOrderPrefixed(
                key_size,
                a.prefix,
                arrayMapKeyBytes(&ctx[a.index].key),
                b.prefix,
                arrayMapKeyBytes(&ctx[b.index].key),
            );
            if (key_order != .eq) return key_order == .lt;
            return a.index < b.index;
        }
    }.order);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_prefix: u64 = 0;
    var prev_key: []const u8 = undefined;
    for (sort_items) |item| {
        const key_bytes = arrayMapKeyBytes(&entries[item.index].key);
        if (!has_prev or fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, item.prefix, key_bytes) != .eq) {
            unique_count += 1;
            prev_prefix = item.prefix;
            prev_key = key_bytes;
            has_prev = true;
        }
    }

    try uleb128WriteWriter(writer, @intCast(unique_count));
    has_prev = false;
    for (sort_items) |item| {
        const key_bytes = arrayMapKeyBytes(&entries[item.index].key);
        if (has_prev and fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, item.prefix, key_bytes) == .eq) continue;
        prev_prefix = item.prefix;
        prev_key = key_bytes;
        has_prev = true;
        try writer.writeAll(key_bytes);
        try serializeValueToWriter(allocator, writer, entries[item.index].value, depth, depth_limit);
    }
}

fn serializeMapFixedKeysToWriter(
    comptime key_size: usize,
    allocator: Allocator,
    writer: anytype,
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) (WriterError(@TypeOf(writer)) || Error)!void {
    const count: u32 = @intCast(entries.len);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const SortItem = struct { prefix: u64, offset: usize, index: usize };
    const SortContext = struct {
        key_storage: []const u8,
        key_size: usize,
    };
    var stack_sort_items: [inline_map_scratch_entries]SortItem = undefined;
    const sort_items = if (entries.len <= inline_map_scratch_entries)
        stack_sort_items[0..entries.len]
    else
        allocator.alloc(SortItem, count) catch return Error.OutOfMemory;
    defer if (entries.len > inline_map_scratch_entries) allocator.free(sort_items);

    const total_key_bytes = std.math.mul(usize, entries.len, key_size) catch return Error.OutOfMemory;
    var stack_key_storage: [inline_map_scratch_bytes]u8 = undefined;
    const key_storage = if (total_key_bytes <= inline_map_scratch_bytes)
        stack_key_storage[0..total_key_bytes]
    else
        allocator.alloc(u8, total_key_bytes) catch return Error.OutOfMemory;
    defer if (total_key_bytes > inline_map_scratch_bytes) allocator.free(key_storage);

    for (entries, 0..) |entry, i| {
        const offset = i * key_size;
        const key_bytes = key_storage[offset..][0..key_size];
        var buffer_writer = BufferWriter{ .buf = key_bytes };
        try serializeFixed(&buffer_writer, entry.key, depth, depth_limit);
        sort_items[i] = .{
            .prefix = fixedBytesPrefix(key_bytes),
            .offset = offset,
            .index = i,
        };
    }

    std.mem.sort(SortItem, sort_items, SortContext{ .key_storage = key_storage, .key_size = key_size }, struct {
        fn order(ctx: SortContext, a: SortItem, b: SortItem) bool {
            const key_order = fixedBytesOrderPrefixed(
                key_size,
                a.prefix,
                ctx.key_storage[a.offset..][0..ctx.key_size],
                b.prefix,
                ctx.key_storage[b.offset..][0..ctx.key_size],
            );
            if (key_order != .eq) return key_order == .lt;
            return a.index < b.index;
        }
    }.order);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_prefix: u64 = 0;
    var prev_key: []const u8 = undefined;
    for (sort_items) |item| {
        const key_bytes = key_storage[item.offset..][0..key_size];
        if (!has_prev or fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, item.prefix, key_bytes) != .eq) {
            unique_count += 1;
            prev_prefix = item.prefix;
            prev_key = key_bytes;
            has_prev = true;
        }
    }

    try uleb128WriteWriter(writer, @intCast(unique_count));
    has_prev = false;
    for (sort_items) |item| {
        const key_bytes = key_storage[item.offset..][0..key_size];
        if (has_prev and fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, item.prefix, key_bytes) == .eq) continue;
        prev_prefix = item.prefix;
        prev_key = key_bytes;
        has_prev = true;
        try writer.writeAll(key_bytes);
        try serializeValueToWriter(allocator, writer, entries[item.index].value, depth, depth_limit);
    }
}

fn serializeCanonicalMapIntKeysToWriter(
    comptime K: type,
    allocator: Allocator,
    writer: anytype,
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) (WriterError(@TypeOf(writer)) || Error)!void {
    if (entries.len > max_sequence_length) return Error.SequenceTooLong;

    const SortKey = intMapSortKeyType(K);
    var unique_count: usize = 0;
    var has_prev = false;
    var prev_sort_key: SortKey = undefined;
    for (entries) |entry| {
        const sort_key = intMapSortKey(K, entry.key);
        if (has_prev and prev_sort_key > sort_key) return Error.NonCanonicalMap;
        if (!has_prev or prev_sort_key != sort_key) {
            unique_count += 1;
            prev_sort_key = sort_key;
            has_prev = true;
        }
    }

    try uleb128WriteWriter(writer, @intCast(unique_count));
    has_prev = false;
    for (entries) |entry| {
        const sort_key = intMapSortKey(K, entry.key);
        if (has_prev and prev_sort_key == sort_key) continue;
        prev_sort_key = sort_key;
        has_prev = true;

        try writeIntLittleWriter(writer, K, entry.key);
        try serializeValueToWriter(allocator, writer, entry.value, depth, depth_limit);
    }
}

fn serializeCanonicalMapByteSliceKeysToWriter(
    allocator: Allocator,
    writer: anytype,
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) (WriterError(@TypeOf(writer)) || Error)!void {
    if (entries.len > max_sequence_length) return Error.SequenceTooLong;

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_len_buf: [5]u8 = undefined;
    var prev_len_len: usize = 0;
    var prev_key: []const u8 = undefined;

    for (entries) |entry| {
        const key = try validateByteSliceMapKey(entry.key);
        var len_buf: [5]u8 = undefined;
        const len_len = uleb128Encode(&len_buf, @intCast(key.len));
        const len_bytes = len_buf[0..len_len];

        const key_order = if (has_prev)
            byteSliceKeyOrder(prev_len_buf[0..prev_len_len], prev_key, len_bytes, key)
        else
            std.math.Order.lt;
        if (has_prev and key_order == .gt) return Error.NonCanonicalMap;
        if (!has_prev or key_order != .eq) {
            unique_count += 1;
            @memcpy(prev_len_buf[0..len_len], len_bytes);
            prev_len_len = len_len;
            prev_key = key;
            has_prev = true;
        }
    }

    try uleb128WriteWriter(writer, @intCast(unique_count));
    has_prev = false;
    for (entries) |entry| {
        const key = try validateByteSliceMapKey(entry.key);
        var len_buf: [5]u8 = undefined;
        const len_len = uleb128Encode(&len_buf, @intCast(key.len));
        const len_bytes = len_buf[0..len_len];
        if (has_prev and byteSliceKeyOrder(prev_len_buf[0..prev_len_len], prev_key, len_bytes, key) == .eq) continue;

        try writer.writeAll(len_bytes);
        try writer.writeAll(key);
        try serializeValueToWriter(allocator, writer, entry.value, depth, depth_limit);

        @memcpy(prev_len_buf[0..len_len], len_bytes);
        prev_len_len = len_len;
        prev_key = key;
        has_prev = true;
    }
}

fn serializeCanonicalMapArrayKeysToWriter(
    comptime K: type,
    allocator: Allocator,
    writer: anytype,
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) (WriterError(@TypeOf(writer)) || Error)!void {
    if (entries.len > max_sequence_length) return Error.SequenceTooLong;
    const key_size = comptime @sizeOf(K);
    var unique_count: usize = 0;
    var has_prev = false;
    var prev_prefix: u64 = 0;
    var prev_key: []const u8 = undefined;

    for (entries) |entry| {
        const key_bytes = arrayMapKeyBytes(&entry.key);
        const prefix = fixedBytesPrefix(key_bytes);
        const key_order = if (has_prev)
            fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, prefix, key_bytes)
        else
            std.math.Order.lt;
        if (has_prev and key_order == .gt) return Error.NonCanonicalMap;
        if (!has_prev or key_order != .eq) {
            unique_count += 1;
            prev_prefix = prefix;
            prev_key = key_bytes;
            has_prev = true;
        }
    }

    try uleb128WriteWriter(writer, @intCast(unique_count));
    has_prev = false;
    for (entries) |entry| {
        const key_bytes = arrayMapKeyBytes(&entry.key);
        const prefix = fixedBytesPrefix(key_bytes);
        if (has_prev and fixedBytesOrderPrefixed(key_size, prev_prefix, prev_key, prefix, key_bytes) == .eq) continue;

        try writer.writeAll(key_bytes);
        try serializeValueToWriter(allocator, writer, entry.value, depth, depth_limit);

        prev_prefix = prefix;
        prev_key = key_bytes;
        has_prev = true;
    }
}

fn serializeCanonicalMapFixedKeysToWriter(
    comptime key_size: usize,
    allocator: Allocator,
    writer: anytype,
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) (WriterError(@TypeOf(writer)) || Error)!void {
    if (entries.len > max_sequence_length) return Error.SequenceTooLong;

    var prev_stack: [inline_map_scratch_bytes]u8 = undefined;
    var curr_stack: [inline_map_scratch_bytes]u8 = undefined;
    const prev_buf = if (key_size <= inline_map_scratch_bytes)
        prev_stack[0..key_size]
    else
        allocator.alloc(u8, key_size) catch return Error.OutOfMemory;
    defer if (key_size > inline_map_scratch_bytes) allocator.free(prev_buf);
    const curr_buf = if (key_size <= inline_map_scratch_bytes)
        curr_stack[0..key_size]
    else
        allocator.alloc(u8, key_size) catch return Error.OutOfMemory;
    defer if (key_size > inline_map_scratch_bytes) allocator.free(curr_buf);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_prefix: u64 = 0;

    for (entries) |entry| {
        var buffer_writer = BufferWriter{ .buf = curr_buf };
        try serializeFixed(&buffer_writer, entry.key, depth, depth_limit);
        const prefix = fixedBytesPrefix(curr_buf);
        const key_order = if (has_prev)
            fixedBytesOrderPrefixed(key_size, prev_prefix, prev_buf, prefix, curr_buf)
        else
            std.math.Order.lt;
        if (has_prev and key_order == .gt) return Error.NonCanonicalMap;
        if (!has_prev or key_order != .eq) {
            unique_count += 1;
            prev_prefix = prefix;
            std.mem.copyForwards(u8, prev_buf, curr_buf);
            has_prev = true;
        }
    }

    try uleb128WriteWriter(writer, @intCast(unique_count));
    has_prev = false;
    for (entries) |entry| {
        var buffer_writer = BufferWriter{ .buf = curr_buf };
        try serializeFixed(&buffer_writer, entry.key, depth, depth_limit);
        const prefix = fixedBytesPrefix(curr_buf);
        if (has_prev and fixedBytesOrderPrefixed(key_size, prev_prefix, prev_buf, prefix, curr_buf) == .eq) continue;

        try writer.writeAll(curr_buf);
        try serializeValueToWriter(allocator, writer, entry.value, depth, depth_limit);

        prev_prefix = prefix;
        std.mem.copyForwards(u8, prev_buf, curr_buf);
        has_prev = true;
    }
}

fn serializeCanonicalMapVariableKeysToWriter(
    comptime K: type,
    allocator: Allocator,
    writer: anytype,
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) (WriterError(@TypeOf(writer)) || Error)!void {
    _ = K;
    if (entries.len > max_sequence_length) return Error.SequenceTooLong;

    var prev_key_storage: std.ArrayList(u8) = .{};
    defer prev_key_storage.deinit(allocator);
    var curr_key_storage: std.ArrayList(u8) = .{};
    defer curr_key_storage.deinit(allocator);

    var unique_count: usize = 0;
    var has_prev = false;
    for (entries) |entry| {
        curr_key_storage.clearRetainingCapacity();
        const key_size = try serializedSizeValue(entry.key, depth, depth_limit);
        curr_key_storage.ensureTotalCapacityPrecise(allocator, key_size) catch return Error.OutOfMemory;
        var key_writer = ReservedListWriter{ .list = &curr_key_storage };
        try serializeValueToWriter(allocator, &key_writer, entry.key, depth, depth_limit);

        const key_order = if (has_prev)
            std.mem.order(u8, prev_key_storage.items, curr_key_storage.items)
        else
            std.math.Order.lt;
        if (has_prev and key_order == .gt) return Error.NonCanonicalMap;
        if (!has_prev or key_order != .eq) {
            unique_count += 1;
            has_prev = true;
            std.mem.swap(std.ArrayList(u8), &prev_key_storage, &curr_key_storage);
        }
    }

    try uleb128WriteWriter(writer, @intCast(unique_count));
    prev_key_storage.clearRetainingCapacity();
    curr_key_storage.clearRetainingCapacity();
    has_prev = false;
    for (entries) |entry| {
        curr_key_storage.clearRetainingCapacity();
        const key_size = try serializedSizeValue(entry.key, depth, depth_limit);
        curr_key_storage.ensureTotalCapacityPrecise(allocator, key_size) catch return Error.OutOfMemory;
        var key_writer = ReservedListWriter{ .list = &curr_key_storage };
        try serializeValueToWriter(allocator, &key_writer, entry.key, depth, depth_limit);
        if (has_prev and std.mem.eql(u8, prev_key_storage.items, curr_key_storage.items)) continue;

        try writer.writeAll(curr_key_storage.items);
        try serializeValueToWriter(allocator, writer, entry.value, depth, depth_limit);

        std.mem.swap(std.ArrayList(u8), &prev_key_storage, &curr_key_storage);
        has_prev = true;
    }
}

fn serializeCanonicalMapToWriter(
    comptime K: type,
    allocator: Allocator,
    writer: anytype,
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) (WriterError(@TypeOf(writer)) || Error)!void {
    const key_size = comptime serializedSizeHint(K);
    if (key_size > 0) {
        if (comptime canUseIntMapFastPath(K)) {
            return serializeCanonicalMapIntKeysToWriter(K, allocator, writer, entries, depth, depth_limit);
        }
        if (comptime canUseArrayMapFastPath(K)) {
            return serializeCanonicalMapArrayKeysToWriter(K, allocator, writer, entries, depth, depth_limit);
        }
        return serializeCanonicalMapFixedKeysToWriter(key_size, allocator, writer, entries, depth, depth_limit);
    }

    if (comptime isByteSliceMapKey(K)) {
        return serializeCanonicalMapByteSliceKeysToWriter(allocator, writer, entries, depth, depth_limit);
    }

    return serializeCanonicalMapVariableKeysToWriter(K, allocator, writer, entries, depth, depth_limit);
}

fn serializeMapToWriter(
    comptime K: type,
    allocator: Allocator,
    writer: anytype,
    entries: anytype,
    depth: u32,
    depth_limit: u32,
) (WriterError(@TypeOf(writer)) || Error)!void {
    const key_size = comptime serializedSizeHint(K);
    if (key_size > 0) {
        if (comptime canUseIntMapFastPath(K)) {
            return serializeMapIntKeysToWriter(K, allocator, writer, entries, depth, depth_limit);
        }
        if (comptime canUseArrayMapFastPath(K)) {
            return serializeMapArrayKeysToWriter(K, allocator, writer, entries, depth, depth_limit);
        }
        return serializeMapFixedKeysToWriter(key_size, allocator, writer, entries, depth, depth_limit);
    }

    if (comptime isByteSliceMapKey(K)) {
        return serializeMapByteSliceKeysToWriter(allocator, writer, entries, depth, depth_limit);
    }

    const count: u32 = @intCast(entries.len);
    if (count > max_sequence_length) return Error.SequenceTooLong;

    const SortItem = struct { start: usize, end: usize, index: usize };
    var stack_sort_items: [inline_map_scratch_entries]SortItem = undefined;
    const sort_items = if (entries.len <= inline_map_scratch_entries)
        stack_sort_items[0..entries.len]
    else
        allocator.alloc(SortItem, count) catch return Error.OutOfMemory;
    defer if (entries.len > inline_map_scratch_entries) allocator.free(sort_items);

    var total_key_bytes: usize = 0;

    for (entries) |entry| {
        total_key_bytes = try checkedSizeAdd(total_key_bytes, try serializedSizeValue(entry.key, depth, depth_limit));
    }
    var stack_key_storage: [inline_map_scratch_bytes]u8 = undefined;
    const key_storage = if (total_key_bytes <= inline_map_scratch_bytes)
        stack_key_storage[0..total_key_bytes]
    else
        allocator.alloc(u8, total_key_bytes) catch return Error.OutOfMemory;
    defer if (total_key_bytes > inline_map_scratch_bytes) allocator.free(key_storage);
    var key_writer = BufferWriter{ .buf = key_storage };

    for (entries, 0..) |entry, i| {
        const start = key_writer.pos;
        try serializeValueToWriter(allocator, &key_writer, entry.key, depth, depth_limit);
        sort_items[i] = .{
            .start = start,
            .end = key_writer.pos,
            .index = i,
        };
    }

    std.mem.sort(SortItem, sort_items, key_storage, struct {
        fn order(key_bytes: []const u8, a: SortItem, b: SortItem) bool {
            const a_key = key_bytes[a.start..a.end];
            const b_key = key_bytes[b.start..b.end];
            const key_order = std.mem.order(u8, a_key, b_key);
            if (key_order != .eq) return key_order == .lt;
            return a.index < b.index;
        }
    }.order);

    var unique_count: usize = 0;
    var has_prev = false;
    var prev_key: []const u8 = undefined;
    for (sort_items) |item| {
        const key = key_storage[item.start..item.end];
        if (!has_prev or !std.mem.eql(u8, prev_key, key)) {
            unique_count += 1;
            prev_key = key;
            has_prev = true;
        }
    }

    try uleb128WriteWriter(writer, @intCast(unique_count));
    has_prev = false;
    for (sort_items) |item| {
        const key = key_storage[item.start..item.end];
        if (has_prev and std.mem.eql(u8, prev_key, key)) continue;
        prev_key = key;
        has_prev = true;
        try writer.writeAll(key);
        try serializeValueToWriter(allocator, writer, entries[item.index].value, depth, depth_limit);
    }
}

fn serializeValueToWriter(allocator: Allocator, writer: anytype, value: anytype, depth: u32, depth_limit: u32) (WriterError(@TypeOf(writer)) || Error)!void {
    @setEvalBranchQuota(10000);
    const T = @TypeOf(value);
    if (comptime isBcsStringType(T)) {
        const bytes = bcsStringBytes(value);
        try validateUtf8(bytes);
        if (bytes.len > max_sequence_length) return Error.SequenceTooLong;
        try uleb128WriteWriter(writer, @intCast(bytes.len));
        try writer.writeAll(bytes);
        return;
    }
    const hint = comptime serializedSizeHint(T);
    if (hint > 0) {
        if (comptime @TypeOf(writer) == *BufferWriter) {
            try serializeFixed(writer, value, depth, depth_limit);
            return;
        }
        try serializeFixedToWriter(writer, value, depth, depth_limit);
        return;
    }
    const info = @typeInfo(T);

    switch (info) {
        .bool => try writerWriteByte(writer, if (value) @as(u8, 1) else @as(u8, 0)),

        .int => try writeIntLittleWriter(writer, T, value),

        .optional => {
            if (value) |v| {
                try writerWriteByte(writer, 0x01);
                try serializeValueToWriter(allocator, writer, v, depth, depth_limit);
            } else {
                try writerWriteByte(writer, 0x00);
            }
        },

        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    if (value.len > max_sequence_length) return Error.SequenceTooLong;
                    try uleb128WriteWriter(writer, @intCast(value.len));
                    if (ptr_info.child == u8) {
                        try writer.writeAll(value);
                    } else if (comptime canBulkCopy(ptr_info.child)) {
                        try writer.writeAll(std.mem.sliceAsBytes(value));
                    } else {
                        for (value) |elem| {
                            try serializeValueToWriter(allocator, writer, elem, depth, depth_limit);
                        }
                    }
                },
                .one => try serializeValueToWriter(allocator, writer, value.*, depth, depth_limit),
                else => @compileError("BCS: unsupported pointer type " ++ @typeName(T)),
            }
        },

        .array => |arr_info| {
            if (arr_info.child == u8) {
                try writer.writeAll(&value);
            } else if (comptime canBulkCopy(arr_info.child)) {
                try writer.writeAll(std.mem.asBytes(&value));
            } else {
                for (value) |elem| {
                    try serializeValueToWriter(allocator, writer, elem, depth, depth_limit);
                }
            }
        },

        .@"struct" => |struct_info| {
            if (@hasDecl(T, "bcs_map") and T.bcs_map) {
                if (comptime isCanonicalMapType(T)) {
                    try serializeCanonicalMapToWriter(T.Key, allocator, writer, value.entries, depth, depth_limit);
                } else {
                    try serializeMapToWriter(T.Key, allocator, writer, value.entries, depth, depth_limit);
                }
            } else if (struct_info.is_tuple) {
                inline for (struct_info.fields) |field| {
                    try serializeValueToWriter(allocator, writer, @field(value, field.name), depth, depth_limit);
                }
            } else {
                const new_depth = depth + 1;
                if (new_depth > depth_limit) return Error.ContainerTooDeep;
                inline for (struct_info.fields) |field| {
                    try serializeValueToWriter(allocator, writer, @field(value, field.name), new_depth, depth_limit);
                }
            }
        },

        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("BCS: untagged unions not supported — use a tagged union");
            }
            const new_depth = depth + 1;
            if (new_depth > depth_limit) return Error.ContainerTooDeep;

            const tag = std.meta.activeTag(value);
            const index = enumVariantIndex(std.meta.Tag(T), tag);
            try uleb128WriteWriter(writer, index);

            inline for (union_info.fields) |field| {
                if (comptime std.meta.stringToEnum(std.meta.Tag(T), field.name)) |this_tag| {
                    if (tag == this_tag) {
                        if (field.type != void) {
                            try serializeValueToWriter(allocator, writer, @field(value, field.name), new_depth, depth_limit);
                        }
                        return;
                    }
                }
            }
        },

        .@"enum" => try uleb128WriteWriter(writer, enumVariantIndex(T, value)),

        .void => {},

        else => @compileError("BCS: unsupported type " ++ @typeName(T)),
    }
}

// ── Deserialize ────────────────────────────────────────────────────────

fn deserializeFixed(comptime T: type, reader: *Reader, depth: u32, depth_limit: u32) Error!T {
    @setEvalBranchQuota(10000);
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

        .array => |arr_info| {
            if (arr_info.child == u8) {
                const bytes = try reader.readBytes(arr_info.len);
                return bytes[0..arr_info.len].*;
            }
            if (comptime canBulkCopy(arr_info.child)) {
                const byte_count = arr_info.len * @sizeOf(arr_info.child);
                const bytes = try reader.readBytes(byte_count);
                var result: T = undefined;
                @memcpy(std.mem.asBytes(&result), bytes);
                return result;
            }

            var result: T = undefined;
            for (&result) |*elem| {
                elem.* = try deserializeFixed(arr_info.child, reader, depth, depth_limit);
            }
            return result;
        },

        .@"struct" => |struct_info| {
            var result: T = undefined;

            if (struct_info.is_tuple) {
                inline for (struct_info.fields) |field| {
                    @field(result, field.name) = try deserializeFixed(field.type, reader, depth, depth_limit);
                }
                return result;
            }

            const new_depth = depth + 1;
            if (new_depth > depth_limit) return Error.ContainerTooDeep;
            inline for (struct_info.fields) |field| {
                @field(result, field.name) = try deserializeFixed(field.type, reader, new_depth, depth_limit);
            }
            return result;
        },

        else => unreachable,
    }
}

fn deserializeValue(comptime T: type, allocator: Allocator, reader: *Reader, depth: u32, depth_limit: u32) Error!T {
    @setEvalBranchQuota(10000);
    if (comptime isBcsStringType(T)) {
        const len = try uleb128Read(reader);
        if (len > max_sequence_length) return Error.SequenceTooLong;
        const bytes = try reader.readBytes(len);
        try validateUtf8(bytes);
        const owned = allocator.dupe(u8, bytes) catch return Error.OutOfMemory;
        return initBcsString(T, owned);
    }
    if (comptime serializedSizeHint(T) > 0) {
        return deserializeFixed(T, reader, depth, depth_limit);
    }
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
                0x01 => try deserializeValue(opt_info.child, allocator, reader, depth, depth_limit),
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
                    } else if (comptime canBulkCopy(ptr_info.child)) {
                        const byte_count = @as(usize, len) * @sizeOf(ptr_info.child);
                        const bytes = try reader.readBytes(byte_count);
                        const slice = allocator.alloc(ptr_info.child, len) catch return Error.OutOfMemory;
                        @memcpy(std.mem.sliceAsBytes(slice), bytes);
                        return slice;
                    } else {
                        const slice = allocator.alloc(ptr_info.child, len) catch return Error.OutOfMemory;
                        for (slice) |*elem| {
                            elem.* = try deserializeValue(ptr_info.child, allocator, reader, depth, depth_limit);
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
            } else if (comptime canBulkCopy(arr_info.child)) {
                const byte_count = arr_info.len * @sizeOf(arr_info.child);
                const bytes = try reader.readBytes(byte_count);
                var result: T = undefined;
                @memcpy(std.mem.asBytes(&result), bytes);
                return result;
            } else {
                var result: T = undefined;
                for (&result) |*elem| {
                    elem.* = try deserializeValue(arr_info.child, allocator, reader, depth, depth_limit);
                }
                return result;
            }
        },

        .@"struct" => |struct_info| {
            if (@hasDecl(T, "bcs_map") and T.bcs_map) {
                return deserializeMap(T, allocator, reader, depth, depth_limit);
            } else if (struct_info.is_tuple) {
                var result: T = undefined;
                inline for (struct_info.fields) |field| {
                    @field(result, field.name) = try deserializeValue(field.type, allocator, reader, depth, depth_limit);
                }
                return result;
            } else {
                const new_depth = depth + 1;
                if (new_depth > depth_limit) return Error.ContainerTooDeep;
                var result: T = undefined;
                inline for (struct_info.fields) |field| {
                    @field(result, field.name) = try deserializeValue(field.type, allocator, reader, new_depth, depth_limit);
                }
                return result;
            }
        },

        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("BCS: untagged unions not supported");
            }
            const new_depth = depth + 1;
            if (new_depth > depth_limit) return Error.ContainerTooDeep;

            const index = try uleb128Read(reader);

            inline for (union_info.fields, 0..) |field, i| {
                if (index == i) {
                    if (field.type == void) {
                        return @unionInit(T, field.name, {});
                    } else {
                        const val = try deserializeValue(field.type, allocator, reader, new_depth, depth_limit);
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

fn DeepStruct(comptime depth: usize) type {
    return if (depth == 0) struct {
        leaf: u8,
    } else struct {
        child: DeepStruct(depth - 1),
    };
}

fn deepStructValue(comptime depth: usize) DeepStruct(depth) {
    return if (depth == 0) .{ .leaf = 7 } else .{ .child = deepStructValue(depth - 1) };
}

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
    const bytes = try serialize(t_alloc, String.init("diem"));
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 4, 'd', 'i', 'e', 'm' }, bytes);
}

test "empty string" {
    const bytes = try serialize(t_alloc, String.init(""));
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{0}, bytes);
}

test "string round-trip" {
    const original = String.init("hello world");
    const bytes = try serialize(t_alloc, original);
    defer t_alloc.free(bytes);
    const decoded = try deserialize(String, t_alloc, bytes);
    defer freeDeserialized(String, t_alloc, decoded);
    try testing.expectEqualStrings(original.bytes, decoded.bytes);
}

test "string serialization rejects invalid utf8" {
    try testing.expectError(Error.Utf8, serialize(t_alloc, String.init(&.{ 0xc0, 0x80 })));
}

test "string deserialization rejects invalid utf8" {
    try testing.expectError(Error.Utf8, deserialize(String, t_alloc, &.{ 0x02, 0xc0, 0x80 }));
}

test "raw byte slices allow invalid utf8" {
    const original: []const u8 = &.{ 0xc0, 0x80 };
    const bytes = try serialize(t_alloc, original);
    defer t_alloc.free(bytes);
    const decoded = try deserialize([]const u8, t_alloc, bytes);
    defer t_alloc.free(decoded);
    try testing.expectEqualSlices(u8, original, decoded);
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
        0x02,
        0x00,
        0x03,
        0x00,
        0x00,
        0x00,
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
    const Event = struct { sender: [32]u8, name: String, amount: u64 };
    var addr: [32]u8 = .{0} ** 32;
    addr[0] = 0x01;
    const val = Event{ .sender = addr, .name = String.init("test"), .amount = 1000 };

    const bytes = try serialize(t_alloc, val);
    defer t_alloc.free(bytes);

    const decoded = try deserialize(Event, t_alloc, bytes);
    defer freeDeserialized(Event, t_alloc, decoded);
    try testing.expectEqual(val.sender, decoded.sender);
    try testing.expectEqualStrings(val.name.bytes, decoded.name.bytes);
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

test "enum with explicit values uses declaration order" {
    const Color = enum(u16) { red = 10, green = 100, blue = 999 };
    const bytes = try serialize(t_alloc, Color.blue);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{0x02}, bytes);
    try testing.expectEqual(Color.blue, try deserialize(Color, t_alloc, bytes));
}

test "tagged union with explicit tag values uses declaration order" {
    const Tag = enum(u8) { a = 10, b = 42, c = 255 };
    const Payload = union(Tag) {
        a: void,
        b: u16,
        c: []const u8,
    };

    const value = Payload{ .c = "zig" };
    const bytes = try serialize(t_alloc, value);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x03, 'z', 'i', 'g' }, bytes);

    const decoded = try deserialize(Payload, t_alloc, bytes);
    defer freeDeserialized(Payload, t_alloc, decoded);
    try testing.expectEqual(Tag.c, std.meta.activeTag(decoded));
    try testing.expectEqualStrings(value.c, decoded.c);
}

// ── Tuples ─────────────────────────────────────────────────────────────

test "tuple serialization" {
    const val: struct { i8, String } = .{ -1, String.init("diem") };
    const bytes = try serialize(t_alloc, val);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x04, 'd', 'i', 'e', 'm' }, bytes);
}

test "fixed-size tuple uses zero-allocation path" {
    const T = struct { u16, u32 };
    const val: T = .{ 0x0102, 0x03040506 };
    var buf: [serializedSizeHint(T)]u8 = undefined;
    const n = try serializeInto(&buf, val);
    try testing.expectEqual(@as(usize, 6), n);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x06, 0x05, 0x04, 0x03 }, buf[0..n]);
}

test "serializeAppend appends bytes to existing list" {
    var list: std.ArrayList(u8) = .{};
    defer list.deinit(t_alloc);

    try list.append(t_alloc, 0xaa);
    try serializeAppend(t_alloc, &list, @as(u16, 0x0102));
    try serializeAppend(t_alloc, &list, @as([]const u8, "ok"));

    try testing.expectEqualSlices(u8, &.{ 0xaa, 0x02, 0x01, 0x02, 'o', 'k' }, list.items);
}

test "serializeWriter matches serialize for variable-size struct" {
    const Event = struct {
        sender: [32]u8,
        name: String,
        amount: u64,
    };

    const value = Event{
        .sender = .{0x11} ** 32,
        .name = String.init("stream"),
        .amount = 1234,
    };

    const expected = try serialize(t_alloc, value);
    defer t_alloc.free(expected);

    var list: std.ArrayList(u8) = .{};
    defer list.deinit(t_alloc);
    const writer = list.writer(t_alloc);
    try serializeWriter(t_alloc, writer, value);

    try testing.expectEqualSlices(u8, expected, list.items);
}

test "serializeWriter matches serialize for map with string keys" {
    const M = Map(String, u64);
    const value = M{ .entries = &.{
        .{ .key = String.init("zeta"), .value = 6 },
        .{ .key = String.init("alpha"), .value = 1 },
        .{ .key = String.init("beta"), .value = 2 },
    } };

    const expected = try serialize(t_alloc, value);
    defer t_alloc.free(expected);

    var list: std.ArrayList(u8) = .{};
    defer list.deinit(t_alloc);
    const writer = list.writer(t_alloc);
    try serializeWriter(t_alloc, writer, value);

    try testing.expectEqualSlices(u8, expected, list.items);
}

test "serializeWriter matches serialize for duplicate map keys" {
    const M = Map([]const u8, u64);
    const value = M{ .entries = &.{
        .{ .key = "beta", .value = 2 },
        .{ .key = "alpha", .value = 1 },
        .{ .key = "alpha", .value = 9 },
    } };

    const expected = try serialize(t_alloc, value);
    defer t_alloc.free(expected);

    var list: std.ArrayList(u8) = .{};
    defer list.deinit(t_alloc);
    const writer = list.writer(t_alloc);
    try serializeWriter(t_alloc, writer, value);

    try testing.expectEqualSlices(u8, expected, list.items);
}

test "serializedSize matches serialize length for variable-size values" {
    const Inner = struct {
        tag: []const u8,
        nums: []const u32,
    };
    const Outer = struct {
        id: u64,
        opt: ?Inner,
        names: []const []const u8,
    };

    const value = Outer{
        .id = 9,
        .opt = .{
            .tag = "abc",
            .nums = &.{ 10, 20, 30 },
        },
        .names = &.{ "alpha", "beta", "gamma" },
    };

    const bytes = try serialize(t_alloc, value);
    defer t_alloc.free(bytes);

    try testing.expectEqual(bytes.len, try serializedSize(value));
}

test "serializedSize matches deduplicated map serialization length" {
    const M = Map([]const u8, u64);
    const value = M{ .entries = &.{
        .{ .key = "beta", .value = 2 },
        .{ .key = "alpha", .value = 1 },
        .{ .key = "alpha", .value = 9 },
    } };

    const bytes = try serialize(t_alloc, value);
    defer t_alloc.free(bytes);

    try testing.expectEqual(bytes.len, try serializedSize(value));
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

test "fixed-size fast path enforces container depth" {
    const depth = @as(usize, max_container_depth) + 1;
    const T = DeepStruct(depth);
    const value = deepStructValue(depth);
    var buf: [serializedSizeHint(T)]u8 = undefined;
    try testing.expectError(Error.ContainerTooDeep, serializeInto(&buf, value));
    try testing.expectError(Error.ContainerTooDeep, serialize(t_alloc, value));
    try testing.expectError(Error.ContainerTooDeep, serializedSize(value));
}

test "limit-aware APIs reject limits above max" {
    const invalid_limit = @as(usize, max_container_depth) + 1;
    var buf: [1]u8 = undefined;
    var append_list: std.ArrayList(u8) = .{};
    defer append_list.deinit(t_alloc);
    var writer_list: std.ArrayList(u8) = .{};
    defer writer_list.deinit(t_alloc);

    try testing.expectError(Error.NotSupported, serializeIntoWithLimit(&buf, @as(u8, 7), invalid_limit));
    try testing.expectError(Error.NotSupported, serializedSizeWithLimit(@as(u8, 7), invalid_limit));
    try testing.expectError(Error.NotSupported, serializeWithLimit(t_alloc, @as(u8, 7), invalid_limit));
    try testing.expectError(Error.NotSupported, serializeAppendWithLimit(t_alloc, &append_list, @as(u8, 7), invalid_limit));
    try testing.expectError(Error.NotSupported, serializeWriterWithLimit(t_alloc, writer_list.writer(t_alloc), @as(u8, 7), invalid_limit));
    try testing.expectError(Error.NotSupported, deserializeWithLimit(u8, t_alloc, &.{7}, invalid_limit));
    try testing.expectError(Error.NotSupported, deserializePartialWithLimit(u8, t_alloc, &.{7}, invalid_limit));
}

test "custom container depth limits apply consistently" {
    const depth = 8;
    const limit_fail = depth;
    const limit_ok = depth + 1;
    const T = DeepStruct(depth);
    const value = deepStructValue(depth);
    var buf: [serializedSizeHint(T)]u8 = undefined;

    try testing.expectError(Error.ContainerTooDeep, serializeIntoWithLimit(&buf, value, limit_fail));
    try testing.expectError(Error.ContainerTooDeep, serializedSizeWithLimit(value, limit_fail));
    try testing.expectError(Error.ContainerTooDeep, serializeWithLimit(t_alloc, value, limit_fail));

    const bytes = try serializeWithLimit(t_alloc, value, limit_ok);
    defer t_alloc.free(bytes);
    try testing.expectEqual(bytes.len, try serializedSizeWithLimit(value, limit_ok));

    var append_list: std.ArrayList(u8) = .{};
    defer append_list.deinit(t_alloc);
    try serializeAppendWithLimit(t_alloc, &append_list, value, limit_ok);
    try testing.expectEqualSlices(u8, bytes, append_list.items);

    var writer_list: std.ArrayList(u8) = .{};
    defer writer_list.deinit(t_alloc);
    try serializeWriterWithLimit(t_alloc, writer_list.writer(t_alloc), value, limit_ok);
    try testing.expectEqualSlices(u8, bytes, writer_list.items);

    try testing.expectError(Error.ContainerTooDeep, deserializeWithLimit(T, t_alloc, bytes, limit_fail));
    try testing.expectError(Error.ContainerTooDeep, deserializePartialWithLimit(T, t_alloc, bytes, limit_fail));

    try testing.expectEqual(value, try deserializeWithLimit(T, t_alloc, bytes, limit_ok));
    const partial = try deserializePartialWithLimit(T, t_alloc, bytes, limit_ok);
    try testing.expectEqual(value, partial.value);
    try testing.expectEqual(bytes.len, partial.bytes_read);
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

test "deserializeReader matches slice deserialize" {
    const ReaderStruct = struct {
        id: u64,
        name: String,
        tags: []const String,
    };
    const value = ReaderStruct{
        .id = 7,
        .name = String.init("reader"),
        .tags = &.{ String.init("alpha"), String.init("beta") },
    };
    const bytes = try serialize(t_alloc, value);
    defer t_alloc.free(bytes);

    var stream = std.io.fixedBufferStream(bytes);
    const decoded = try deserializeReader(ReaderStruct, t_alloc, stream.reader());
    defer freeDeserialized(ReaderStruct, t_alloc, decoded);

    try testing.expectEqual(value.id, decoded.id);
    try testing.expect(value.name.eql(decoded.name));
    try testing.expectEqual(@as(usize, 2), decoded.tags.len);
    try testing.expect(decoded.tags[0].eql(String.init("alpha")));
    try testing.expect(decoded.tags[1].eql(String.init("beta")));
}

test "deserializeReader rejects trailing bytes" {
    var stream = std.io.fixedBufferStream(&[_]u8{ 0x01, 0x02 });
    try testing.expectError(Error.TrailingBytes, deserializeReader(u8, t_alloc, stream.reader()));
}

test "deserializeReaderWithLimit enforces container depth" {
    const T = struct {
        inner: struct {
            name: String,
        },
    };
    const value = T{ .inner = .{ .name = String.init("x") } };
    const bytes = try serialize(t_alloc, value);
    defer t_alloc.free(bytes);

    var ok_stream = std.io.fixedBufferStream(bytes);
    const ok = try deserializeReaderWithLimit(T, t_alloc, ok_stream.reader(), 2);
    defer freeDeserialized(T, t_alloc, ok);
    try testing.expect(ok.inner.name.eql(String.init("x")));

    var fail_stream = std.io.fixedBufferStream(bytes);
    try testing.expectError(Error.ContainerTooDeep, deserializeReaderWithLimit(T, t_alloc, fail_stream.reader(), 1));
}

test "deserializeReader propagates reader errors" {
    const BrokenReader = struct {
        fail_after: usize,
        count: usize = 0,

        fn readByte(self: *@This()) error{ EndOfStream, Boom }!u8 {
            if (self.count >= self.fail_after) return error.Boom;
            self.count += 1;
            return 0x01;
        }
    };

    var reader = BrokenReader{ .fail_after = 0 };
    try testing.expectError(error.Boom, deserializeReader(u8, t_alloc, &reader));
}

test "deserializeSeed transforms values" {
    const MultiplySeed = struct {
        factor: u64,
        pub const Value = u64;

        pub fn deserialize(self: @This(), de: *SeedDeserializer) Error!u64 {
            return (try de.deserialize(u64)) * self.factor;
        }
    };

    const bytes = try serialize(t_alloc, @as(u64, 42));
    defer t_alloc.free(bytes);

    try testing.expectEqual(@as(u64, 126), try deserializeSeed(MultiplySeed{ .factor = 3 }, t_alloc, bytes));
}

test "deserializeReaderSeed matches reader seed path" {
    const PrefixSeed = struct {
        prefix: []const u8,
        pub const Value = struct { text: []const u8 };

        pub fn deserialize(self: @This(), de: *SeedDeserializer) Error!Value {
            const input = try de.deserialize(String);
            errdefer freeDeserialized(String, de.allocator, input);

            const out = try de.allocator.alloc(u8, self.prefix.len + input.bytes.len);
            @memcpy(out[0..self.prefix.len], self.prefix);
            @memcpy(out[self.prefix.len..], input.bytes);
            freeDeserialized(String, de.allocator, input);
            return .{ .text = out };
        }

        pub fn free(_: @This(), allocator: Allocator, value: Value) void {
            allocator.free(value.text);
        }
    };

    const bytes = try serialize(t_alloc, String.init("coin"));
    defer t_alloc.free(bytes);

    var stream = std.io.fixedBufferStream(bytes);
    const value = try deserializeReaderSeed(PrefixSeed{ .prefix = "mod:" }, t_alloc, stream.reader());
    defer t_alloc.free(value.text);
    try testing.expectEqualStrings("mod:coin", value.text);
}

test "deserializeSeedWithLimit enforces limits for seeds" {
    const Raw = struct {
        inner: struct {
            name: String,
        },
    };
    const PassThroughSeed = struct {
        pub const Value = Raw;

        pub fn deserialize(_: @This(), de: *SeedDeserializer) Error!Raw {
            return de.deserialize(Raw);
        }
    };

    const bytes = try serialize(t_alloc, Raw{ .inner = .{ .name = String.init("x") } });
    defer t_alloc.free(bytes);

    const ok = try deserializeSeedWithLimit(PassThroughSeed{}, t_alloc, bytes, 2);
    defer freeDeserialized(Raw, t_alloc, ok);
    try testing.expect(ok.inner.name.eql(String.init("x")));

    try testing.expectError(Error.ContainerTooDeep, deserializeSeedWithLimit(PassThroughSeed{}, t_alloc, bytes, 1));
}

test "deserializeSeed uses custom free hook on trailing bytes" {
    var freed = false;
    const TrackSeed = struct {
        freed: *bool,
        pub const Value = struct { bytes: []const u8 };

        pub fn deserialize(_: @This(), de: *SeedDeserializer) Error!Value {
            return .{ .bytes = try de.deserialize([]const u8) };
        }

        pub fn free(self: @This(), allocator: Allocator, value: Value) void {
            self.freed.* = true;
            allocator.free(value.bytes);
        }
    };

    const bytes = &[_]u8{ 0x01, 'a', 0xff };
    try testing.expectError(Error.TrailingBytes, deserializeSeed(TrackSeed{ .freed = &freed }, t_alloc, bytes));
    try testing.expect(freed);
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
    const ZeroCopyFoo = struct { borrowed_str: String, borrowed_bytes: []const u8 };
    const f = ZeroCopyFoo{ .borrowed_str = String.init("hi"), .borrowed_bytes = &.{ 0, 1, 2, 3 } };

    const expected = &[_]u8{ 2, 'h', 'i', 4, 0, 1, 2, 3 };
    const encoded = try serialize(t_alloc, f);
    defer t_alloc.free(encoded);
    try testing.expectEqualSlices(u8, expected, encoded);

    const out = try deserialize(ZeroCopyFoo, t_alloc, encoded);
    defer freeDeserialized(ZeroCopyFoo, t_alloc, out);
    try testing.expectEqualStrings(f.borrowed_str.bytes, out.borrowed_str.bytes);
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
    seq: []const String,
    boolean: bool,
};

test "rust parity: struct S round-trip" {
    const original = S{
        .int = 1000,
        .option = 42,
        .seq = &.{ String.init("hello"), String.init("world") },
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
    defer freeDeserialized(S, t_alloc, decoded);
    try testing.expectEqual(original.int, decoded.int);
    try testing.expectEqual(original.option, decoded.option);
    try testing.expectEqual(original.boolean, decoded.boolean);
    try testing.expectEqual(original.seq.len, decoded.seq.len);
    for (original.seq, decoded.seq) |orig, dec| {
        try testing.expectEqualStrings(orig.bytes, dec.bytes);
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
    defer freeDeserialized(S, t_alloc, decoded);
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

test "map serialization — duplicate fixed-size keys keep first value" {
    const M = Map(u8, u16);
    const map = M{ .entries = &.{
        .{ .key = 5, .value = 100 },
        .{ .key = 5, .value = 999 },
    } };
    const bytes = try serialize(t_alloc, map);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 1, 5, 100, 0 }, bytes);
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
    const M = Map(String, []const u8);
    const map = M{ .entries = &.{
        .{ .key = String.init("b"), .value = "2" },
        .{ .key = String.init("a"), .value = "1" },
        .{ .key = String.init("c"), .value = "3" },
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

test "map with invalid utf8 string key rejected on serialize" {
    const M = Map(String, u8);
    const map = M{ .entries = &.{
        .{ .key = String.init(&.{0xff}), .value = 1 },
    } };

    try testing.expectError(Error.Utf8, serialize(t_alloc, map));
}

test "map with invalid utf8 string key rejected on deserialize" {
    const M = Map(String, u8);
    try testing.expectError(Error.Utf8, deserialize(M, t_alloc, &.{ 1, 1, 0xff, 1 }));
}

test "map serialization — duplicate variable-size keys keep first value" {
    const M = Map(String, u8);
    const map = M{ .entries = &.{
        .{ .key = String.init("dup"), .value = 1 },
        .{ .key = String.init("dup"), .value = 2 },
    } };
    const bytes = try serialize(t_alloc, map);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 1, 3, 'd', 'u', 'p', 1 }, bytes);
}

test "map serialization — duplicate array keys keep first value" {
    const M = Map([32]u8, u8);
    const key: [32]u8 = .{0xaa} ** 32;
    const map = M{ .entries = &.{
        .{ .key = key, .value = 1 },
        .{ .key = key, .value = 2 },
    } };
    const bytes = try serialize(t_alloc, map);
    defer t_alloc.free(bytes);
    try testing.expectEqual(@as(usize, 34), bytes.len);
    try testing.expectEqual(@as(u8, 1), bytes[0]);
    try testing.expectEqualSlices(u8, &key, bytes[1..33]);
    try testing.expectEqual(@as(u8, 1), bytes[33]);
}

test "canonical map serialization — sorted input passes without reordering" {
    const M = CanonicalMap(u8, void);
    const map = M{ .entries = &.{
        .{ .key = 4, .value = {} },
        .{ .key = 5, .value = {} },
    } };

    const bytes = try serialize(t_alloc, map);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 2, 4, 5 }, bytes);
}

test "canonical map serialization — unsorted input rejected" {
    const M = CanonicalMap(u8, void);
    const map = M{ .entries = &.{
        .{ .key = 5, .value = {} },
        .{ .key = 4, .value = {} },
    } };

    try testing.expectError(Error.NonCanonicalMap, serialize(t_alloc, map));
}

test "canonical map serialization — duplicate keys keep first value" {
    const M = CanonicalMap(String, u8);
    const map = M{ .entries = &.{
        .{ .key = String.init("dup"), .value = 1 },
        .{ .key = String.init("dup"), .value = 2 },
    } };

    const bytes = try serialize(t_alloc, map);
    defer t_alloc.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 1, 3, 'd', 'u', 'p', 1 }, bytes);
}

test "canonical map deserializes as canonical map type" {
    const M = CanonicalMap(String, u64);
    const bytes = &.{
        3,
        1,
        'a',
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        'b',
        2,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        'c',
        3,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    };

    const decoded = try deserialize(M, t_alloc, bytes);
    defer freeDeserialized(M, t_alloc, decoded);

    try testing.expectEqual(@as(usize, 3), decoded.entries.len);
    try testing.expectEqualStrings("a", decoded.entries[0].key.bytes);
    try testing.expectEqual(@as(u64, 1), decoded.entries[0].value);
    try testing.expectEqualStrings("b", decoded.entries[1].key.bytes);
    try testing.expectEqual(@as(u64, 2), decoded.entries[1].value);
    try testing.expectEqualStrings("c", decoded.entries[2].key.bytes);
    try testing.expectEqual(@as(u64, 3), decoded.entries[2].value);
}

test "map with address keys round-trip" {
    const M = Map([32]u8, u64);

    var a: [32]u8 = .{0} ** 32;
    a[0] = 0x10;
    a[31] = 0xaa;

    var b: [32]u8 = .{0} ** 32;
    b[0] = 0x22;
    b[31] = 0xbb;

    var c: [32]u8 = .{0} ** 32;
    c[0] = 0x33;
    c[31] = 0xcc;

    const map = M{ .entries = &.{
        .{ .key = c, .value = 3 },
        .{ .key = a, .value = 1 },
        .{ .key = b, .value = 2 },
    } };

    const bytes = try serialize(t_alloc, map);
    defer t_alloc.free(bytes);

    const decoded = try deserialize(M, t_alloc, bytes);
    defer t_alloc.free(decoded.entries);

    try testing.expectEqual(@as(usize, 3), decoded.entries.len);
    try testing.expectEqual(a, decoded.entries[0].key);
    try testing.expectEqual(@as(u64, 1), decoded.entries[0].value);
    try testing.expectEqual(b, decoded.entries[1].key);
    try testing.expectEqual(@as(u64, 2), decoded.entries[1].value);
    try testing.expectEqual(c, decoded.entries[2].key);
    try testing.expectEqual(@as(u64, 3), decoded.entries[2].value);
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
        0x01,
        0x01,
        0x03,
        0x16,
        0x15,
        0x43,
        // key=[0,56,21] (BCS: 0x03,0x00,0x38,0x15) → val=[22,10,5]
        0x03,
        0x00,
        0x38,
        0x15,
        0x03,
        0x16,
        0x0a,
        0x05,
        // key=[20,21,89,105] (BCS: 0x04,0x14,0x15,0x59,0x69) → val=[201,23,90]
        0x04,
        0x14,
        0x15,
        0x59,
        0x69,
        0x03,
        0xc9,
        0x17,
        0x5a,
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

// ── Bulk copy verification ────────────────────────────────────────────
// Serialize via per-element path (forced) and compare against bulk path output.
// Catches any divergence between canBulkCopy fast path and canonical encoding.

fn serializePerElement(allocator: Allocator, comptime T: type, values: []const T) Error![]u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);
    try uleb128Append(allocator, &list, @intCast(values.len));
    for (values) |v| try writeIntLittle(allocator, &list, T, v);
    return list.toOwnedSlice(allocator) catch Error.OutOfMemory;
}

test "bulk copy produces identical bytes to per-element serialization" {

    // u16
    {
        const data = [_]u16{ 0, 1, 0x0102, 0xFFFF, 0xABCD, 42 };
        const bulk = try serialize(t_alloc, @as([]const u16, &data));
        defer t_alloc.free(bulk);
        const elem = try serializePerElement(t_alloc, u16, &data);
        defer t_alloc.free(elem);
        try testing.expectEqualSlices(u8, elem, bulk);
    }

    // u32
    {
        const data = [_]u32{ 0, 1, 0x12345678, 0xFFFFFFFF, 0xDEADBEEF };
        const bulk = try serialize(t_alloc, @as([]const u32, &data));
        defer t_alloc.free(bulk);
        const elem = try serializePerElement(t_alloc, u32, &data);
        defer t_alloc.free(elem);
        try testing.expectEqualSlices(u8, elem, bulk);
    }

    // u64
    {
        const data = [_]u64{ 0, 1, 0xDEADBEEFCAFEBABE, std.math.maxInt(u64) };
        const bulk = try serialize(t_alloc, @as([]const u64, &data));
        defer t_alloc.free(bulk);
        const elem = try serializePerElement(t_alloc, u64, &data);
        defer t_alloc.free(elem);
        try testing.expectEqualSlices(u8, elem, bulk);
    }

    // u128
    {
        const data = [_]u128{ 0, 1, std.math.maxInt(u128) };
        const bulk = try serialize(t_alloc, @as([]const u128, &data));
        defer t_alloc.free(bulk);
        const elem = try serializePerElement(t_alloc, u128, &data);
        defer t_alloc.free(elem);
        try testing.expectEqualSlices(u8, elem, bulk);
    }

    // i32 (signed — two's complement LE)
    {
        const data = [_]i32{ 0, -1, 1, std.math.minInt(i32), std.math.maxInt(i32) };
        const bulk = try serialize(t_alloc, @as([]const i32, &data));
        defer t_alloc.free(bulk);
        const elem = try serializePerElement(t_alloc, i32, &data);
        defer t_alloc.free(elem);
        try testing.expectEqualSlices(u8, elem, bulk);
    }

    // Roundtrip: serialize bulk, deserialize, compare values
    {
        const original = [_]u32{ 100, 200, 300, 400, 500 };
        const bytes = try serialize(t_alloc, @as([]const u32, &original));
        defer t_alloc.free(bytes);
        const decoded = try deserialize([]const u32, t_alloc, bytes);
        defer t_alloc.free(decoded);
        try testing.expectEqualSlices(u32, &original, decoded);
    }
}
