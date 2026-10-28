const std = @import("std");
const ts = @import("tree_sitter");
const Parse = @import("../Parse.zig");
const html = @import("elements.zig");
pub const elements = html;
pub const builtins = @import("builtins.zig");

const AllocError = std.mem.Allocator.Error;

/// Severity level of a diagnostic message.
pub const Severity = enum { err, warning };

/// A single structured diagnostic produced during validation.
pub const Diagnostic = struct {
    /// Human-readable description of the problem.
    message: []const u8,
    /// 0-based start line number in the source file.
    start_line: u32,
    /// 0-based start column number in the source file.
    start_column: u32,
    /// 0-based end line number in the source file.
    end_line: u32,
    /// 0-based end column number in the source file.
    end_column: u32,
    /// Severity of this diagnostic.
    severity: Severity,
};

/// An owned, heap-allocated list of `Diagnostic` values.
/// Always call `deinit()` when done.
pub const DiagnosticList = struct {
    items: []const Diagnostic,
    allocator: std.mem.Allocator,

    /// Returns `true` if any diagnostic has `.err` severity.
    pub fn hasErrors(self: DiagnosticList) bool {
        for (self.items) |d| {
            if (d.severity == .err) return true;
        }
        return false;
    }

    /// Free all memory owned by this list (messages and the slice itself).
    pub fn deinit(self: *DiagnosticList) void {
        for (self.items) |d| self.allocator.free(d.message);
        self.allocator.free(self.items);
    }
};

/// Walk `parser`'s tree-sitter AST and collect diagnostics.
///
/// Two passes run over the tree:
///   1. Syntax errors from tree-sitter recovery:
///      - ERROR nodes produce "Unexpected token '<text>'" messages.
///      - MISSING nodes produce "Expected '<token>'" messages.
///   2. Semantic HTML validation (mirroring `fmt/html`), e.g. unknown HTML
///      tag names, HTML elements that illegally self-close, end tags on void
///      elements, deprecated elements, duplicate attributes, and duplicate
///      `id` values.
///
/// The caller owns the returned `DiagnosticList` and must call `deinit()` on it.
pub fn validate(allocator: std.mem.Allocator, parser: *Parse) !DiagnosticList {
    var list = std.ArrayList(Diagnostic).empty;
    errdefer {
        for (list.items) |d| allocator.free(d.message);
        list.deinit(allocator);
    }

    const root = parser.tree.rootNode();
    if (root.hasError()) {
        try collectDiagnostics(allocator, root, parser.source, &list);
    }

    if (!root.hasError()) {
        var seen_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer seen_ids.deinit(allocator);
        try validateSemantics(allocator, root, parser.source, &list, &seen_ids);
    }

    return DiagnosticList{
        .items = try list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Recursively walk `node` and append a `Diagnostic` for every ERROR or
/// MISSING descendant.
///
/// Some tree-sitter recoveries produce a broad parent ERROR node, sometimes
/// all the way up to the root, while still nesting more precise error markers
/// underneath. In that case we prefer the narrower descendants so the LSP
/// highlights the actual bad line instead of the whole file.
fn collectDiagnostics(
    allocator: std.mem.Allocator,
    node: ts.Node,
    source: []const u8,
    list: *std.ArrayList(Diagnostic),
) AllocError!void {
    if (node.isError()) {
        if (!(try collectNestedErrorDiagnostics(allocator, node, source, list))) {
            try list.append(allocator, try errorDiagnostic(allocator, node, source));
        }
        return;
    }

    if (node.isMissing()) {
        try list.append(allocator, try missingDiagnostic(allocator, node));
        return;
    }

    // Only recurse into subtrees that carry an error to avoid a full-tree walk
    // on otherwise valid source.
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (child.hasError() or child.isMissing()) {
            try collectDiagnostics(allocator, child, source, list);
        }
    }
}

fn collectNestedErrorDiagnostics(
    allocator: std.mem.Allocator,
    node: ts.Node,
    source: []const u8,
    list: *std.ArrayList(Diagnostic),
) AllocError!bool {
    var found_nested = false;
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (child.isError() or child.isMissing() or child.hasError()) {
            const before_len = list.items.len;
            try collectDiagnostics(allocator, child, source, list);
            found_nested = found_nested or list.items.len > before_len;
        }
    }
    return found_nested;
}

fn errorDiagnostic(allocator: std.mem.Allocator, node: ts.Node, source: []const u8) !Diagnostic {
    const start_point = node.startPoint();
    const end_point = node.endPoint();
    const start = node.startByte();
    const end = node.endByte();

    // Extract the offending text for a more informative message, but cap its
    // length so the message stays readable.
    const max_snippet = 48;
    const raw = if (start < end and end <= source.len) source[start..end] else "";
    const snippet = if (raw.len > max_snippet) raw[0..max_snippet] else raw;

    const message = if (snippet.len > 0)
        try allocator.print("Unexpected token '{s}'", .{snippet})
    else
        try allocator.dupe(u8, "Syntax error");

    return Diagnostic{
        .message = message,
        .start_line = start_point.row,
        .start_column = start_point.column,
        .end_line = end_point.row,
        .end_column = end_point.column,
        .severity = .err,
    };
}

