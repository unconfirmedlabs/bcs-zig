const bcs = @import("bcs");
const std = @import("std");

const D0 = struct { leaf: u8 };
const D1 = struct { child: D0 };
const D2 = struct { child: D1 };
const D3 = struct { child: D2 };
const D4 = struct { child: D3 };
const D5 = struct { child: D4 };
const D6 = struct { child: D5 };
const D7 = struct { child: D6 };
const D8 = struct { child: D7 };

fn deepValue() D8 {
    return .{
        .child = .{
            .child = .{
                .child = .{
                    .child = .{
                        .child = .{
                            .child = .{
                                .child = .{
                                    .child = .{ .leaf = 7 },
                                },
                            },
                        },
                    },
                },
            },
        },
    };
}

fn errName(err: bcs.Error) []const u8 {
    return switch (err) {
        error.ContainerTooDeep => "container_too_deep",
        error.NotSupported => "not_supported",
        else => "other",
    };
}

fn emitBytesResult(name: []const u8, result: bcs.Error![]u8, allocator: std.mem.Allocator) void {
    if (result) |bytes| {
        defer allocator.free(bytes);
        std.debug.print("{s}=ok:", .{name});
        for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
        std.debug.print("\n", .{});
    } else |err| {
        std.debug.print("{s}=err:{s}\n", .{ name, errName(err) });
    }
}

fn emitSizeResult(name: []const u8, result: bcs.Error!usize) void {
    if (result) |size| {
        std.debug.print("{s}=ok:{}\n", .{ name, size });
    } else |err| {
        std.debug.print("{s}=err:{s}\n", .{ name, errName(err) });
    }
}

fn emitUnitResult(name: []const u8, result: anytype) void {
    if (result) |_| {
        std.debug.print("{s}=ok\n", .{name});
    } else |err| {
        std.debug.print("{s}=err:{s}\n", .{ name, errName(err) });
    }
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const value = deepValue();
    const limit_fail: usize = 8;
    const limit_ok: usize = 9;
    const bytes = try bcs.serializeWithLimit(allocator, value, limit_ok);
    defer allocator.free(bytes);

    emitBytesResult("to_bytes_with_limit_fail", bcs.serializeWithLimit(allocator, value, limit_fail), allocator);
    emitBytesResult("to_bytes_with_limit_ok", allocator.dupe(u8, bytes), allocator);
    emitBytesResult(
        "to_bytes_with_limit_above_max",
        bcs.serializeWithLimit(allocator, value, @as(usize, bcs.max_container_depth) + 1),
        allocator,
    );

    emitSizeResult("serialized_size_with_limit_fail", bcs.serializedSizeWithLimit(value, limit_fail));
    emitSizeResult("serialized_size_with_limit_ok", bcs.serializedSizeWithLimit(value, limit_ok));
    emitSizeResult(
        "serialized_size_with_limit_above_max",
        bcs.serializedSizeWithLimit(value, @as(usize, bcs.max_container_depth) + 1),
    );

    emitUnitResult("from_bytes_with_limit_fail", bcs.deserializeWithLimit(D8, allocator, bytes, limit_fail));
    emitUnitResult("from_bytes_with_limit_ok", bcs.deserializeWithLimit(D8, allocator, bytes, limit_ok));
    emitUnitResult(
        "from_bytes_with_limit_above_max",
        bcs.deserializeWithLimit(D8, allocator, bytes, @as(usize, bcs.max_container_depth) + 1),
    );
}
