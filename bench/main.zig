// Zig BCS benchmark — native binary
// Equivalent to bench/main.rs
//
// Build: zig build-exe -OReleaseSmall --dep bcs -Mroot=bench/main.zig -Mbcs=src/bcs.zig
const bcs = @import("bcs");
const std = @import("std");

const TestStruct = struct {
    a: u64,
    b: bool,
    c: [32]u8,
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    const val = TestStruct{ .a = 42, .b = true, .c = .{0xab} ** 32 };

    // Serialize
    const bytes = try bcs.serialize(allocator, val);
    defer allocator.free(bytes);

    // Deserialize
    const decoded = try bcs.deserialize(TestStruct, allocator, bytes);
    std.debug.assert(decoded.a == val.a);
    std.debug.assert(decoded.b == val.b);
    std.debug.assert(std.mem.eql(u8, &decoded.c, &val.c));
}