fn missingDiagnostic(allocator: std.mem.Allocator, node: ts.Node) !Diagnostic {
    const start_point = node.startPoint();
    const end_point = node.endPoint();
    const token = node.kind();
    const message = try allocator.print("Expected '{s}'", .{token});

    return Diagnostic{
        .message = message,
        .start_line = start_point.row,
        .start_column = start_point.column,
        .end_line = end_point.row,
        .end_column = end_point.column,
        .severity = .err,
    };
}

// Semantic HTML validation
fn validateSemantics(
    allocator: std.mem.Allocator,
    node: ts.Node,
    source: []const u8,
    list: *std.ArrayList(Diagnostic),
    seen_ids: *std.StringHashMapUnmanaged(void),
) AllocError!void {
    switch (Parse.NodeKind.fromNode(node)) {
        .zx_element => try validateElement(allocator, node, source, list, seen_ids),
        .zx_self_closing_element => try validateSelfClosing(allocator, node, source, list, seen_ids),
        else => {},
    }

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        try validateSemantics(allocator, child, source, list, seen_ids);
    }
}

/// Validate a `<tag>...</tag>` element: its start tag name/attributes and the
/// matching end tag (e.g. void elements must not have one).
fn validateElement(
    allocator: std.mem.Allocator,
    node: ts.Node,
    source: []const u8,
    list: *std.ArrayList(Diagnostic),
    seen_ids: *std.StringHashMapUnmanaged(void),
) AllocError!void {
    const start_tag = childOfKind(node, .zx_start_tag) orelse return;
    const name_node = start_tag.childByFieldName("name") orelse return;
    const name = nodeText(name_node, source);

    try validateTagName(allocator, name_node, name, list);
    try validateAttributes(allocator, start_tag, source, list, seen_ids);

    // Void elements must not carry an explicit end tag (`</br>`).
    if (childOfKind(node, .zx_end_tag)) |end_tag| {
        if (isHtmlElement(name) and html.isVoid(name)) {
            const end_name = end_tag.childByFieldName("name") orelse end_tag;
            try appendError(allocator, end_name, list, "void elements have no end tag", .{});
        }
    }
}

/// Validate a `<tag ... />` self-closing element. HTML elements (other than
/// void ones) are not allowed to self-close.
fn validateSelfClosing(
    allocator: std.mem.Allocator,
    node: ts.Node,
    source: []const u8,
    list: *std.ArrayList(Diagnostic),
    seen_ids: *std.StringHashMapUnmanaged(void),
) AllocError!void {
    const name_node = node.childByFieldName("name") orelse return;
    const name = nodeText(name_node, source);

    if (isHtmlElement(name)) {
        // Unknown lowercase tag names are reported as invalid element names.
        try validateTagName(allocator, name_node, name, list);

        // Real HTML elements can't self-close; only void elements, ZX
        // components and custom/SVG elements may use `<x />`.
        if (html.isKnown(name) and !html.isVoid(name) and !html.isSvg(name)) {
            try appendError(allocator, name_node, list, "HTML elements can't self-close", .{});
        }
    }

    try validateAttributes(allocator, node, source, list, seen_ids);
}

/// Report unknown or deprecated HTML tag names.
fn validateTagName(
    allocator: std.mem.Allocator,
    name_node: ts.Node,
    name: []const u8,
    list: *std.ArrayList(Diagnostic),
) AllocError!void {
    if (!isHtmlElement(name)) return;

    if (html.isDeprecated(name)) {
        try appendError(allocator, name_node, list, "'{s}' is deprecated and unsupported", .{name});
    } else if (!html.isKnown(name)) {
        try appendError(allocator, name_node, list, "'{s}' is not a valid HTML element", .{name});
    }
}

