// Zig BCS benchmark — WASM library
// Equivalent to bench/lib.rs
//
// Build: zig build-lib -OReleaseSmall --dep bcs -Mroot=bench/lib.zig -Mbcs=src/bcs.zig -target wasm32-freestanding
// Note: Zig targets wasm32-freestanding (no OS) because the library has no
// std dependency. This is a genuine advantage — no WASI overhead.
const bcs = @import("bcs");
const std = @import("std");

const TestStruct = struct {
    a: u64,
    b: bool,
    c: [32]u8,
};

var buf: [256]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buf);

export fn bcs_roundtrip() u64 {
    fba.reset();
    const allocator = fba.allocator();

    const val = TestStruct{ .a = 42, .b = true, .c = .{0xab} ** 32 };

    // Serialize
    const bytes = bcs.serialize(allocator, val) catch return 0;

    // Deserialize
    const decoded = bcs.deserialize(TestStruct, allocator, bytes) catch return 0;
    return decoded.a;
}
