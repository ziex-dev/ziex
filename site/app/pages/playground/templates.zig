//! Playground starter templates: hand-written ones plus snippets cut from the
//! feature examples. Plain data, shared by the page (default files) and the worker.
const std = @import("std");
const util = @import("../reference/util.zig");

pub const Mode = enum(u8) { playground, app };

pub const File = struct {
    name: []const u8,
    content: []const u8,
    /// A library source opened from a hover link: shown, never built, shared or saved.
    readonly: bool = false,
};

pub const Template = struct {
    id: []const u8,
    label: []const u8,
    mode: Mode,
    files: []const File,
};

/// Files every run gets that aren't shown as tabs.
pub fn sharedMain(mode: Mode) File {
    return switch (mode) {
        .playground => .{ .name = "main.zig", .content = pg_main },
        .app => .{ .name = "app/main.zig", .content = app_main },
    };
}

/// The template the page opens with (also rendered on the server).
pub const default_files = [_]File{
    .{ .name = "Playground.zx", .content = pg_hello },
    .{ .name = "style.css", .content = pg_css },
};

pub fn all(a: std.mem.Allocator) ![]const Template {
    var list: std.ArrayList(Template) = .empty;

    try list.append(a, .{ .id = "playground", .label = "Playground", .mode = .playground, .files = &default_files });
    try list.append(a, .{ .id = "app", .label = "App", .mode = .app, .files = &.{
        .{ .name = "app/pages/layout.zx", .content = app_layout },
        .{ .name = "app/pages/page.zx", .content = app_page },
        .{ .name = "app/pages/about/page.zx", .content = app_about },
        .{ .name = "app/routes/api/route.zig", .content = app_api },
    } });
    try list.append(a, .{ .id = "app-events", .label = "App events", .mode = .app, .files = &.{
        .{ .name = "app/pages/layout.zx", .content = events_layout },
        .{ .name = "app/pages/page.zx", .content = events_page },
    } });

    // Feature examples without client rendering.
    const snippets = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "Learn: greeting", "greeting", "Greeting" },
        .{ "Learn: markup", "markup", "Markup" },
        .{ "Learn: text expression", "text-expr", "Text expression" },
        .{ "Learn: format expression", "format-expr", "Format expression" },
        .{ "Learn: conditional", "conditional", "Conditional" },
        .{ "Learn: switch", "switch", "Switch" },
        .{ "Learn: list", "list", "List" },
        .{ "Learn: props", "props", "Props" },
        .{ "Learn: fragment", "fragment", "Fragment" },
        .{ "Learn: children", "children", "Children" },
        .{ "Learn: dynamic attributes", "dyn-attrs", "Dynamic attributes" },
        .{ "Expressions", "expressions", "Expressions" },
        .{ "Component: fragment", "component-fragment", "Component fragment" },
        .{ "Component: attr", "dyn-attr", "Dynamic attr" },
        .{ "Builtin Attributes: escaping", "escaping", "Escaping" },
    };
    for (snippets) |s| {
        try list.append(a, .{ .id = s[1], .label = s[2], .mode = .playground, .files = try files(a, &.{
            .{ .name = "Playground.zx", .content = try section(a, s[0]) },
        }) });
    }

    // Feature examples as apps.
    try list.append(a, .{ .id = "fs-routing", .label = "File system routing", .mode = .app, .files = try files(a, &.{
        .{ .name = "app/pages/layout.zx", .content = try section(a, "File System Routing: layout") },
        .{ .name = "app/pages/page.zx", .content = try section(a, "File System Routing: page") },
    }) });
    try list.append(a, .{ .id = "learn-page", .label = "Page + layout", .mode = .app, .files = try files(a, &.{
        .{ .name = "app/pages/layout.zx", .content = try section(a, "Learn: layout") },
        .{ .name = "app/pages/page.zx", .content = try section(a, "Learn: page") },
    }) });
    try list.append(a, try pageOnly(a, "csr", "Client-side rendering", "Client-side Rendering"));
    try list.append(a, .{ .id = "api-route", .label = "API route", .mode = .app, .files = try files(a, &.{
        .{ .name = "app/pages/layout.zx", .content = try section(a, "Learn: layout") },
        .{ .name = "app/pages/page.zx", .content = try section(a, "Learn: page") },
        .{ .name = "app/routes/api/route.zig", .content = try section(a, "Learn: api route") },
    }) });
    try list.append(a, try pageOnly(a, "onclick", "Onclick", "Learn: onclick"));
    try list.append(a, try pageOnly(a, "state", "State management", "Learn: state management"));

    return list.toOwnedSlice(a);
}

fn pageOnly(a: std.mem.Allocator, id: []const u8, label: []const u8, name: []const u8) !Template {
    return .{ .id = id, .label = label, .mode = .app, .files = try files(a, &.{
        .{ .name = "app/pages/layout.zx", .content = simple_layout },
        .{ .name = "app/pages/page.zx", .content = try section(a, name) },
    }) };
}

fn files(a: std.mem.Allocator, items: []const File) ![]const File {
    return a.dupe(File, items);
}

/// A `// --- name ---` section of the feature examples, with the imports it needs.
fn section(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const body = std.mem.trim(u8, util.extractSection(a, examples_source, name), " \t\n\r");
    if (std.mem.indexOf(u8, body, "@import(\"zx\")") != null) return body;
    if (std.mem.indexOf(u8, body, "std.") != null)
        return std.fmt.allocPrint(a, "{s}\n\nconst std = @import(\"std\");\nconst zx = @import(\"zx\");\n", .{body});
    return std.fmt.allocPrint(a, "{s}\n\nconst zx = @import(\"zx\");\n", .{body});
}

const examples_source = @embedFile("../examples/feature_examples.zx");

const pg_hello = @embedFile("../../playground/template/Playground.zx");
const pg_main = @embedFile("../../playground/template/main.zig");
const pg_css = @embedFile("../../playground/template/style.css");

const app_main = @embedFile("../../playground/template/app/main.zig");
const app_layout = @embedFile("../../playground/template/app/pages/layout.zx");
const app_page = @embedFile("../../playground/template/app/pages/page.zx");
const app_about = @embedFile("../../playground/template/app/pages/about/page.zx");
const app_api = @embedFile("../../playground/template/app/routes/api/route.zig");

const events_layout = @embedFile("../../playground/template/app-events/pages/layout.zx");
const events_page = @embedFile("../../playground/template/app-events/pages/page.zx");

pub const stubs = [_]File{
    .{ .name = "stubs/zx_info.zig", .content = @embedFile("../../playground/template/stubs/zx_info.zig") },
    .{ .name = "stubs/app_opts.zig", .content = @embedFile("../../playground/template/stubs/app_opts.zig") },
    .{ .name = "stubs/manifest.zon", .content = @embedFile("../../playground/template/stubs/manifest.zon") },
    .{ .name = "stubs/build_injections.zon", .content = @embedFile("../../playground/template/stubs/build_injections.zon") },
};

const simple_layout =
    \\pub fn Layout(ctx: zx.LayoutContext, children: zx.Component) zx.Component {
    \\    return (
    \\        <html @allocator={ctx.arena} lang="en-US">
    \\            <head>
    \\                <meta charset="UTF-8" />
    \\                <title>Playground</title>
    \\            </head>
    \\            <body>
    \\                {children}
    \\            </body>
    \\        </html>
    \\    );
    \\}
    \\
    \\const zx = @import("zx");
    \\
;
