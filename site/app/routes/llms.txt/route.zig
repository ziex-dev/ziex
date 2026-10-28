pub fn GET(ctx: zx.RouteContext) !void {
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    var w = &aw.writer;

    const home = zx.info.homepage;
    const repo = zx.info.repository;

    try w.writeAll(
        \\# Ziex
        \\
        \\> Full-stack web framework for Zig. Compile-time safety, deterministic performance, absolute simplicity, and a delightful developer experience.
        \\
        \\ZX files use familiar HTML-style markup with full access to Zig control flow (`if`/`else`, `for`/`while`, `switch`). File-system routing, API routes, WebSockets, component/page caching, KV storage, and SQLite are built in. Deploy as a standalone binary, WASI edge module, or static site.
        \\
        \\Important notes:
        \\
        \\- ZX is stricter than HTML: all tags must be closed (including self-closing tags like `<br />`)
        \\- Components and pages receive an allocator (usually `ctx.arena` for request-scoped allocations)
        \\- File-system routing maps `pages/` and `routes/` to URLs; dynamic segments use `[param]` folders
        \\
        \\## Docs
        \\
    );
    try w.print(
        \\- [Learn]({s}/learn): Quick start covering core Ziex concepts
        \\- [Reference]({s}/reference): Language and API reference
        \\- [Examples]({s}/examples): Interactive feature demos
        \\- [Playground]({s}/playground): Try Ziex in the browser
        \\- [GitHub]({s}): Source repository
        \\
        \\## Examples
        \\
    , .{ home, home, home, home, repo });

    try writeParsedExamples(w, examples_source);

    try w.print(
        \\
        \\## Optional
        \\
        \\- [Framework comparisons]({s}/vs): Ziex vs other web frameworks
        \\- [Sitemap]({s}/sitemap.xml): All indexable pages
        \\
    , .{ home, home });

    ctx.response.setContentType(.@"text/plain");
    ctx.response.headers.set("Content-Type", "text/plain; charset=utf-8");
    ctx.response.text(aw.written());
}

fn writeParsedExamples(w: *std.Io.Writer, source: []const u8) !void {
    const prefix = "// --- ";
    const suffix = " ---";

    var last_group: ?[]const u8 = null;
    var pending_title: ?[]const u8 = null;
    var pending_start: usize = 0;

    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        const at_eof = i == source.len;
        const at_eol = !at_eof and source[i] == '\n';
        if (!at_eof and !at_eol) continue;

        const line = source[line_start..i];
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.startsWith(u8, trimmed, prefix) and std.mem.endsWith(u8, trimmed, suffix)) {
            if (pending_title) |title| {
                try writeSection(w, &last_group, title, source[pending_start..line_start]);
            }
            pending_title = trimmed[prefix.len .. trimmed.len - suffix.len];
            pending_start = i + @as(usize, @intFromBool(!at_eof));
        }

        line_start = i + 1;
        if (at_eof) break;
    }

    if (pending_title) |title| {
        try writeSection(w, &last_group, title, source[pending_start..]);
    }
}

fn writeSection(w: *std.Io.Writer, last_group: *?[]const u8, title: []const u8, raw_body: []const u8) !void {
    if (shouldSkipSection(title)) return;

    var body = std.mem.trim(u8, raw_body, " \t\r\n");
    if (body.len == 0) return;

    if (std.mem.indexOf(u8, body, "\nconst ziex = struct")) |idx| {
        body = std.mem.trimEnd(u8, body[0..idx], " \t\r\n");
    }
    if (body.len == 0) return;

    const group = sectionGroup(title);
    const heading = sectionHeading(title);

    if (last_group.* == null or !std.mem.eql(u8, last_group.*.?, group)) {
        try w.print("\n### {s}\n", .{group});
        last_group.* = group;
    }

    if (!std.mem.eql(u8, group, heading)) {
        try w.print("\n#### {s}\n\n", .{heading});
    } else {
        try w.writeAll("\n");
    }

    try w.writeAll("```zx\n");
    try w.writeAll(body);
    try w.writeAll("\n```\n");
}

fn shouldSkipSection(title: []const u8) bool {
    return std.mem.eql(u8, title, "Imports") or std.mem.eql(u8, title, "Learn: onnull");
}

fn sectionGroup(title: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, title, ':')) |idx| {
        return std.mem.trim(u8, title[0..idx], " ");
    }
    return title;
}

fn sectionHeading(title: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, title, ':')) |idx| {
        return std.mem.trim(u8, title[idx + 1 ..], " ");
    }
    return title;
}

const examples_source = @embedFile("../../pages/examples/feature_examples.zx");

const options: zx.RouteOptions = .{};

const zx = @import("zx");
const std = @import("std");
