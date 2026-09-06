//! Startup-owned Mustache templates, explicit partials, and bounded cached rendering.
const std = @import("std");
const engine = @import("mustache_engine");

pub const Value = engine.Value;
pub const RenderLimits = engine.RenderLimits;

pub const Partial = struct {
    name: []const u8,
    source: []const u8,
};

pub const Options = struct {
    partials: []const Partial = &.{},
    /// One startup allocation covers copied source, parsed nodes and parser scratch.
    storage_bytes: usize = 256 * 1024,
    /// Aggregate source and partial-name bytes.
    max_source_bytes: usize = 64 * 1024,
    max_partials: usize = 32,
    max_elements: usize = 4096,
    max_depth: usize = 64,
    render_limits: RenderLimits = .{},
};

/// Owns a fixed startup allocation. Do not copy this owner after initialization.
/// Share a const pointer for concurrent renders, then deinit after all users stop.
pub const Template = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    parsed: engine.Template,
    partials: std.StringHashMapUnmanaged(engine.Template),
    render_limits: RenderLimits,

    /// Parse before App.start. Source and partial names are copied, so their
    /// original buffers may be released after this call. No implicit file lookup.
    pub fn init(allocator: std.mem.Allocator, source: []const u8, options: Options) !Template {
        if (options.storage_bytes == 0 or options.storage_bytes > 16 * 1024 * 1024 or
            options.max_source_bytes > 1024 * 1024 or options.max_partials > 128 or
            options.max_elements == 0 or options.max_elements > 65536 or
            options.max_depth == 0 or options.max_depth > 128 or
            options.render_limits.max_depth == 0 or options.render_limits.max_depth > 128 or
            options.render_limits.max_work == 0)
            return error.InvalidTemplateLimits;
        if (options.partials.len > options.max_partials or source.len > options.max_source_bytes)
            return error.TemplateLimit;
        var source_bytes = source.len;
        for (options.partials) |partial| {
            if (partial.name.len == 0) return error.InvalidPartialName;
            source_bytes = std.math.add(usize, source_bytes, partial.name.len) catch return error.TemplateLimit;
            source_bytes = std.math.add(usize, source_bytes, partial.source.len) catch return error.TemplateLimit;
            if (source_bytes > options.max_source_bytes) return error.TemplateLimit;
        }

        const storage = try allocator.alloc(u8, options.storage_bytes);
        errdefer allocator.free(storage);
        var fixed = std.heap.FixedBufferAllocator.init(storage);
        const startup = fixed.allocator();
        var element_count: usize = 0;
        const parsed = try parse(startup, source, options, &element_count);
        var partials: std.StringHashMapUnmanaged(engine.Template) = .empty;
        for (options.partials) |partial| {
            if (partials.contains(partial.name)) return error.DuplicatePartial;
            const name = startup.dupe(u8, partial.name) catch return error.TemplateStorageLimit;
            const value = try parse(startup, partial.source, options, &element_count);
            partials.put(startup, name, value) catch return error.TemplateStorageLimit;
        }
        return .{ .allocator = allocator, .storage = storage, .parsed = parsed, .partials = partials, .render_limits = options.render_limits };
    }

    pub fn deinit(self: *Template) void {
        // Every parser allocation, including intermediate storage, belongs to
        // this one fixed block. The renderer never owns or frees any of it.
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    /// Data is borrowed only until this call returns. Writers remain exclusive.
    /// An error may leave a writer prefix; Response.mustache keeps it unpublished.
    pub fn renderTo(self: *const Template, writer: *std.Io.Writer, data: anytype) !void {
        try engine.renderPartialsBounded(self.parsed, self.partials, data, writer, self.render_limits);
    }
};

fn parse(allocator: std.mem.Allocator, source: []const u8, options: Options, count: *usize) !engine.Template {
    const result = engine.parseText(allocator, source, .{}, .{
        .copy_strings = true,
        .features = .{ .lambdas = .disabled },
    }) catch return error.TemplateStorageLimit;
    const parsed = switch (result) {
        .success => |value| value,
        .parse_error => |detail| return detail.parse_error,
    };
    if (parsed.elements.len > options.max_elements - count.*) return error.TemplateLimit;
    count.* += parsed.elements.len;
    var ends: [128]usize = undefined;
    var depth: usize = 0;
    for (parsed.elements, 0..) |element, index| {
        while (depth != 0 and index >= ends[depth - 1]) depth -= 1;
        switch (element) {
            .parent, .block => return error.UnsupportedTemplateFeature,
            .partial => |partial| if (std.mem.startsWith(u8, partial.key, "*")) return error.UnsupportedTemplateFeature,
            .interpolation, .unescaped_interpolation => |path| try checkPath(path, options),
            .section => |section| {
                try checkPath(section.path, options);
                try pushDepth(&ends, &depth, index, section.children_count, options);
            },
            .inverted_section => |section| {
                try checkPath(section.path, options);
                try pushDepth(&ends, &depth, index, section.children_count, options);
            },
            .static_text => {},
        }
    }
    return parsed;
}

