const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const framework = b.dependency("baz", .{ .target = target, .optimize = optimize });
    const tests = b.addTest(.{
        .use_llvm = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
        .use_lld = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "baz", .module = framework.module("baz") },
                .{ .name = "bounded_http", .module = framework.module("bounded_http") },
            },
        }),
    });
    b.step("check", "Compile the independent consumer without executing its tests").dependOn(&tests.step);
    b.step("test", "Verify independent framework consumption and engine type identity").dependOn(&b.addRunArtifact(tests).step);
}
