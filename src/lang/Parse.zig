pub const Parse = @This();

const std = @import("std");
const ts = @import("tree_sitter");

const sourcemap = @import("sourcemap.zig");
const Render = @import("Render.zig");
const Transpile = @import("Transpile.zig");
const Markdown = @import("Markdown.zig");

pub const NodeKind = enum {
    /// (<..>..</..>)
    zx_block,
    /// <tag attr1={val1} />
    zx_element,
    /// <tag attr1={val1} />
    zx_self_closing_element,
    /// <>..</>
    zx_fragment,
    /// <div>
    zx_start_tag,
    /// </div>
    zx_end_tag,
    /// <|div|>
    zx_tag_name,
    /// attrexpr={val1}
    /// attrstr="test"
    /// attrbool
    zx_attribute,
    /// @attr
    zx_builtin_attribute,
    zx_regular_attribute,
    /// {class} shorthand for class={class}
    zx_shorthand_attribute,
    /// @{allocator} shorthand for @allocator={allocator}
    zx_builtin_shorthand_attribute,
    /// {..props} spread all properties of props as attributes
    zx_spread_attribute,
    zx_builtin_name,
    zx_attribute_name,
    zx_attribute_value,
    zx_expression_block,
    zx_string_literal,
    zx_template_string,
    zx_template_content,
    zx_template_substitution,
    zx_child,
    zx_text,
    zx_js_import,

    // Zig Related Nodes
    builtin_function,
    builtin_identifier,
    arguments,
    string_content,
    parenthesized_expression,

    identifier,
    field_expression,
    string,
    function_declaration,
    variable_declaration,
    return_expression,
    range_expression,

    // Control Flow Expressions
    if_expression,
    for_expression,
    while_expression,
    switch_expression,
    switch_case,
    payload,
    array_type,
    assignment_expression,
    multiline_string,

    /// Zig comment (// ...)
    comment,

    /// Anonymous/unrecognized node kind
    anon,

    fn fromString(s: []const u8) NodeKind {
        return std.meta.stringToEnum(NodeKind, s) orelse .anon;
    }

    pub fn fromNode(node: ?ts.Node) NodeKind {
        if (node == null) return .anon;
        return fromString(node.?.kind());
    }
};

pub const Language = enum {
    zx,
    mdzx,
    md,
};

tree: *ts.Tree,
lang: Language,
source: []const u8,
allocator: std.mem.Allocator,

pub const ParseLangOptions = struct {
    lang: Language = .zx,
    /// Source path used to decide default `Page` emission for MDZX/MD.
    path: ?[]const u8 = null,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8, lang: Language) !Parse {
    return parseWithOptions(allocator, source, .{ .lang = lang });
}

pub fn parseWithOptions(allocator: std.mem.Allocator, source: []const u8, opts: ParseLangOptions) !Parse {
    const parser = ts.Parser.create();
    parser.setLanguage(ts.Language.fromRaw(@import("tree_sitter_zx").language())) catch return error.LoadingLang;

    const effective_source = switch (opts.lang) {
        .zx => source,
        .mdzx, .md => try mdzxTozx(allocator, source, opts),
    };
    const tree = parser.parseString(effective_source, null) orelse return error.ParseError;

    return Parse{
        .tree = tree,
        .source = effective_source,
        .lang = opts.lang,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Parse, _: std.mem.Allocator) void {
    self.tree.destroy();
}

pub const ClientComponentMetadata = Transpile.ClientComponentMetadata;
pub const RenderResult = struct {
    source: []const u8,
    sourcemap: ?sourcemap.SourceMap = null,
    client_components: []const Transpile.ClientComponentMetadata,

    pub fn deinit(self: *RenderResult, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        if (self.sourcemap) |*sm| {
            sm.deinit();
        }
        for (self.client_components) |*component| {
            allocator.free(component.name);
            allocator.free(component.path);
            allocator.free(component.id);
        }
        allocator.free(self.client_components);
    }
};

pub const RenderOptions = struct {
    pub const RenderMode = enum { zx, zig };
    mode: RenderMode,
    sourcemap: bool,
    path: ?[]const u8,
};

pub fn renderAlloc(
    self: *Parse,
    allocator: std.mem.Allocator,
    options: RenderOptions,
) !RenderResult {
    switch (options.mode) {
        .zx => {
            var aw = std.Io.Writer.Allocating.init(allocator);
            var renderer = Render.init(self, allocator);
            defer renderer.deinit();
            try renderer.run(&aw.writer);
            return RenderResult{ .source = try aw.toOwnedSlice(), .client_components = &.{} };
        },
        .zig => {
            var transpiler = Transpile.init(self, allocator, .{ .sourcemap = options.sourcemap, .path = options.path });
            defer transpiler.deinit();
            try transpiler.run();

            return RenderResult{
                .source = try transpiler.output.toOwnedSlice(allocator),
                .sourcemap = if (options.sourcemap) try transpiler.finalizeSourceMap() else null,
                .client_components = try transpiler.client_components.toOwnedSlice(allocator),
            };
        },
    }
}

fn mdzxTozx(
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: ParseLangOptions,
) ![]const u8 {
    return Markdown.transpileWithOptions(allocator, source, .{
        .emit_default_page = Markdown.shouldEmitDefaultPage(opts.path),
        .pure_md = opts.lang == .md,
    }) catch |err| switch (err) {
        error.UserDeclaredRender => {
            std.log.err("MDZX/MD modules must not declare `render`; it is generated automatically", .{});
            return error.UserDeclaredRender;
        },
        error.PureMdEmbed => {
            std.log.err("Pure `.md` files cannot embed ZX components or `{{...}}` expressions; use `.mdzx` instead", .{});
            return error.PureMdEmbed;
        },
        else => |e| return e,
    };
}

pub fn getNodeText(self: *Parse, node: ts.Node) ![]const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start < end and end <= self.source.len) {
        return self.source[start..end];
    }
    return "";
}

pub fn getLineColumn(self: *const Parse, byte_offset: u32) struct { line: i32, column: i32 } {
    var line: i32 = 0;
    var column: i32 = 0;
    var i: u32 = 0;

    while (i < byte_offset and i < self.source.len) : (i += 1) {
        if (self.source[i] == '\n') {
            line += 1;
            column = 0;
        } else {
            column += 1;
        }
    }

    return .{ .line = line, .column = column };
}
