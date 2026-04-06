const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bcs = b.addModule("bcs", .{
        .root_source_file = b.path("src/bcs.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = bcs });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run BCS tests");
    test_step.dependOn(&run_tests.step);

    const compat = b.addSystemCommand(&[_][]const u8{
        "sh",
        "bench/verify_compat.sh",
    });
    const compat_step = b.step("compat", "Run Rust/Zig compatibility checks");
    compat_step.dependOn(&compat.step);
}
