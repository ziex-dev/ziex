pub fn GET(ctx: zx.RouteContext) !void {
    try ctx.response.json(try prepare(ctx.arena), .{});
}

const Response = struct {
    shared_files: SharedFiles,
    templates: []const Template,
};

const SharedFiles = struct {
    none_app: []const Template.File,
    app: []const Template.File,
};

fn prepare(allocator: zx.Allocator) !Response {
    var list: std.ArrayList(Template) = .empty;

    // ── Hand-crafted defaults ──
    try list.append(allocator, .{
        .name = "playground",
        .description = "Playground",
        .kind = .none_app,
        .files = try files(allocator, &.{
            .{ .path = "Playground.zx", .content = pg_hello },
            .{ .path = "style.css", .content = pg_css },
        }),
    });

    try list.append(allocator, .{
        .name = "app",
        .description = "App",
        .kind = .app,
        .files = try files(allocator, &.{
            .{ .path = "app/pages/layout.zx", .content = app_layout },
            .{ .path = "app/pages/page.zx", .content = app_page },
            .{ .path = "app/pages/about/page.zx", .content = app_about },
            .{ .path = "app/routes/api/route.zig", .content = app_api },
        }),
    });

    try list.append(allocator, .{
        .name = "app-events",
        .description = "App events",
        .kind = .app,
        .files = try files(allocator, &.{
            .{ .path = "app/pages/layout.zx", .content = events_layout },
            .{ .path = "app/pages/page.zx", .content = events_page },
        }),
    });

    // ── Feature examples → none_app (no CSR; no style.css; shared main.zig) ──
    const none_app_specs = [_]FeatureSpec{
        .{ .section = "Learn: greeting", .name = "greeting", .description = "Greeting" },
        .{ .section = "Learn: markup", .name = "markup", .description = "Markup" },
        .{ .section = "Learn: text expression", .name = "text-expr", .description = "Text expression" },
        .{ .section = "Learn: format expression", .name = "format-expr", .description = "Format expression" },
        .{ .section = "Learn: conditional", .name = "conditional", .description = "Conditional" },
        .{ .section = "Learn: switch", .name = "switch", .description = "Switch" },
        .{ .section = "Learn: list", .name = "list", .description = "List" },
        .{ .section = "Learn: props", .name = "props", .description = "Props" },
        .{ .section = "Learn: fragment", .name = "fragment", .description = "Fragment" },
        .{ .section = "Learn: children", .name = "children", .description = "Children" },
        .{ .section = "Learn: dynamic attributes", .name = "dyn-attrs", .description = "Dynamic attributes" },
        .{ .section = "Expressions", .name = "expressions", .description = "Expressions" },
        .{ .section = "Component: fragment", .name = "component-fragment", .description = "Component fragment" },
        .{ .section = "Component: attr", .name = "dyn-attr", .description = "Dynamic attr" },
        .{ .section = "Builtin Attributes: escaping", .name = "escaping", .description = "Escaping" },
    };
    for (none_app_specs) |spec| {
        try list.append(allocator, try noneAppFromSection(allocator, spec));
    }

    // ── Feature examples → app (CSR examples use Page(...) as entry) ──
    try list.append(allocator, try appFromPageLayout(allocator, .{
        .name = "fs-routing",
        .description = "File system routing",
        .page_section = "File System Routing: page",
        .layout_section = "File System Routing: layout",
    }));
    try list.append(allocator, try appFromPageLayout(allocator, .{
        .name = "learn-page",
        .description = "Page + layout",
        .page_section = "Learn: page",
        .layout_section = "Learn: layout",
    }));
    try list.append(allocator, try appFromPageSection(allocator, .{
        .section = "Client-side Rendering",
        .name = "csr",
        .description = "Client-side rendering",
    }));
    try list.append(allocator, try appWithApiRoute(allocator, .{
        .name = "api-route",
        .description = "API route",
        .page_section = "Learn: page",
        .layout_section = "Learn: layout",
        .api_section = "Learn: api route",
    }));
    try list.append(allocator, try appFromPageSection(allocator, .{
        .section = "Learn: onclick",
        .name = "onclick",
        .description = "Onclick",
    }));
    try list.append(allocator, try appFromPageSection(allocator, .{
        .section = "Learn: state management",
        .name = "state",
        .description = "State management",
    }));

    return .{
        .shared_files = .{
            .none_app = try files(allocator, &.{
                .{ .path = "main.zig", .content = pg_main },
            }),
            .app = try files(allocator, &.{
                .{ .path = "app/main.zig", .content = app_main },
            }),
        },
        .templates = try list.toOwnedSlice(allocator),
    };
}

