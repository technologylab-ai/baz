const std = @import("std");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, std.mem.trim(u8, @embedFile(".zig-version"), " \r\n")))
        @panic("Use exactly the Zig release in .zig-version");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        @panic("This MVP requires Debug or ReleaseSafe so its invariants remain enabled");
    }
    const module = b.addModule("bounded_http", .{
        .root_source_file = b.path("src/web.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // One module identity, two entry names: existing low-level imports remain
    // valid and can be mixed with the application API without duplicate types.
    b.modules.put(b.allocator, b.dupe("http_app"), module) catch @panic("out of memory");
    // Arch's GCC 16 CRT contains .sframe R_X86_64_PC64 relocations which
    // Zig 0.16's native ELF linker rejects. Use the bundled LLVM/LLD path
    // for Linux Debug only. ReleaseSafe uses its default toolchain selection.
    const exe = b.addExecutable(.{
        .use_llvm = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
        .use_lld = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
        .name = "zig-http",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "bounded_http", .module = module }},
        }),
    });
    b.installArtifact(exe);
    const app_exe = b.addExecutable(.{
        .name = "http-app",
        .use_llvm = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
        .use_lld = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app_demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "http_app", .module = module }},
        }),
    });
    b.installArtifact(app_exe);
    const app_run = b.addRunArtifact(app_exe);
    if (b.args) |args| app_run.addArgs(args);
    b.step("run-app", "Run the application API example").dependOn(&app_run.step);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the bounded HTTP experiment").dependOn(&run.step);
    const verify = b.step("verify", "Compile and test the exact-version MVP");
    verify.dependOn(&exe.step);
    verify.dependOn(&app_exe.step);
    const example_support = b.createModule(.{
        .root_source_file = b.path("examples/support.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http_app", .module = module }},
    });
    const examples = b.step("examples", "Build and install all supported Zap example ports");
    for ([_][]const u8{ "hello", "hello2", "hello_json", "simple_router", "routes", "serve", "sendfile", "senderror", "accept", "app_basic", "app_auth", "app_errors", "endpoint", "endpoint_auth", "middleware", "middleware_with_endpoint", "userpass_session", "cookies", "http_params", "bindataformpost" }) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .use_llvm = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
            .use_lld = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{ .{ .name = "http_app", .module = module }, .{ .name = "example_support", .module = example_support } },
            }),
        });
        const install_example = b.addInstallArtifact(example, .{});
        examples.dependOn(&install_example.step);
        b.step(name, b.fmt("Build and install {s}", .{name})).dependOn(&install_example.step);
        const run_example = b.addRunArtifact(example);
        if (b.args) |args| run_example.addArgs(args);
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name})).dependOn(&run_example.step);
        verify.dependOn(&example.step);
    }
    const format = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src", "examples" }, .check = true });
    verify.dependOn(&format.step);
    const version = b.addSystemCommand(&.{ "python3", "tools/check_version.py" });
    verify.dependOn(&version.step);
    const test_step = b.step("test", "Run unit and transport tests");
    for ([_][]const u8{ "src/http.zig", "src/api.zig", "src/budget.zig", "src/transport.zig", "src/server.zig", "src/params.zig", "src/form.zig", "src/request.zig", "src/multipart.zig", "src/response.zig", "src/router.zig", "src/App.zig", "src/web.zig" }) |path| {
        const tests = b.addTest(.{ .use_llvm = if (target.result.os.tag == .linux and optimize == .Debug) true else null, .use_lld = if (target.result.os.tag == .linux and optimize == .Debug) true else null, .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }) });
        const run_tests = b.addRunArtifact(tests);
        verify.dependOn(&run_tests.step);
        test_step.dependOn(&run_tests.step);
    }
}