fn checkPath(path: engine.Element.Path, options: Options) !void {
    if (path.len > options.max_depth) return error.TemplateLimit;
}

fn pushDepth(ends: *[128]usize, depth: *usize, index: usize, children: usize, options: Options) !void {
    if (depth.* == options.max_depth) return error.TemplateLimit;
    ends[depth.*] = std.math.add(usize, index + 1, children) catch return error.TemplateLimit;
    depth.* += 1;
}

test "template owns source and named partials and renders through a fixed writer" {
    var source = "Hello {{name}}: {{> detail}}".*;
    var part = "{{nested.value}}".*;
    var name = "detail".*;
    var template = try Template.init(std.testing.allocator, &source, .{ .partials = &.{.{ .name = &name, .source = &part }} });
    defer template.deinit();
    @memset(&source, '?');
    @memset(&part, '?');
    @memset(&name, '?');
    var bytes: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&bytes);
    try template.renderTo(&out, .{ .name = "<Rene>", .nested = .{ .value = "works" } });
    try std.testing.expectEqualStrings("Hello &lt;Rene&gt;: works", out.buffered());
}

test "startup memory source element nesting and partial bounds reject with ordinary errors" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.TemplateStorageLimit, Template.init(allocator, "hello {{name}}", .{ .storage_bytes = 1 }));
    try std.testing.expectError(error.TemplateLimit, Template.init(allocator, "four", .{ .max_source_bytes = 3 }));
    try std.testing.expectError(error.TemplateLimit, Template.init(allocator, "a{{name}}", .{ .max_elements = 1 }));
    try std.testing.expectError(error.TemplateLimit, Template.init(allocator, "{{#a}}{{#b}}x{{/b}}{{/a}}", .{ .max_depth = 1 }));
    try std.testing.expectError(error.TemplateLimit, Template.init(allocator, "{{a.b}}", .{ .max_depth = 1 }));
    try std.testing.expectError(error.DuplicatePartial, Template.init(allocator, "", .{ .partials = &.{ .{ .name = "x", .source = "a" }, .{ .name = "x", .source = "b" } } }));
    try std.testing.expectError(error.TemplateLimit, Template.init(allocator, "", .{ .max_partials = 0, .partials = &.{.{ .name = "x", .source = "a" }} }));
    try std.testing.expectError(error.InvalidPartialName, Template.init(allocator, "", .{ .partials = &.{.{ .name = "", .source = "a" }} }));
    try std.testing.expectError(error.UnexpectedEof, Template.init(allocator, "{{#x}}", .{}));
    try std.testing.expectError(error.UnsupportedTemplateFeature, Template.init(allocator, "{{<layout}}hello{{/layout}}", .{}));
    try std.testing.expectError(error.UnsupportedTemplateFeature, Template.init(allocator, "{{>*layout}}", .{}));
}

test "empty template fits empty output and immutable template can be reused after overflow" {
    var empty = try Template.init(std.testing.allocator, "", .{});
    defer empty.deinit();
    var none: [0]u8 = .{};
    var empty_out: std.Io.Writer = .fixed(&none);
    try empty.renderTo(&empty_out, .{});
    var template = try Template.init(std.testing.allocator, "{{name}}", .{});
    defer template.deinit();
    var short: [3]u8 = undefined;
    var short_out: std.Io.Writer = .fixed(&short);
    try std.testing.expectError(error.WriteFailed, template.renderTo(&short_out, .{ .name = "<&>" }));
    var exact: [13]u8 = undefined;
    var out: std.Io.Writer = .fixed(&exact);
    try template.renderTo(&out, .{ .name = "<&>" });
    try std.testing.expectEqualStrings("&lt;&amp;&gt;", out.buffered());
}

test "parser rejects excessive dotted recursion before post-parse validation" {
    const source = "{{" ++ "a." ** 1000 ++ "a}}";
    try std.testing.expectError(error.DepthLimitExceeded, Template.init(std.testing.allocator, source, .{}));
}

test "empty delimiter declarations return an ordinary parse error" {
    for ([_][]const u8{ "{{=}}", "{{=}}x" }) |source| {
        try std.testing.expectError(error.InvalidDelimiters, Template.init(std.testing.allocator, source, .{}));
    }
}

test "delimiter declarations reject embedded line breaks without parser panic" {
    try std.testing.expectError(error.InvalidDelimiters, Template.init(std.testing.allocator, "{{=A\nX Y=}}A\nXnameY", .{}));
}