/// Validate the attributes of a start tag / self-closing element: detect
/// duplicate attribute names on the same element and duplicate `id` values
/// across the document.
fn validateAttributes(
    allocator: std.mem.Allocator,
    tag: ts.Node,
    source: []const u8,
    list: *std.ArrayList(Diagnostic),
    seen_ids: *std.StringHashMapUnmanaged(void),
) AllocError!void {
    var seen_attrs: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_attrs.deinit(allocator);

    const child_count = tag.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = tag.child(i) orelse continue;
        if (Parse.NodeKind.fromNode(child) != .zx_attribute) continue;

        const attr = child.child(0) orelse continue;
        // Only plain `name`/`name="value"` attributes have a comparable name;
        // shorthand/spread/builtin forms are skipped here.
        switch (Parse.NodeKind.fromNode(attr)) {
            .zx_regular_attribute, .zx_builtin_attribute => {},
            .zx_builtin_shorthand_attribute => {
                try validateBuiltinShorthand(allocator, attr, source, list);
                continue;
            },
            else => continue,
        }

        const name_node = attr.childByFieldName("name") orelse continue;
        const name = nodeText(name_node, source);
        if (name.len == 0) continue;

        if (Parse.NodeKind.fromNode(attr) == .zx_builtin_attribute) {
            try validateBuiltin(allocator, attr, name_node, name, list);
        }

        const gop = try seen_attrs.getOrPut(allocator, name);
        if (gop.found_existing) {
            try appendDiagnostic(allocator, name_node, list, .warning, "duplicate attribute '{s}'", .{name});
            continue;
        }

        // Duplicate id detection across the whole document.
        if (std.ascii.eqlIgnoreCase(name, "id")) {
            if (attr.childByFieldName("value")) |value_node| {
                if (attributeValueText(value_node, source)) |id_value| {
                    if (id_value.len > 0) {
                        const id_gop = try seen_ids.getOrPut(allocator, id_value);
                        if (id_gop.found_existing) {
                            // Warning, not error: duplicate ids are invalid
                            try appendDiagnostic(allocator, value_node, list, .warning, "duplicate id '{s}'", .{id_value});
                        }
                    }
                }
            }
        }
    }
}

/// A name is treated as an HTML element (subject to HTML rules) when it is not
/// a ZX component (uppercase) or custom element (contains '-').
fn isHtmlElement(name: []const u8) bool {
    return name.len > 0 and !html.isCustomOrComponent(name);
}

fn validateBuiltin(
    allocator: std.mem.Allocator,
    attr: ts.Node,
    name_node: ts.Node,
    name: []const u8,
    list: *std.ArrayList(Diagnostic),
) AllocError!void {
    if (!builtins.isKnown(name)) {
        if (std.ascii.eqlIgnoreCase(name, "@rendering")) {
            return appendDiagnostic(allocator, name_node, list, .err, "'@rendering' was replaced by '@client'", .{});
        }
        return appendDiagnostic(allocator, name_node, list, .err, "unknown ZX builtin attribute '{s}'", .{name});
    }

    const has_value = attr.childByFieldName("value") != null;
    if (builtins.isFlag(name)) {
        if (has_value) try appendDiagnostic(allocator, name_node, list, .err, "'{s}' takes no value", .{name});
    } else if (!has_value) {
        try appendDiagnostic(allocator, name_node, list, .err, "'{s}' needs a value", .{name});
    }
}

fn validateBuiltinShorthand(
    allocator: std.mem.Allocator,
    attr: ts.Node,
    source: []const u8,
    list: *std.ArrayList(Diagnostic),
) AllocError!void {
    const name_node = attr.childByFieldName("name") orelse return;
    const name = nodeText(name_node, source);
    if (name.len == 0) return;
    if (builtins.isKnownShorthand(name)) return;
    try appendDiagnostic(
        allocator,
        name_node,
        list,
        .err,
        "unknown ZX builtin attribute '@{s}'",
        .{name},
    );
}

fn childOfKind(node: ts.Node, kind: Parse.NodeKind) ?ts.Node {
    const count = node.childCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (Parse.NodeKind.fromNode(child) == kind) return child;
    }
    return null;
}

fn nodeText(node: ts.Node, source: []const u8) []const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start < end and end <= source.len) return source[start..end];
    return "";
}

/// Returns the inner text of an attribute value, stripping a single layer of
/// surrounding quotes when present (e.g. `"foo"` -> `foo`).
fn attributeValueText(value_node: ts.Node, source: []const u8) ?[]const u8 {
    const raw = nodeText(value_node, source);
    if (raw.len >= 2) {
        const first = raw[0];
        const last = raw[raw.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return raw[1 .. raw.len - 1];
        }
    }
    return raw;
}

/// Format `fmt`/`args` into an owned message and append an error diagnostic
/// spanning `node`.
fn appendError(
    allocator: std.mem.Allocator,
    node: ts.Node,
    list: *std.ArrayList(Diagnostic),
    comptime fmt: []const u8,
    args: anytype,
) AllocError!void {
    try appendDiagnostic(allocator, node, list, .err, fmt, args);
}

/// Format `fmt`/`args` into an owned message and append a diagnostic with the
/// given `severity`, spanning `node`.
fn appendDiagnostic(
    allocator: std.mem.Allocator,
    node: ts.Node,
    list: *std.ArrayList(Diagnostic),
    severity: Severity,
    comptime fmt: []const u8,
    args: anytype,
) AllocError!void {
    const start_point = node.startPoint();
    const end_point = node.endPoint();
    const message = try allocator.print(fmt, args);
    errdefer allocator.free(message);
    try list.append(allocator, .{
        .message = message,
        .start_line = start_point.row,
        .start_column = start_point.column,
        .end_line = end_point.row,
        .end_column = end_point.column,
        .severity = severity,
    });
}
