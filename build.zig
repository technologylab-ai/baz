const std = @import("std");

pub fn build(b: *std.Build) void {
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, std.mem.trim(u8, @embedFile(".zig-version"), " \r\n")))
        @panic("Use exactly the Zig release in .zig-version");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        @panic("This MVP requires Debug or ReleaseSafe so its invariants remain enabled");
    }
    const engine = b.dependency("bounded_http", .{
        .target = target,
        .optimize = optimize,
    }).module("bounded_http");
    const module = b.addModule("baz", .{
        .root_source_file = b.path("src/web.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "bounded_http", .module = engine }},
    });
    // Consumers may import the framework and its exact engine module together.
    b.modules.put(b.allocator, b.dupe("bounded_http"), engine) catch @panic("out of memory");
    // Arch's GCC 16 CRT contains .sframe R_X86_64_PC64 relocations which
    // Zig 0.16's native ELF linker rejects. Use the bundled LLVM/LLD path
    // for Linux Debug only. ReleaseSafe uses its default toolchain selection.
    const app_exe = b.addExecutable(.{
        .name = "baz",
        .use_llvm = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
        .use_lld = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app_demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "baz", .module = module }},
        }),
    });
    b.installArtifact(app_exe);
    const app_run = b.addRunArtifact(app_exe);
    if (b.args) |args| app_run.addArgs(args);
    b.step("run-app", "Run the application API example").dependOn(&app_run.step);
    b.step("run", "Run the application API example").dependOn(&app_run.step);
    const verify = b.step("verify", "Compile and test the exact-version MVP");
    const check = b.step("check", "Compile all framework tests and examples without executing target binaries");
    const stream_fixture = b.addExecutable(.{
        .name = "baz-streaming",
        .use_llvm = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
        .use_lld = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/streaming_demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "baz", .module = module }},
        }),
    });
    b.installArtifact(stream_fixture);
    check.dependOn(&stream_fixture.step);
    verify.dependOn(&stream_fixture.step);
    check.dependOn(&app_exe.step);
    verify.dependOn(&app_exe.step);
    const example_support = b.createModule(.{
        .root_source_file = b.path("examples/support.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "baz", .module = module }},
    });
    const examples = b.step("examples", "Build and install all supported Zap example ports");
    for ([_][]const u8{ "hello", "hello2", "hello_json", "simple_router", "routes", "serve", "sendfile", "senderror", "accept", "app_basic", "app_auth", "app_errors", "endpoint", "endpoint_auth", "middleware", "middleware_with_endpoint", "userpass_session", "cookies", "http_params", "bindataformpost", "streaming" }) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .use_llvm = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
            .use_lld = if (target.result.os.tag == .linux and optimize == .Debug) true else null,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{ .{ .name = "baz", .module = module }, .{ .name = "example_support", .module = example_support } },
            }),
        });
        const install_example = b.addInstallArtifact(example, .{});
        examples.dependOn(&install_example.step);
        b.step(name, b.fmt("Build and install {s}", .{name})).dependOn(&install_example.step);
        const run_example = b.addRunArtifact(example);
        if (b.args) |args| run_example.addArgs(args);
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name})).dependOn(&run_example.step);
        verify.dependOn(&example.step);
        check.dependOn(&example.step);
    }
    const format = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src", "examples" }, .check = true });
    verify.dependOn(&format.step);
    check.dependOn(&format.step);
    const version = b.addSystemCommand(&.{ "python3", "tools/check_version.py" });
    verify.dependOn(&version.step);
    check.dependOn(&version.step);
    const target_arg = b.fmt("-Dtarget={s}", .{target.query.zigTriple(b.allocator) catch @panic("out of memory")});
    const cpu_arg = b.fmt("-Dcpu={s}", .{target.query.serializeCpuAlloc(b.allocator) catch @panic("out of memory")});
    for ([_][]const u8{ "test", "check" }) |step| {
        const consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", step, target_arg, cpu_arg, b.fmt("-Doptimize={s}", .{@tagName(optimize)}), "-j2", "--summary", "all" });
        consumer.setCwd(b.path("examples/embedding"));
        if (std.mem.eql(u8, step, "test")) verify.dependOn(&consumer.step) else check.dependOn(&consumer.step);
    }
    const test_step = b.step("test", "Run framework unit tests");
    for ([_][]const u8{ "src/params.zig", "src/form.zig", "src/request.zig", "src/multipart.zig", "src/response.zig", "src/router.zig", "src/App.zig", "src/web.zig" }) |path| {
        const tests = b.addTest(.{ .use_llvm = if (target.result.os.tag == .linux and optimize == .Debug) true else null, .use_lld = if (target.result.os.tag == .linux and optimize == .Debug) true else null, .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "bounded_http", .module = engine }},
        }) });
        check.dependOn(&tests.step);
        const run_tests = b.addRunArtifact(tests);
        verify.dependOn(&run_tests.step);
        test_step.dependOn(&run_tests.step);
    }
}