const FeatureSpec = struct {
    section: []const u8,
    name: []const u8,
    description: []const u8,
};

const PageLayoutSpec = struct {
    name: []const u8,
    description: []const u8,
    page_section: []const u8,
    layout_section: []const u8,
};

const ApiAppSpec = struct {
    name: []const u8,
    description: []const u8,
    page_section: []const u8,
    layout_section: []const u8,
    api_section: []const u8,
};

fn noneAppFromSection(allocator: zx.Allocator, spec: FeatureSpec) !Template {
    const body = util.extractSection(allocator, examples_source, spec.section);
    return .{
        .name = spec.name,
        .description = spec.description,
        .kind = .none_app,
        .files = try files(allocator, &.{
            .{ .path = "Playground.zx", .content = try withZxImport(allocator, body) },
        }),
    };
}

fn appFromPageLayout(allocator: zx.Allocator, spec: PageLayoutSpec) !Template {
    const page_body = util.extractSection(allocator, examples_source, spec.page_section);
    const layout_body = util.extractSection(allocator, examples_source, spec.layout_section);
    return .{
        .name = spec.name,
        .description = spec.description,
        .kind = .app,
        .files = try files(allocator, &.{
            .{ .path = "app/pages/layout.zx", .content = try withZxImport(allocator, layout_body) },
            .{ .path = "app/pages/page.zx", .content = try withZxImport(allocator, page_body) },
        }),
    };
}

fn appFromPageSection(allocator: zx.Allocator, spec: FeatureSpec) !Template {
    const body = util.extractSection(allocator, examples_source, spec.section);
    return .{
        .name = spec.name,
        .description = spec.description,
        .kind = .app,
        .files = try files(allocator, &.{
            .{ .path = "app/pages/layout.zx", .content = app_layout_simple },
            .{ .path = "app/pages/page.zx", .content = try withZxImport(allocator, body) },
        }),
    };
}

fn appWithApiRoute(allocator: zx.Allocator, spec: ApiAppSpec) !Template {
    const page_body = util.extractSection(allocator, examples_source, spec.page_section);
    const layout_body = util.extractSection(allocator, examples_source, spec.layout_section);
    const api_body = util.extractSection(allocator, examples_source, spec.api_section);
    return .{
        .name = spec.name,
        .description = spec.description,
        .kind = .app,
        .files = try files(allocator, &.{
            .{ .path = "app/pages/layout.zx", .content = try withZxImport(allocator, layout_body) },
            .{ .path = "app/pages/page.zx", .content = try withZxImport(allocator, page_body) },
            .{ .path = "app/routes/api/route.zig", .content = try withZxImport(allocator, api_body) },
        }),
    };
}

fn withZxImport(allocator: zx.Allocator, body: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\n\r");
    if (std.mem.indexOf(u8, trimmed, "@import(\"zx\")") != null) {
        return try allocator.dupe(u8, trimmed);
    }
    const needs_std = std.mem.indexOf(u8, trimmed, "std.") != null;
    if (needs_std) {
        return try allocator.print("{s}\n\nconst std = @import(\"std\");\nconst zx = @import(\"zx\");\n", .{trimmed});
    }
    return try allocator.print("{s}\n\nconst zx = @import(\"zx\");\n", .{trimmed});
}

fn files(allocator: zx.Allocator, items: []const Template.File) ![]const Template.File {
    return try allocator.dupe(Template.File, items);
}

pub const Template = struct {
    pub const Kind = enum { app, none_app };
    pub const File = struct {
        path: []const u8,
        content: []const u8,
    };

    name: []const u8,
    description: []const u8,
    kind: Kind,
    files: []const File,
};

const options: zx.RouteOptions = .{};

const examples_source = @embedFile("../../examples/feature_examples.zx");
const util = @import("../../reference/util.zig");

const pg_hello = @embedFile("../scripts/template/Playground.zx");
const pg_main = @embedFile("../scripts/template/main.zig");
const pg_css = @embedFile("../scripts/template/style.css");

const app_main = @embedFile("../scripts/template/app/main.zig");
const app_layout = @embedFile("../scripts/template/app/pages/layout.zx");
const app_page = @embedFile("../scripts/template/app/pages/page.zx");
const app_about = @embedFile("../scripts/template/app/pages/about/page.zx");
const app_api = @embedFile("../scripts/template/app/routes/api/route.zig");

const events_layout = @embedFile("../scripts/template/app-events/pages/layout.zx");
const events_page = @embedFile("../scripts/template/app-events/pages/page.zx");

const app_layout_simple =
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

const zx = @import("zx");
const std = @import("std");
