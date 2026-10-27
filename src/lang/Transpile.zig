const Transpile = @This();

const std = @import("std");
const ts = @import("tree_sitter");

const sourcemap = @import("sourcemap.zig");
const Parse = @import("Parse.zig");

const Ast = Parse.Parse;
const NodeKind = Parse.NodeKind;

/// The shape of the transpiled output,
/// changes when the transpiler output format changes.
pub const shape: []const u8 = "0.1.0";

ast: *Ast,
output: std.array_list.Managed(u8),
sourcemap_builder: sourcemap.Builder,
current_line: i32 = 0,
current_column: i32 = 0,
track_mappings: bool,
indent_level: u32 = 0,
/// Source file path relative to the working directory.
file_path: ?[]const u8 = null,
block_counter: u32 = 0,
zx_initialized: bool = false,
zx_name: []const u8 = "_zx",
zx_name_owned: bool = false,
client_components: std.ArrayList(ClientComponentMetadata),
paren_byte: ?u32 = null,
allocator: std.mem.Allocator,

pub const Options = struct {
    sourcemap: bool,
    path: ?[]const u8,
};

pub const ClientComponentMetadata = struct {
    pub const Type = enum { client };

    type: Type,
    name: []const u8,
    path: []const u8,
    id: []const u8,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, path: []const u8, component_type: Type, index: ?usize) !ClientComponentMetadata {
        const generated = generateComponentIdInner(name, path, index);
        const owned_id = try allocator.dupe(u8, generated.buf[0..generated.len]);

        const owned_path = try allocator.dupe(u8, path);
        return .{
            .type = component_type,
            .name = name,
            .path = owned_path,
            .id = owned_id,
        };
    }

    /// Generate a short unique component ID
    /// Format: c<6-char-hash> (e.g., c1a2b3c)
    /// Uses first 6 hex chars of MD5 hash for uniqueness (16M combinations)
    fn generateComponentIdInner(name: []const u8, path: []const u8, index: ?usize) struct { buf: [56]u8, len: usize } {
        var hasher = std.crypto.hash.Md5.init(.{});
        hasher.update(name);
        hasher.update(path);
        if (index) |idx| {
            var idx_buf: [20]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{idx}) catch unreachable;
            hasher.update(idx_str);
        }
        var digest: [16]u8 = undefined;
        hasher.final(&digest);

        var result: [56]u8 = undefined;
        result[0] = 'c';

        // Use first 3 bytes (6 hex chars) for compact but unique ID
        const hex_chars = "0123456789abcdef";
        for (digest[0..3], 0..) |byte, i| {
            result[1 + i * 2] = hex_chars[byte >> 4];
            result[1 + i * 2 + 1] = hex_chars[byte & 0x0f];
        }

        return .{ .buf = result, .len = 7 }; // "c" + 6 hex chars
    }
};

/// Token types that should be skipped during expression block processing
const SkipTokens = enum {
    open_brace,
    close_brace,
    open_paren,
    close_paren,
    other,

    fn from(token: []const u8) SkipTokens {
        if (std.mem.eql(u8, token, "{")) return .open_brace;
        if (std.mem.eql(u8, token, "}")) return .close_brace;
        if (std.mem.eql(u8, token, "(")) return .open_paren;
        if (std.mem.eql(u8, token, ")")) return .close_paren;
        return .other;
    }
};

pub fn init(ast: *Ast, allocator: std.mem.Allocator, options: Options) Transpile {
    var builder = sourcemap.Builder.init(allocator);
    builder.source = options.path orelse "";
    return .{
        .ast = ast,
        .output = std.array_list.Managed(u8).init(allocator),
        .sourcemap_builder = builder,
        .track_mappings = options.sourcemap,
        .file_path = options.path,
        .client_components = std.ArrayList(ClientComponentMetadata).empty,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Transpile) void {
    self.output.deinit();
    self.sourcemap_builder.deinit();
    self.client_components.deinit(self.allocator);
    if (self.zx_name_owned) self.allocator.free(self.zx_name);
}

pub fn run(self: *Transpile) !void {
    try self.transpileNode(self.ast.tree.rootNode());
}

fn write(self: *Transpile, bytes: []const u8) !void {
    try self.output.appendSlice(bytes);
    self.updatePosition(bytes);
}

/// Format and write a short synthesized snippet. Use `{s}` for `zx_name`.
/// Dunder helpers: `"_{s}_children_"` → `__zx_children_` or `__zx1_children_`.
fn print(self: *Transpile, comptime fmt: []const u8, args: anytype) !void {
    var buf: [128]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, fmt, args) catch return error.OutOfMemory;
    try self.write(formatted);
}

fn printM(self: *Transpile, comptime fmt: []const u8, args: anytype, source_byte: u32) !void {
    var buf: [128]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, fmt, args) catch return error.OutOfMemory;
    try self.writeM(formatted, source_byte);
}

fn writeWithMapping(self: *Transpile, bytes: []const u8, source_line: i32, source_column: i32) !void {
    if (self.track_mappings and bytes.len > 0) {
        try self.sourcemap_builder.addMapping(.{
            .generated_line = self.current_line,
            .generated_column = self.current_column,
            .source_line = source_line,
            .source_column = source_column,
        });
    }
    try self.write(bytes);
}

fn writeM(self: *Transpile, bytes: []const u8, source_byte: u32) !void {
    const pos = self.ast.getLineColumn(source_byte);
    try self.writeWithMapping(bytes, pos.line, pos.column);
}

fn addMapping(self: *Transpile, source_byte: u32) !void {
    if (!self.track_mappings) return;
    const pos = self.ast.getLineColumn(source_byte);
    try self.sourcemap_builder.addMapping(.{
        .generated_line = self.current_line,
        .generated_column = self.current_column,
        .source_line = pos.line,
        .source_column = pos.column,
    });
}

fn updatePosition(self: *Transpile, bytes: []const u8) void {
    for (bytes) |byte| {
        if (byte == '\n') {
            self.current_line += 1;
            self.current_column = 0;
        } else {
            self.current_column += 1;
        }
    }
}

fn writeIndent(self: *Transpile) !void {
    const spaces = self.indent_level * 4;
    var i: u32 = 0;
    while (i < spaces) : (i += 1) {
        try self.write(" ");
    }
}

const Cursor = struct {
    line: i32,
    column: i32,
    len: usize,
};

fn saveCursor(self: *const Transpile) Cursor {
    return .{
        .line = self.current_line,
        .column = self.current_column,
        .len = self.output.items.len,
    };
}

fn restoreCursor(self: *Transpile, cursor: Cursor) void {
    self.output.shrinkRetainingCapacity(cursor.len);
    self.current_line = cursor.line;
    self.current_column = cursor.column;
}

pub fn finalizeSourceMap(self: *Transpile) !sourcemap.SourceMap {
    return self.sourcemap_builder.build();
}

fn nextBlockIndex(self: *Transpile) u32 {
    const idx = self.block_counter;
    self.block_counter += 1;
    return idx;
}

fn isZxRelatedIdent(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "_zx") or std.mem.startsWith(u8, name, "__zx");
}

fn zxNameConflicts(candidate: []const u8, used: []const []const u8) bool {
    for (used) |name| {
        if (std.mem.eql(u8, name, candidate)) return true;
        if (name.len > candidate.len and std.mem.startsWith(u8, name, candidate) and name[candidate.len] == '_') return true;

        // Dunder helpers: __zx_children_N / __zx1_list_N
        if (name.len >= candidate.len + 1 and name[0] == '_' and std.mem.startsWith(u8, name[1..], candidate)) {
            if (name.len == candidate.len + 1) return true;
            if (name[candidate.len + 1] == '_') return true;
        }
    }
    return false;
}

fn collectZxRelatedIdents(self: *Transpile, node: ts.Node, list: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
    if (NodeKind.fromNode(node) == .identifier) {
        const name = try self.ast.getNodeText(node);
        if (isZxRelatedIdent(name)) {
            try list.append(self.allocator, name);
        }
    }

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        try self.collectZxRelatedIdents(child, list);
    }
}

fn enclosingFunctionScope(node: ts.Node) ?ts.Node {
    var current: ?ts.Node = node;
    while (current) |n| {
        if (NodeKind.fromNode(n) == .function_declaration) return n;
        current = n.parent();
    }
    return null;
}

/// Collect `_zx*` / `__zx*` identifiers at module scope only (skip function bodies).
fn collectModuleScopeZxIdents(self: *Transpile, node: ts.Node, list: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
    if (NodeKind.fromNode(node) == .function_declaration) return;

    if (NodeKind.fromNode(node) == .identifier) {
        const name = try self.ast.getNodeText(node);
        if (isZxRelatedIdent(name)) {
            try list.append(self.allocator, name);
        }
    }

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        try self.collectModuleScopeZxIdents(child, list);
    }
}

fn pickZxName(allocator: std.mem.Allocator, used: []const []const u8) error{OutOfMemory}!struct { []const u8, bool } {
    if (used.len == 0) return .{ "_zx", false };

    var n: u32 = 0;
    while (n < 10_000) : (n += 1) {
        var buf: [32]u8 = undefined;
        const candidate = if (n == 0)
            "_zx"
        else
            std.fmt.bufPrint(&buf, "_zx{d}", .{n}) catch return error.OutOfMemory;

        if (!zxNameConflicts(candidate, used)) {
            if (n == 0) return .{ "_zx", false };
            return .{ try allocator.dupe(u8, candidate), true };
        }
    }
    return error.OutOfMemory;
}

/// Resolve builder name for the enclosing function, also avoiding module-scope bindings.
/// Prefer `_zx`; on collision with user `_zx` / `_zx_*` / `__zx_*`, use `_zx1`, `_zx2`, …
fn resolveZxNameFor(self: *Transpile, node: ts.Node) error{OutOfMemory}!void {
    if (self.zx_name_owned) {
        self.allocator.free(self.zx_name);
        self.zx_name_owned = false;
    }
    self.zx_name = "_zx";

    var used: std.ArrayList([]const u8) = .empty;
    defer used.deinit(self.allocator);

    // Function-locals (params, captures, locals) + module-scope decls that Zig would shadow.
    if (enclosingFunctionScope(node)) |fn_scope| {
        try self.collectZxRelatedIdents(fn_scope, &used);
    }
    try self.collectModuleScopeZxIdents(self.ast.tree.rootNode(), &used);

    const picked = try pickZxName(self.allocator, used.items);
    self.zx_name = picked[0];
    self.zx_name_owned = picked[1];
}

fn transpileNode(self: *Transpile, node: ts.Node) error{OutOfMemory}!void {
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    const node_kind = NodeKind.fromNode(node);

    // Check if this is a ZX block or return expression that needs special handling
    switch (node_kind) {
        .zx_block => {
            // For inline zx_blocks (not in return statements), just transpile the content
            try self.transpileBlock(node);
            return;
        },
        .return_expression => {
            const has_zx_block = findZxBlockInReturn(node) != null;

            if (has_zx_block) {
                // Special handling for return (ZX)
                try self.transpileReturn(node);
                return;
            }
        },
        .builtin_function => {
            const had_output = try self.transpileBuiltin(node);
            if (had_output)
                return;
        },
        else => {},
    }

    // For regular Zig code, copy as-is with source mapping
    const child_count = node.childCount();
    if (child_count == 0) {
        if (start_byte < end_byte and end_byte <= self.ast.source.len) {
            const text = self.ast.source[start_byte..end_byte];
            try self.writeM(text, start_byte);
        }
        return;
    }

    // Recursively process children
    var current_pos = start_byte;
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_start = child.startByte();
        const child_end = child.endByte();

        if (current_pos < child_start and child_start <= self.ast.source.len) {
            const text = self.ast.source[current_pos..child_start];
            try self.writeM(text, current_pos);
        }

        try self.transpileNode(child);
        current_pos = child_end;
    }

    if (current_pos < end_byte and end_byte <= self.ast.source.len) {
        const text = self.ast.source[current_pos..end_byte];
        try self.writeM(text, current_pos);
    }
}

// @import("component.zx") --> @import("component.zig")
fn transpileBuiltin(self: *Transpile, node: ts.Node) !bool {
    var had_output = false;
    var builtin_identifier: ?[]const u8 = null;
    var import_string: ?[]const u8 = null;

    const child_count = node.childCount();
    var i: u32 = 0;

    // First pass: collect builtin identifier and import string
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);

        switch (child_kind) {
            .builtin_identifier => {
                builtin_identifier = try self.ast.getNodeText(child);
            },
            .arguments => {
                // Look for string inside arguments
                const args_child_count = child.childCount();
                var j: u32 = 0;
                while (j < args_child_count) : (j += 1) {
                    const arg_child = child.child(j) orelse continue;
                    const arg_child_kind = NodeKind.fromNode(arg_child);

                    if (arg_child_kind == .string) {
                        // Get the string with quotes
                        const full_string = try self.ast.getNodeText(arg_child);

                        // Look for string_content inside
                        const string_child_count = arg_child.childCount();
                        var k: u32 = 0;
                        while (k < string_child_count) : (k += 1) {
                            const str_child = arg_child.child(k) orelse continue;
                            const str_child_kind = NodeKind.fromNode(str_child);

                            if (str_child_kind == .string_content) {
                                import_string = try self.ast.getNodeText(str_child);
                                break;
                            }
                        }

                        // If no string_content found, use full_string but strip quotes
                        if (import_string == null and full_string.len >= 2) {
                            import_string = full_string[1 .. full_string.len - 1];
                        }
                        break;
                    }
                }
            },
            else => {},
        }
    }

    // Check if this is @import with a .zx file
    if (builtin_identifier) |ident| {
        if (std.mem.eql(u8, ident, "@import")) {
            if (import_string) |import_path| {
                // Check if it ends with .zx / .mdzx / .md
                if (std.mem.endsWith(u8, import_path, ".zx") or
                    std.mem.endsWith(u8, import_path, ".mdzx") or
                    (std.mem.endsWith(u8, import_path, ".md") and !std.mem.endsWith(u8, import_path, ".mdzx")))
                {
                    // Write @import with transformed path
                    try self.writeM("@import", node.startByte());
                    try self.write("(\"");

                    const ext_len: usize = if (std.mem.endsWith(u8, import_path, ".mdzx"))
                        ".mdzx".len
                    else if (std.mem.endsWith(u8, import_path, ".md"))
                        ".md".len
                    else
                        ".zx".len;
                    const base_path = import_path[0 .. import_path.len - ext_len];
                    try self.write(base_path);
                    try self.write(".zig\")");

                    had_output = true;
                }
            }
        }
    }

    return had_output;
}

fn transpileReturn(self: *Transpile, node: ts.Node) !void {
    // Handle: return (<zx>...</zx>) or return ((<zx>...</zx>))
    // This should NOT initialize _zx here - that's done in the parent block
    const zx_block_node = findZxBlockInReturn(node);

    // Find the parenthesis position if present
    var paren_byte: ?u32 = null;
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) == .parenthesized_expression) {
            // The first child of parenthesized_expression is '('
            const open_paren = child.child(0);
            if (open_paren) |p| {
                if (std.mem.eql(u8, p.kind(), "(")) {
                    paren_byte = p.startByte();
                }
            }
            break;
        }
    }

    if (zx_block_node) |zx_node| {
        // `if (c) return (<a />);` and `x catch return (<a />)` leave no statement
        // slot for the builder declaration, so return a labeled block expression.
        if (!isStatement(node)) {
            try self.writeM("return", node.startByte());
            try self.write(" ");
            try self.transpileBlock(zx_node);
            return;
        }

        // Find the element inside the zx_block
        const zx_child_count = zx_node.childCount();
        var j: u32 = 0;
        while (j < zx_child_count) : (j += 1) {
            const child = zx_node.child(j) orelse continue;
            const child_kind = NodeKind.fromNode(child);

            switch (child_kind) {
                .zx_element, .zx_self_closing_element, .zx_fragment => {
                    // Check if we need to initialize _zx with allocator
                    const allocator_value = try self.getAllocatorAttribute(child);

                    try self.resolveZxNameFor(child);

                    // Synthesized builder init - no source mapping for boilerplate,
                    // but map the allocator expression so Zig errors on it remap to .zx.
                    try self.print("var {s} = @import(\"zx\").x.", .{self.zx_name});
                    // `@src()` is only valid inside a function scope. Module-scope
                    // block level component (e.g. `const x = zx { ... }`) can't use @src so skipping.
                    if (allocator_value) |alloc| {
                        try self.write("allocInit(");
                        try self.writeM(alloc.value, alloc.byte_offset);
                        if (isInFunction(child)) {
                            try self.write(", .{ .src = @src() })");
                        } else {
                            try self.write(", .{})");
                        }
                    } else {
                        if (isInFunction(child)) {
                            try self.write("init(.{ .src = @src() })");
                        } else {
                            try self.write("init(.{})");
                        }
                    }
                    try self.write(";\n");
                    // Mark that _zx is now initialized for nested ZX blocks
                    self.zx_initialized = true;
                    try self.writeIndent();
                    // Map generated `return` to the source `return` keyword
                    try self.writeM("return", node.startByte());
                    try self.write(" ");

                    // Set the paren position for the upcoming element transpilation
                    self.paren_byte = paren_byte;

                    try self.transpileElement(child, true);
                    // Reset the flag after processing the return statement
                    self.zx_initialized = false;
                    return;
                },
                else => {},
            }
        }
    }
}

fn isStatement(node: ts.Node) bool {
    const parent = node.parent() orelse return false;
    return std.mem.eql(u8, parent.kind(), "expression_statement");
}

/// Find zx_block inside return expression (may be wrapped in parenthesized_expression)
fn findZxBlockInReturn(node: ts.Node) ?ts.Node {
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);

        if (child_kind == .zx_block) return child;
        if (child_kind == .parenthesized_expression) {
            if (findZxBlockInReturn(child)) |found| return found;
        }
    }
    return null;
}

fn transpileBlock(self: *Transpile, node: ts.Node) !void {
    // This is for zx_block nodes found inside expressions (not top-level)
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);

        switch (child_kind) {
            .zx_element, .zx_self_closing_element, .zx_fragment => {
                // If _zx is already initialized (e.g., inside a return statement),
                // just transpile the element directly without wrapping
                if (self.zx_initialized) {
                    try self.transpileElement(child, false);
                    return;
                }

                // Otherwise, wrap in a self-contained labeled block with local _zx initialization
                // Get unique block index for this inline ZX expression
                const block_idx = self.nextBlockIndex();
                var idx_buf: [16]u8 = undefined;
                const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{block_idx}) catch unreachable;

                // Check if element has @allocator attribute
                const allocator_value = try self.getAllocatorAttribute(child);

                try self.resolveZxNameFor(child);

                // Generate: _zx_ele_blk_N: { var _zx = …; break :_zx_ele_blk_N …; }
                // (or _zx1_ele_blk_N / var _zx1 when the default name collides)
                try self.print("{s}_ele_blk_", .{self.zx_name});
                try self.write(idx_str);
                try self.write(": {\n");

                self.indent_level += 1;
                try self.writeIndent();
                try self.print("var {s} = @import(\"zx\").x.", .{self.zx_name});
                if (allocator_value) |alloc| {
                    try self.write("allocInit(");
                    try self.writeM(alloc.value, alloc.byte_offset);
                    if (isInFunction(child)) {
                        try self.write(", .{ .src = @src() })");
                    } else {
                        try self.write(", .{})");
                    }
                } else {
                    if (isInFunction(child)) {
                        try self.write("init(.{ .src = @src() })");
                    } else {
                        try self.write("init(.{})");
                    }
                }
                try self.write(";\n");

                try self.writeIndent();
                try self.print("break :{s}_ele_blk_", .{self.zx_name});
                try self.write(idx_str);
                try self.write(" ");
                try self.transpileElement(child, false);
                try self.write(";\n");

                self.indent_level -= 1;
                try self.writeIndent();
                try self.write("}");
                return;
            },
            else => {},
        }
    }
}

/// Allocator expression taken from `@allocator={...}` / `@{allocator}`.
const AllocatorExpr = struct {
    value: []const u8,
    /// Byte offset in .zx source of the expression (for position maps).
    byte_offset: u32,
};

/// Returns the allocator attribute value if found, null otherwise.
fn getAllocatorAttribute(self: *Transpile, node: ts.Node) !?AllocatorExpr {
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);

        // Regular elements like <div>...</div>)
        if (child_kind == .zx_start_tag) {
            const tag_children = child.childCount();
            var j: u32 = 0;
            while (j < tag_children) : (j += 1) {
                const attr = child.child(j) orelse continue;
                if (try self.checkAllocatorAttr(attr)) |value| return value;
            }
        }

        // Self-closing elements (like <Button @allocator={allocator} /> or <Button @{allocator} />)
        if (child_kind == .zx_attribute or child_kind == .zx_builtin_attribute or child_kind == .zx_shorthand_attribute or child_kind == .zx_builtin_shorthand_attribute) {
            if (try self.checkAllocatorAttr(child)) |value| return value;
        }
    }
    return null;
}

fn checkAllocatorAttr(self: *Transpile, attr: ts.Node) !?AllocatorExpr {
    const attr_kind = NodeKind.fromNode(attr);
    if (attr_kind != .zx_attribute and attr_kind != .zx_builtin_attribute and attr_kind != .zx_shorthand_attribute and attr_kind != .zx_builtin_shorthand_attribute) return null;

    const actual_attr = if (attr_kind == .zx_attribute) attr.child(0) orelse return null else attr;
    const actual_kind = NodeKind.fromNode(actual_attr);

    // Regular shorthand attributes can't be @allocator since they don't have @ prefix
    if (actual_kind == .zx_shorthand_attribute) return null;

    // Handle builtin shorthand: @{allocator} -> @allocator={allocator}
    if (actual_kind == .zx_builtin_shorthand_attribute) {
        const name_node = actual_attr.childByFieldName("name") orelse return null;
        const name = try self.ast.getNodeText(name_node);
        if (std.mem.eql(u8, name, "allocator")) {
            return .{ .value = name, .byte_offset = name_node.startByte() };
        }
        return null;
    }

    const name_node = actual_attr.childByFieldName("name") orelse return null;
    const name = try self.ast.getNodeText(name_node);

    if (std.mem.eql(u8, name, "@allocator")) {
        const value_node = actual_attr.childByFieldName("value") orelse {
            // TODO: need to catch and add to errors list in case of no value
            return .{ .value = "allocator", .byte_offset = name_node.startByte() };
        };
        return try self.getAttributeValueExpr(value_node);
    }
    return null;
}

fn transpileElement(self: *Transpile, node: ts.Node, is_root: bool) !void {
    const node_kind = NodeKind.fromNode(node);
    switch (node_kind) {
        .zx_fragment => try self.transpileFragment(node, is_root),
        .zx_self_closing_element => try self.transpileSelfClosing(node, is_root),
        .zx_element => try self.transpileFullElement(node, is_root, false),
        else => unreachable,
    }
}

fn transpileFragment(self: *Transpile, node: ts.Node, is_root: bool) !void {
    _ = is_root;

    // Collect all zx_child nodes from the fragment
    var children = std.ArrayList(ts.Node).empty;
    defer children.deinit(self.output.allocator);

    var end_tag_start_byte: u32 = node.endByte();
    var end_tag_end_byte: u32 = node.endByte();
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const kind = NodeKind.fromNode(child);
        if (kind == .zx_child) {
            try children.append(self.output.allocator, child);
        } else if (kind == .zx_end_tag) {
            end_tag_start_byte = child.startByte();
            end_tag_end_byte = child.endByte();
        }
    }

    // Fragment is just like a regular element but with .fragment tag and no attributes
    try self.print("{s}.ele", .{self.zx_name});
    if (self.paren_byte) |p| {
        try self.writeM("(", p);
        self.paren_byte = null;
    } else {
        try self.write("(");
    }
    try self.write("\n");

    self.indent_level += 1;
    try self.writeIndent();
    // Map both start and end tag to the fragment name for tooltips
    try self.addMapping(end_tag_start_byte);
    try self.writeM(".", node.startByte());
    try self.addMapping(end_tag_start_byte);
    try self.writeM("fragment", node.startByte());
    try self.writeM(",\n", end_tag_start_byte);

    try self.writeIndent();
    try self.write(".{\n");
    self.indent_level += 1;

    // Write children
    if (children.items.len > 0) {
        try self.writeIndent();
        try self.write(".children = ");
        try self.print("{s}.chs(.{{\n", .{self.zx_name});
        self.indent_level += 1;

        for (children.items, 0..) |child, idx| {
            const saved = self.saveCursor();
            try self.writeIndent();
            const is_last_child = idx == children.items.len - 1;
            const had_output = try self.transpileChild(child, false, is_last_child);

            if (had_output) {
                try self.write(",\n");
            } else {
                self.restoreCursor(saved);
            }
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}),\n");
    }

    self.indent_level -= 1;
    try self.writeIndent();
    try self.write("},\n");
    self.indent_level -= 1;

    try self.writeIndent();
    try self.writeM(")", end_tag_end_byte);
}

fn isCustomComponent(tag: []const u8) bool {
    // Namespaced components (e.g., components.Button, icons.GitHub) are always custom
    if (std.mem.indexOfScalar(u8, tag, '.') != null) return true;
    return tag.len > 0 and std.ascii.isUpper(tag[0]);
}

/// Hyphenated tags are web components (not ZX components / HTML enum tags).
fn isWebComponent(tag: []const u8) bool {
    return tag.len > 0 and !isCustomComponent(tag) and std.mem.indexOfScalar(u8, tag, '-') != null;
}

/// Extract the component display name from a tag (part after the last dot, or the full tag)
fn componentDisplayName(tag: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, tag, '.')) |dot_pos| {
        return tag[dot_pos + 1 ..];
    }
    return tag;
}

/// Check if element is a <pre> tag (preserve whitespace but still process children)
fn isPreElement(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "pre");
}

pub const NormalizedText = struct {
    text: []const u8,
    /// Space before `text` when a newline would glue it to a prior `{expr}` or `</tag>`.
    leading_space: bool = false,
};

/// Exported for unit tests; used by transpileChild for HTML-like inline spacing.
pub fn normalizeText(source: []const u8, node_start: u32, node_end: u32) ?NormalizedText {
    if (node_start >= node_end or node_end > source.len) return null;
    const text = source[node_start..node_end];
    if (text.len == 0) return null;

    const preceded_by_newline = node_start > 0 and isNewline(source[node_start - 1]);
    const followed_by_newline = node_end < source.len and isNewline(source[node_end]);

    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        if (std.mem.indexOfAny(u8, text, "\n\r") != null or preceded_by_newline) return null;
        return .{ .text = text };
    }

    const content_start = @intFromPtr(trimmed.ptr) - @intFromPtr(text.ptr);
    const content_end = content_start + trimmed.len;
    const leading = text[0..content_start];
    const trailing = text[content_end..];

    const strip_leading = preceded_by_newline or std.mem.indexOfAny(u8, leading, "\n\r") != null;
    const strip_trailing = followed_by_newline or std.mem.indexOfAny(u8, trailing, "\n\r") != null;

    const start: usize = if (strip_leading) content_start else 0;
    const end: usize = if (strip_trailing) content_end else text.len;
    return .{
        .text = text[start..end],
        .leading_space = strip_leading and continuesInlineSibling(source, node_start),
    };
}

fn isNewline(c: u8) bool {
    return c == '\n' or c == '\r';
}

/// Newline after `{expr}` / `</tag>` → one leading space (HTML-like).
/// Not after open/self-closing/void tags, and not after `{" "}` / `{ }` / `{' '}`.
fn continuesInlineSibling(source: []const u8, node_start: u32) bool {
    var i = node_start;
    while (i > 0 and std.ascii.isWhitespace(source[i - 1])) i -= 1;
    if (i == 0) return false;
    return switch (source[i - 1]) {
        '}' => !exprIsWhitespaceOnly(source, i),
        '>' => isClosingTagEnd(source, i),
        else => false,
    };
}

fn isClosingTagEnd(source: []const u8, end_exclusive: u32) bool {
    if (end_exclusive >= 2 and source[end_exclusive - 2] == '/') return false;
    var j = end_exclusive;
    while (j > 0) {
        j -= 1;
        if (source[j] == '<') return j + 1 < end_exclusive and source[j + 1] == '/';
    }
    return false;
}

fn exprIsWhitespaceOnly(source: []const u8, end_exclusive: u32) bool {
    if (end_exclusive == 0 or source[end_exclusive - 1] != '}') return false;
    var depth: i32 = 0;
    var j = end_exclusive;
    while (j > 0) {
        j -= 1;
        if (source[j] == '}') {
            depth += 1;
        } else if (source[j] == '{') {
            depth -= 1;
            if (depth == 0) {
                const inner = std.mem.trim(u8, source[j + 1 .. end_exclusive - 1], &std.ascii.whitespace);
                if (inner.len == 0) return true;
                if (inner.len >= 2 and (inner[0] == '\'' or inner[0] == '"') and inner[inner.len - 1] == inner[0]) {
                    return std.mem.trim(u8, inner[1 .. inner.len - 1], &std.ascii.whitespace).len == 0;
                }
                return false;
            }
        }
    }
    return false;
}

/// Escape text for use in Zig string literal
fn escapeZigString(self: *Transpile, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '\\' => try self.write("\\\\"),
            '"' => try self.write("\\\""),
            '\n' => try self.write("\\n"),
            '\r' => try self.write("\\r"),
            '\t' => try self.write("\\t"),
            else => try self.write(&[_]u8{c}),
        }
    }
}

fn transpileSelfClosing(self: *Transpile, node: ts.Node, is_root: bool) !void {
    _ = is_root;

    var tag_name: ?[]const u8 = null;
    var tag_name_byte: u32 = node.startByte();
    var attributes = std.ArrayList(ZxAttribute).empty;
    defer attributes.deinit(self.output.allocator);

    // Parse the self-closing element
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;

        switch (NodeKind.fromNode(child)) {
            .zx_tag_name => {
                tag_name = try self.ast.getNodeText(child);
                tag_name_byte = child.startByte();
            },
            .zx_attribute, .zx_builtin_attribute, .zx_regular_attribute, .zx_shorthand_attribute, .zx_builtin_shorthand_attribute, .zx_spread_attribute => {
                const attr = try self.parseAttribute(child);
                if (attr.isValid()) {
                    try attributes.append(self.output.allocator, attr);
                }
            },
            else => {},
        }
    }

    const tag = tag_name orelse return;

    if (isCustomComponent(tag)) {
        try self.writeCustomComponent(node, tag, node.startByte(), node.endByte(), node.endByte(), attributes.items, &.{});
    } else {
        try self.writeHtmlElement(node, tag, node.startByte(), node.endByte(), node.endByte(), attributes.items, &.{}, false, isWebComponent(tag));
    }
}

fn transpileFullElement(self: *Transpile, node: ts.Node, is_root: bool, parent_preserve_whitespace: bool) !void {
    _ = is_root;

    // Parse element structure
    var tag_name: ?[]const u8 = null;
    var tag_name_byte: u32 = node.startByte();
    var attributes = std.ArrayList(ZxAttribute).empty;
    defer attributes.deinit(self.output.allocator);
    var children = std.ArrayList(ts.Node).empty;
    defer children.deinit(self.output.allocator);

    var end_tag_start_byte: u32 = node.endByte();
    var end_tag_end_byte: u32 = node.endByte();

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;

        switch (NodeKind.fromNode(child)) {
            .zx_start_tag => {
                // Parse tag name and attributes from start tag
                const tag_children = child.childCount();
                var j: u32 = 0;
                while (j < tag_children) : (j += 1) {
                    const tag_child = child.child(j) orelse continue;

                    switch (NodeKind.fromNode(tag_child)) {
                        .zx_tag_name => {
                            tag_name = try self.ast.getNodeText(tag_child);
                            tag_name_byte = tag_child.startByte();
                        },
                        .zx_attribute, .zx_builtin_attribute, .zx_regular_attribute, .zx_shorthand_attribute, .zx_builtin_shorthand_attribute, .zx_spread_attribute => {
                            const attr = try self.parseAttribute(tag_child);
                            if (attr.isValid()) {
                                try attributes.append(self.output.allocator, attr);
                            }
                        },
                        else => {},
                    }
                }
            },
            .zx_child => try children.append(self.output.allocator, child),
            .zx_end_tag => {
                end_tag_start_byte = child.startByte();
                end_tag_end_byte = child.endByte();
            },
            else => {},
        }
    }

    const tag = tag_name orelse return;

    // Custom component with children
    if (isCustomComponent(tag)) {
        try self.writeCustomComponent(node, tag, node.startByte(), end_tag_start_byte, end_tag_end_byte, attributes.items, children.items);
        return;
    }

    // Check for <pre> tag - preserve whitespace but still process children normally
    // Also inherit preserve_whitespace from parent (e.g., nested elements inside <pre>)
    const preserve_whitespace = parent_preserve_whitespace or isPreElement(tag);

    // Regular HTML element or web component (with optional whitespace preservation for <pre>)
    try self.writeHtmlElement(node, tag, node.startByte(), end_tag_start_byte, end_tag_end_byte, attributes.items, children.items, preserve_whitespace, isWebComponent(tag));
}

/// Write a custom component with optional client rendering metadata.
fn writeCustomComponent(self: *Transpile, _: ts.Node, tag: []const u8, tag_name_byte: u32, end_tag_start_byte: u32, end_tag_end_byte: u32, attributes: []const ZxAttribute, children: []const ts.Node) error{OutOfMemory}!void {
    // `@client` marks a client-side rendered Zig component.
    var is_client = false;
    for (attributes) |attr| {
        if (attr.is_builtin and std.mem.eql(u8, attr.name, "@client")) {
            is_client = true;
            break;
        }
    }

    // Client components (@client) use _zx.cmp() with client option
    if (is_client) {
        var path_buf: [512]u8 = undefined;
        var full_path: []const u8 = undefined;

        // Client: use file path with .zig extension (relative to cwd)
        if (self.file_path) |fp| {
            // Replace .zx extension with .zig
            if (std.mem.endsWith(u8, fp, ".zx")) {
                const base_len = fp.len - 3;
                const len = base_len + 4; // ".zig" is 4 chars
                if (len <= path_buf.len) {
                    @memcpy(path_buf[0..base_len], fp[0..base_len]);
                    @memcpy(path_buf[base_len..][0..4], ".zig");
                    full_path = path_buf[0..len];
                } else {
                    full_path = fp;
                }
            } else {
                full_path = fp;
            }
        } else {
            full_path = "unknown.zig";
        }

        // Add to client components list (use current list length as stable index)
        const component_index = self.client_components.items.len;
        const client_cmp = try ClientComponentMetadata.init(self.allocator, tag, full_path, .client, component_index);
        try self.client_components.append(self.allocator, client_cmp);

        // Write _zx.cmp(Component, .{ .name = ..., .client = .{ .name = ..., .id = ... } }, .{ props })
        try self.print("{s}.cmp", .{self.zx_name});
        if (self.paren_byte) |p| {
            try self.writeM("(", p);
            self.paren_byte = null;
        } else {
            try self.write("(");
        }
        try self.write("\n");

        self.indent_level += 1;
        try self.writeIndent();
        try self.addMapping(end_tag_start_byte);
        try self.writeM(tag, tag_name_byte);
        try self.writeM(",\n", end_tag_start_byte);

        try self.writeIndent();
        try self.write(".{ .src = @src() },\n");

        try self.writeIndent();
        try self.write(".{ .name = \"");
        try self.write(componentDisplayName(tag));
        try self.write("\", .client = .{ .name = \"");
        try self.write(componentDisplayName(tag));
        // try self.write("\", .path = \"");
        // try self.write(full_path);
        try self.write("\", .id = \"");
        try self.write(client_cmp.id);
        try self.write("\" } },\n");

        try self.writeIndent();
        try self.write(".{");

        // Write props (non-builtin attributes)
        var first_prop = true;
        for (attributes) |attr| {
            if (attr.is_builtin) continue;
            if (!first_prop) try self.write(",");
            first_prop = false;

            try self.write("\n");
            self.indent_level += 1;
            try self.writeIndent();
            try self.write(".");
            try self.writeM(attr.name, attr.name_byte_offset);
            try self.write(" = ");
            // Handle template strings, zx_blocks, and regular values
            if (attr.template_string_node) |template_node| {
                try self.transpileTemplateStringProp(template_node);
            } else if (attr.zx_block_node) |zx_node| {
                try self.transpileBlock(zx_node);
            } else {
                try self.writeM(attr.value, attr.value_byte_offset);
            }
            self.indent_level -= 1;
        }

        if (!first_prop) {
            try self.write("\n");
            try self.writeIndent();
        }
        try self.write("},\n");

        self.indent_level -= 1;
        try self.writeIndent();
        try self.writeM(")", end_tag_end_byte);
        return;
    }

    {
        // Regular cmp component: _zx.cmp(Func, .{ .name = ..., options }, .{ props })
        try self.print("{s}.cmp", .{self.zx_name});
        if (self.paren_byte) |p| {
            try self.writeM("(", p);
            self.paren_byte = null;
        } else {
            try self.write("(");
        }
        try self.write("\n");

        self.indent_level += 1;
        try self.writeIndent();
        try self.addMapping(end_tag_start_byte);
        try self.writeM(tag, tag_name_byte);
        try self.writeM(",\n", end_tag_start_byte);

        try self.writeIndent();
        try self.write(".{ .src = @src() },\n");

        var spreads = std.ArrayList(ZxAttribute).empty;
        defer spreads.deinit(self.output.allocator);
        var regular_props = std.ArrayList(ZxAttribute).empty;
        defer regular_props.deinit(self.output.allocator);
        var builtin_attrs = std.ArrayList(ZxAttribute).empty;
        defer builtin_attrs.deinit(self.output.allocator);

        for (attributes) |attr| {
            if (attr.is_builtin) {
                // Collect builtin attributes for the options parameter
                try builtin_attrs.append(self.output.allocator, attr);
                continue;
            }
            if (attr.is_spread) {
                try spreads.append(self.output.allocator, attr);
            } else {
                try regular_props.append(self.output.allocator, attr);
            }
        }

        const has_spread = spreads.items.len > 0;
        const has_regular_props = regular_props.items.len > 0;
        const has_children = children.len > 0;

        // Write options parameter (name + builtin attributes)
        try self.writeIndent();
        try self.write(".{ .name = \"");
        try self.write(componentDisplayName(tag));
        try self.write("\"");
        try self.writeComponentBuiltinOptions(builtin_attrs.items, true);
        try self.write(" },\n");

        // Case 1: Single spread
        if (spreads.items.len == 1 and !has_regular_props and !has_children) {
            try self.writeIndent();
            try self.writeM(spreads.items[0].value, spreads.items[0].value_byte_offset);
            try self.write("\n");
        }
        // Case 2: Multiple spreads with other props or children - use propsM
        else if (has_spread) {
            try self.writeIndent();
            var need_merge = false;
            if (spreads.items.len > 0) {
                try self.print("{s}.propsM(", .{self.zx_name});
                try self.writeM(spreads.items[0].value, spreads.items[0].value_byte_offset);
                need_merge = true;
            }

            for (spreads.items[1..]) |spread| {
                try self.write(", ");
                try self.writeM(spread.value, spread.value_byte_offset);
            }

            if (has_regular_props or has_children) {
                if (need_merge) try self.write(", ");
                try self.write(".{");

                var first_prop = true;
                for (regular_props.items) |attr| {
                    if (!first_prop) try self.write(",");
                    first_prop = false;

                    try self.write("\n");
                    self.indent_level += 1;
                    try self.writeIndent();
                    try self.write(".");
                    try self.writeM(attr.name, attr.name_byte_offset);
                    try self.write(" = ");
                    // Handle template strings, zx_blocks, and regular values
                    if (attr.template_string_node) |template_node| {
                        try self.transpileTemplateStringProp(template_node);
                    } else if (attr.zx_block_node) |zx_node| {
                        try self.transpileBlock(zx_node);
                    } else {
                        try self.writeM(attr.value, attr.value_byte_offset);
                    }
                    self.indent_level -= 1;
                }

                // Add children prop
                if (has_children) {
                    if (!first_prop) try self.write(",");
                    try self.write("\n");
                    self.indent_level += 1;
                    try self.writeIndent();
                    try self.write(".children = ");
                    try self.writeChildrenValue(children);
                    self.indent_level -= 1;
                }

                if (!first_prop) {
                    try self.write("\n");
                    try self.writeIndent();
                }
                try self.write("}");
            }

            if (need_merge) try self.write(")");
            try self.write("\n");
        }
        // Case 3: Regular attrs
        else {
            try self.writeIndent();
            try self.write(".{");

            var first_prop = true;
            for (regular_props.items) |attr| {
                if (!first_prop) try self.write(",");
                first_prop = false;

                try self.write("\n");
                self.indent_level += 1;
                try self.writeIndent();
                try self.write(".");
                try self.writeM(attr.name, attr.name_byte_offset);
                try self.write(" = ");
                // Handle template strings, zx_blocks, and regular values
                if (attr.template_string_node) |template_node| {
                    try self.transpileTemplateStringProp(template_node);
                } else if (attr.zx_block_node) |zx_node| {
                    try self.transpileBlock(zx_node);
                } else {
                    try self.writeM(attr.value, attr.value_byte_offset);
                }
                self.indent_level -= 1;
            }

            // Add children prop
            if (has_children) {
                if (!first_prop) try self.write(",");
                try self.write("\n");
                self.indent_level += 1;
                try self.writeIndent();
                try self.write(".children = ");
                try self.writeChildrenValue(children);
                self.indent_level -= 1;
            }

            if (!first_prop) {
                try self.write("\n");
                try self.writeIndent();
            }
            try self.write("}\n");
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.writeM(",)", end_tag_end_byte);
    }
}

/// Write builtin options for component (cmp) calls.
/// `has_prior_field` should be true when a field (e.g. `.name`) was already written
/// so the first builtin attr is prefixed with a comma separator.
fn writeComponentBuiltinOptions(self: *Transpile, builtin_attrs: []const ZxAttribute, has_prior_field: bool) !void {
    var first = !has_prior_field;
    for (builtin_attrs) |attr| {
        // Skip @client which is handled separately for CSR components
        if (std.mem.eql(u8, attr.name, "@client")) continue;
        // Skip @allocator which is not relevant for components
        if (std.mem.eql(u8, attr.name, "@allocator")) continue;

        if (!first) try self.write(",");
        first = false;

        // Map attribute names to Zig field names
        if (std.mem.eql(u8, attr.name, "@async")) {
            try self.write(" .@\"async\" = ");
        } else if (std.mem.eql(u8, attr.name, "@fallback")) {
            try self.print(" .fallback = {s}.ptr(", .{self.zx_name});
        } else if (std.mem.eql(u8, attr.name, "@caching")) {
            try self.write(" .caching = ");
            // If it's a string value (not a zx_block), wrap with comptime .tag()
            if (attr.zx_block_node == null) {
                try self.write("comptime .tag(");
                try self.writeM(attr.value, attr.value_byte_offset);
                try self.write(")");
                continue;
            }
        } else {
            try self.write(" .");
            const name = if (attr.name[0] == '@') attr.name[1..] else attr.name;
            try self.writeM(name, attr.name_byte_offset);
            try self.write(" = ");
        }

        // Write the value
        if (attr.zx_block_node) |zx_node| {
            try self.transpileBlock(zx_node);
        } else {
            try self.writeM(attr.value, attr.value_byte_offset);
        }

        // Close the ptr() wrapper for @fallback
        if (std.mem.eql(u8, attr.name, "@fallback")) {
            try self.write(")");
        }
    }
}

fn writeChildrenValue(self: *Transpile, children: []const ts.Node) !void {
    if (children.len == 1) {
        _ = try self.transpileChild(children[0], false, true);
    } else {
        try self.print("{s}.ele(.fragment, .{{ .children = {s}.chs(.{{", .{ self.zx_name, self.zx_name });
        for (children, 0..) |child, idx| {
            const saved = self.saveCursor();
            const had_output = try self.transpileChild(child, false, idx == children.len - 1);
            if (had_output) {
                try self.write(", ");
            } else {
                self.restoreCursor(saved);
            }
        }
        try self.write("}) })");
    }
}

/// Write a regular HTML element: _zx.ele(.tag, .{ ... })
/// Web components: _zx.ele(.custom, .{ .custom_tag = "my-button", ... })
/// When preserve_whitespace is true (e.g. for <pre>), text nodes won't be trimmed
fn writeHtmlElement(self: *Transpile, node: ts.Node, tag: []const u8, tag_name_byte: u32, end_tag_start_byte: u32, end_tag_end_byte: u32, attributes: []const ZxAttribute, children: []const ts.Node, preserve_whitespace: bool, is_web_component: bool) !void {
    const in_function = isInFunction(node);
    // _zx.ele( is synthesized - no source mapping
    try self.print("{s}.ele", .{self.zx_name});
    if (self.paren_byte) |p| {
        try self.writeM("(", p);
        self.paren_byte = null;
    } else {
        try self.write("(");
    }
    try self.write("\n");

    self.indent_level += 1;
    try self.writeIndent();
    // Map both start and end tags to the tag name for tooltips
    try self.addMapping(end_tag_start_byte);
    try self.writeM(".", tag_name_byte);
    try self.addMapping(end_tag_start_byte);
    if (is_web_component) {
        try self.writeM("custom", tag_name_byte);
    } else {
        try self.writeM(tag, tag_name_byte);
    }
    try self.writeM(",\n", end_tag_start_byte);

    // Write options struct
    try self.writeIndent();
    try self.write(".{\n");
    self.indent_level += 1;

    if (is_web_component) {
        try self.writeIndent();
        try self.write(".custom_tag = \"");
        try self.escapeZigString(tag);
        try self.write("\",\n");
    }

    try self.writeAttributes(attributes, in_function);

    // Write children
    if (children.len > 0) {
        try self.writeIndent();
        try self.write(".children = ");
        try self.print("{s}.chs(.{{\n", .{self.zx_name});
        self.indent_level += 1;

        for (children, 0..) |child, idx| {
            const saved = self.saveCursor();
            try self.writeIndent();
            const is_last_child = idx == children.len - 1;
            const had_output = try self.transpileChild(child, preserve_whitespace, is_last_child);

            if (had_output) {
                try self.write(",\n");
            } else {
                self.restoreCursor(saved);
            }
        }

        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}),\n");
    }

    self.indent_level -= 1;
    try self.writeIndent();
    try self.write("},\n");
    self.indent_level -= 1;

    try self.writeIndent();
    try self.writeM(")", end_tag_end_byte);
}

/// Transpile a child node. When preserve_whitespace is true (e.g. inside <pre>),
/// text nodes are not trimmed and whitespace is preserved exactly.
/// is_last_child indicates if this is the last child in the parent (used for newline handling in <pre>).
fn transpileChild(self: *Transpile, node: ts.Node, preserve_whitespace: bool, is_last_child: bool) error{OutOfMemory}!bool {
    // Returns true if any output was generated, false otherwise
    // zx_child can be: zx_element, zx_self_closing_element, zx_fragment, zx_expression_block, zx_text
    const child_count = node.childCount();
    if (child_count == 0) return false;

    // Get the actual child content (zx_child is a wrapper)
    var had_output = false;
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;

        switch (NodeKind.fromNode(child)) {
            .zx_text => {
                if (preserve_whitespace) {
                    // For <pre> and similar: preserve whitespace exactly
                    // Add \n at end of each text node except the last child
                    const text = try self.ast.getNodeText(child);
                    if (text.len == 0) continue;

                    try self.printM("{s}.txt(\"", .{self.zx_name}, child.startByte());
                    try self.escapeZigString(text);
                    // Add newline at end unless this is the last child
                    if (!is_last_child) try self.write("\\n");
                    try self.write("\")");
                    had_output = true;
                } else {
                    const normalized = normalizeText(self.ast.source, child.startByte(), child.endByte()) orelse continue;

                    try self.printM("{s}.txt(\"", .{self.zx_name}, child.startByte());
                    if (normalized.leading_space) try self.write(" ");
                    try self.escapeZigString(normalized.text);
                    try self.write("\")");
                    had_output = true;
                }
            },
            .zx_expression_block => {
                try self.transpileExprBlock(child);
                had_output = true;
            },
            .zx_element => {
                // Pass preserve_whitespace to nested elements (e.g., elements inside <pre>)
                try self.transpileFullElement(child, false, preserve_whitespace);
                had_output = true;
            },
            .zx_self_closing_element => {
                try self.transpileSelfClosing(child, false);
                had_output = true;
            },
            .zx_fragment => {
                try self.transpileFragment(child, false);
                had_output = true;
            },
            else => {},
        }
    }
    return had_output;
}

fn transpileExprBlock(self: *Transpile, node: ts.Node) error{OutOfMemory}!void {
    // zx_expression_block is: '{' expression '}'
    // We need to extract the expression and handle special cases
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();

        // Handle token types (braces and parentheses)
        switch (SkipTokens.from(child_type)) {
            .open_brace, .close_brace => continue,
            .open_paren, .close_paren => {
                try self.write(child_type);
                continue;
            },
            .other => {},
        }

        // Handle control flow and special expressions
        switch (NodeKind.fromNode(child)) {
            .if_expression => {
                try self.transpileIf(child);
                continue;
            },
            .for_expression => {
                try self.transpileFor(child);
                continue;
            },
            .while_expression => {
                try self.transpileWhile(child);
                continue;
            },
            .switch_expression => {
                try self.transpileSwitch(child);
                continue;
            },
            .multiline_string => {
                try self.transpileMultilineString(child);
                continue;
            },
            else => {},
        }

        // Regular expression handling
        const expr_text = try self.ast.getNodeText(child);
        const trimmed = std.mem.trim(u8, expr_text, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Regular expression like {user.name}
        try self.printM("{s}.expr(", .{self.zx_name}, child.startByte());
        try self.writeM(trimmed, child.startByte());
        try self.write(")");
    }
}

/// Transpile multiline string expression with proper formatting
fn transpileMultilineString(self: *Transpile, node: ts.Node) !void {
    const expr_text = try self.ast.getNodeText(node);

    // Write _zx.expr( followed by newline
    try self.printM("{s}.expr(", .{self.zx_name}, node.startByte());
    try self.write("\n");

    self.indent_level += 1;

    // Split by newlines and write each line with proper indentation
    var lines = std.mem.splitScalar(u8, expr_text, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trimStart(u8, line, " \t");
        if (trimmed_line.len == 0) continue;

        try self.writeIndent();
        try self.write(trimmed_line);
        try self.write("\n");
    }

    self.indent_level -= 1;

    // Write closing paren with proper indentation
    try self.writeIndent();
    try self.write(")");
}

fn transpileIf(self: *Transpile, node: ts.Node) !void {
    // if_expression: 'if' '(' condition ')' [payload] then_expr ['else' [else_payload] else_expr]
    var condition_node: ?ts.Node = null;
    var payload_node: ?ts.Node = null;
    var else_payload_node: ?ts.Node = null;
    var then_node: ?ts.Node = null;
    var else_node: ?ts.Node = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    var in_condition = false;
    var in_then = false;
    var in_else = false;

    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        const child_kind = NodeKind.fromNode(child);

        if (std.mem.eql(u8, child_type, "if")) {
            in_condition = true;
        } else if (std.mem.eql(u8, child_type, "(") and in_condition) {
            // Start of condition
        } else if (std.mem.eql(u8, child_type, ")") and in_condition) {
            in_condition = false;
            in_then = true;
        } else if (std.mem.eql(u8, child_type, "else")) {
            in_then = false;
            in_else = true;
        } else if (in_condition and condition_node == null) {
            condition_node = child;
        } else if (in_then and child_kind == .payload) {
            payload_node = child;
        } else if (in_then and then_node == null) {
            then_node = child;
        } else if (in_else and child_kind == .payload) {
            else_payload_node = child;
        } else if (in_else and else_node == null) {
            else_node = child;
        }
    }

    const cond_n = condition_node orelse return;
    const then_n = then_node orelse return;
    const cond = try self.ast.getNodeText(cond_n);

    try self.writeM("if", node.startByte());
    try self.write(" ");

    // Write condition - ensure wrapped in parens; map to the condition span.
    const cond_trimmed = std.mem.trim(u8, cond, &std.ascii.whitespace);
    if (cond_trimmed.len > 0 and cond_trimmed[0] == '(' and cond_trimmed[cond_trimmed.len - 1] == ')') {
        try self.writeM(cond_trimmed, cond_n.startByte());
    } else {
        try self.write("(");
        try self.writeM(cond_trimmed, cond_n.startByte());
        try self.write(")");
    }
    try self.write(" ");

    // Write payload if present (e.g., |un|)
    if (payload_node) |payload_n| {
        try self.writeM(try self.ast.getNodeText(payload_n), payload_n.startByte());
        try self.write(" ");
    }

    // Handle then branch
    try self.transpileBranch(then_n);

    // Handle else branch
    if (else_node) |else_n| {
        try self.write(" else ");
        if (else_payload_node) |else_payload_n| {
            try self.writeM(try self.ast.getNodeText(else_payload_n), else_payload_n.startByte());
            try self.write(" ");
        }
        try self.transpileBranch(else_n);
    } else {
        try self.print(" else {s}.ele(.fragment, .{{}})", .{self.zx_name});
    }
}

/// Helper to transpile if/else branches consistently
fn transpileBranch(self: *Transpile, node: ts.Node) error{OutOfMemory}!void {
    switch (NodeKind.fromNode(node)) {
        .zx_block => try self.transpileBlock(node),
        .if_expression => try self.transpileIf(node), // Handle else-if chains
        .parenthesized_expression => {
            try self.print("{s}.ele(.fragment, .{{ .children = {s}.chs(.{{\n", .{ self.zx_name, self.zx_name });
            try self.transpileExprBlock(node);
            try self.write(",}),},)");
        },
        else => {
            try self.print("{s}.txt(", .{self.zx_name});
            try self.writeM(try self.ast.getNodeText(node), node.startByte());
            try self.write(")");
        },
    }
}

fn transpileFor(self: *Transpile, node: ts.Node) !void {
    // for_expression: 'for' '(' iterable ')' payload body
    var iterables = std.ArrayList(ts.Node).empty;
    defer iterables.deinit(self.allocator);
    var first_iterable_node: ?ts.Node = null;
    var payload_node: ?ts.Node = null;
    var body_node: ?ts.Node = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    var seen_for = false;
    var seen_payload = false;

    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        const child_kind = NodeKind.fromNode(child);

        if (std.mem.eql(u8, child_type, "for")) {
            seen_for = true;
            continue;
        }

        // Skip parentheses
        if (SkipTokens.from(child_type) != .other) continue;

        if (seen_for and !seen_payload) {
            if (child_kind == .payload) {
                payload_node = child;
                seen_payload = true;
                continue;
            }

            if (first_iterable_node == null) first_iterable_node = child;
            if (!std.mem.eql(u8, child_type, ",")) {
                try iterables.append(self.allocator, child);
            }
            continue;
        }

        switch (child_kind) {
            .zx_block, .parenthesized_expression => {
                body_node = child;
            },
            else => {},
        }
    }

    if (first_iterable_node != null and payload_node != null and body_node != null) {
        // Get unique index for this block to avoid conflicts with nested loops
        const block_idx = self.nextBlockIndex();
        var idx_buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{block_idx}) catch unreachable;

        try self.print("{s}_for_blk_", .{self.zx_name});
        try self.write(idx_str);
        try self.write(": {\n");
        self.indent_level += 1;
        try self.writeIndent();
        try self.print("const _{s}_children_", .{self.zx_name});
        try self.write(idx_str);
        try self.print(" = {s}.getAlloc().alloc(@import(\"zx\").Component, ", .{self.zx_name});
        if (NodeKind.fromNode(first_iterable_node) == .range_expression) {
            const left_node = first_iterable_node.?.childByFieldName("left").?;
            const right_node = first_iterable_node.?.childByFieldName("right").?;
            try self.writeM(try self.ast.getNodeText(right_node), right_node.startByte());
            try self.write(" - ");
            try self.writeM(try self.ast.getNodeText(left_node), left_node.startByte());
        } else {
            try self.writeM(try self.ast.getNodeText(first_iterable_node.?), first_iterable_node.?.startByte());
            try self.write(".len");
        }
        try self.write(") catch unreachable;\n");
        try self.writeIndent();
        try self.write("for (");
        for (iterables.items, 0..) |it, it_idx| {
            if (it_idx > 0) try self.write(", ");
            try self.writeM(try self.ast.getNodeText(it), it.startByte());
        }
        try self.write(", 0..) |");

        // Extract just the variable name from payload (remove pipes)
        const payload = try self.ast.getNodeText(payload_node.?);
        const payload_clean = if (std.mem.startsWith(u8, payload, "|") and std.mem.endsWith(u8, payload, "|"))
            payload[1 .. payload.len - 1]
        else
            payload;

        try self.writeM(payload_clean, payload_node.?.startByte());
        try self.print(", {s}_i_", .{self.zx_name});
        try self.write(idx_str);
        try self.write("| {\n");

        self.indent_level += 1;
        try self.writeIndent();
        try self.print("_{s}_children_", .{self.zx_name});
        try self.write(idx_str);
        try self.print("[{s}_i_", .{self.zx_name});
        try self.write(idx_str);
        try self.write("] = ");
        try self.transpileBranch(body_node.?);
        try self.write(";\n");
        self.indent_level -= 1;

        try self.writeIndent();
        try self.write("}\n");

        try self.writeIndent();
        try self.print("break :{s}_for_blk_", .{self.zx_name});
        try self.write(idx_str);
        try self.print(" {s}.ele(.fragment, .{{ .children = _{s}_children_", .{ self.zx_name, self.zx_name });
        try self.write(idx_str);
        try self.write(" });\n");

        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}");
    }
}

fn transpileWhile(self: *Transpile, node: ts.Node) !void {
    // while_expression: 'while' '(' condition ')' [payload] ':' '(' continue_expr ')' body ['else' [else_payload] else_body]
    var condition_node: ?ts.Node = null;
    var payload_node: ?ts.Node = null;
    var continue_node: ?ts.Node = null;
    var body_node: ?ts.Node = null;
    var else_payload_node: ?ts.Node = null;
    var else_node: ?ts.Node = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    var in_body = false;
    var in_else = false;

    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();
        const field_name = node.fieldNameForChild(i);

        // Check for condition field
        if (field_name) |name| {
            if (std.mem.eql(u8, name, "condition")) {
                condition_node = child;
                i += 1;
                continue;
            }
        }

        if (std.mem.eql(u8, child_type, "else")) {
            in_body = false;
            in_else = true;
            continue;
        }

        const child_kind = NodeKind.fromNode(child);
        switch (child_kind) {
            .payload => {
                if (in_else) {
                    else_payload_node = child;
                } else if (body_node == null) {
                    payload_node = child;
                    in_body = true;
                }
            },
            .assignment_expression => {
                continue_node = child;
            },
            .zx_block => {
                if (in_else) {
                    else_node = child;
                } else {
                    body_node = child;
                    in_body = true;
                }
            },
            else => {},
        }
    }

    if (condition_node != null and body_node != null) {
        // Get unique index for this block to avoid conflicts with nested loops
        const block_idx = self.nextBlockIndex();
        var idx_buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{block_idx}) catch unreachable;

        // Generate: _zx_whl_blk_N: { var __zx_list_N = std.ArrayList(@import("zx").Component).init(_zx.getAlloc()); while (cond) |payload| : (cont) { __zx_list_N.append(...); } else |err| { ... }; break :_zx_whl_blk_N ...; }
        try self.printM("{s}_whl_blk_", .{self.zx_name}, node.startByte());
        try self.write(idx_str);
        try self.write(": {\n");

        self.indent_level += 1;
        try self.writeIndent();
        try self.print("var _{s}_list_", .{self.zx_name});
        try self.write(idx_str);
        try self.write(" = @import(\"std\").ArrayList(@import(\"zx\").Component).empty;\n");

        try self.writeIndent();
        try self.writeM("while", node.startByte());
        try self.write(" (");
        try self.writeM(try self.ast.getNodeText(condition_node.?), condition_node.?.startByte());
        try self.write(")");

        // Write payload if present (e.g., |value|)
        if (payload_node) |payload_n| {
            try self.write(" ");
            try self.writeM(try self.ast.getNodeText(payload_n), payload_n.startByte());
        }

        if (continue_node) |cont_n| {
            try self.write(" : (");
            try self.writeM(std.mem.trim(u8, try self.ast.getNodeText(cont_n), &std.ascii.whitespace), cont_n.startByte());
            try self.write(")");
        }

        try self.write(" {\n");

        self.indent_level += 1;
        try self.writeIndent();
        try self.print("_{s}_list_", .{self.zx_name});
        try self.write(idx_str);
        try self.print(".append({s}.getAlloc(), ", .{self.zx_name});
        try self.transpileBlock(body_node.?);
        try self.write(") catch unreachable;\n");
        self.indent_level -= 1;

        try self.writeIndent();
        try self.write("}");

        // Handle else branch - append to list instead of breaking
        if (else_node) |else_n| {
            try self.write(" else ");
            if (else_payload_node) |else_payload_n| {
                try self.writeM(try self.ast.getNodeText(else_payload_n), else_payload_n.startByte());
                try self.write(" ");
            }
            try self.write("{\n");
            self.indent_level += 1;
            try self.writeIndent();
            try self.print("_{s}_list_", .{self.zx_name});
            try self.write(idx_str);
            try self.print(".append({s}.getAlloc(), ", .{self.zx_name});
            try self.transpileBranch(else_n);
            try self.write(") catch unreachable;\n");
            self.indent_level -= 1;
            try self.writeIndent();
            try self.write("}\n");
        } else {
            try self.write("\n");
        }

        try self.writeIndent();
        try self.print("break :{s}_whl_blk_", .{self.zx_name});
        try self.write(idx_str);
        try self.print(" {s}.ele(.fragment, .{{ .children = _{s}_list_", .{ self.zx_name, self.zx_name });
        try self.write(idx_str);
        try self.write(".items });\n");

        self.indent_level -= 1;
        try self.writeIndent();
        try self.write("}");
    }
}

fn transpileSwitch(self: *Transpile, node: ts.Node) error{OutOfMemory}!void {
    // switch_expression: 'switch' '(' expr ')' '{' switch_case... '}'
    var switch_expr_node: ?ts.Node = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    var found_switch = false;

    // Find the switch expression
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_type = child.kind();

        if (std.mem.eql(u8, child_type, "switch")) {
            found_switch = true;
            continue;
        }

        // Skip delimiters
        if (SkipTokens.from(child_type) != .other) continue;

        if (found_switch and switch_expr_node == null) {
            switch_expr_node = child;
            break;
        }
    }

    const expr_n = switch_expr_node orelse return;

    try self.writeM("switch", node.startByte());
    try self.write(" (");
    try self.writeM(try self.ast.getNodeText(expr_n), expr_n.startByte());
    try self.write(") {\n");

    self.indent_level += 1;

    // Parse switch cases
    i = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) == .switch_case) {
            try self.transpileCase(child);
        }
    }

    self.indent_level -= 1;
    try self.writeIndent();
    try self.write("}");
}

fn transpileCase(self: *Transpile, node: ts.Node) error{OutOfMemory}!void {
    // switch_case structure: pattern [payload] '=>' value
    try self.writeIndent();

    var first_pattern: ?ts.Node = null;
    var last_pattern: ?ts.Node = null;
    var payload_node: ?ts.Node = null;
    var value_node: ?ts.Node = null;
    var seen_arrow = false;

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = child.kind();

        if (std.mem.eql(u8, child_kind, "=>")) {
            seen_arrow = true;
        } else if (std.mem.eql(u8, child_kind, "payload")) {
            payload_node = child;
        } else if (!seen_arrow) {
            if (!std.mem.eql(u8, child_kind, ",")) {
                if (first_pattern == null) first_pattern = child;
                last_pattern = child;
            }
        } else if (seen_arrow and value_node == null) {
            value_node = child;
        }
    }

    if (first_pattern != null and last_pattern != null) {
        const start = first_pattern.?.startByte();
        const end = last_pattern.?.endByte();
        try self.writeM(self.ast.source[start..end], start);
    }

    try self.write(" => ");

    if (payload_node) |pl| {
        try self.write(" ");
        try self.writeM(try self.ast.getNodeText(pl), pl.startByte());
    }

    if (value_node) |v| {
        try self.transpileCaseValue(v);
    }

    try self.write(",\n");
}

/// Transpile switch case value, handling parenthesized expressions with nested control flow/zx
fn transpileCaseValue(self: *Transpile, node: ts.Node) !void {
    const kind = NodeKind.fromNode(node);

    switch (kind) {
        .zx_block => try self.transpileBlock(node),
        .if_expression => try self.transpileIf(node),
        .for_expression => try self.transpileFor(node),
        .while_expression => try self.transpileWhile(node),
        .switch_expression => try self.transpileSwitch(node),
        .string => {
            // String literal without parentheses like "Admin" -> _zx.txt("Admin")
            try self.printM("{s}.txt(", .{self.zx_name}, node.startByte());
            try self.writeM(try self.ast.getNodeText(node), node.startByte());
            try self.write(")");
        },
        .parenthesized_expression => {
            // Check if contains control flow or zx_block
            if (findSpecialChild(node)) |child| {
                try self.transpileCaseValue(child);
            } else {
                // Simple parenthesized expression like ("Admin")
                try self.printM("{s}.txt", .{self.zx_name}, node.startByte());
                try self.writeM(try self.ast.getNodeText(node), node.startByte());
            }
        },
        else => try self.writeM(try self.ast.getNodeText(node), node.startByte()),
    }
}

/// Find control flow or zx_block inside a node
fn findSpecialChild(node: ts.Node) ?ts.Node {
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        switch (NodeKind.fromNode(child)) {
            .if_expression, .for_expression, .while_expression, .switch_expression, .zx_block => return child,
            else => {
                if (findSpecialChild(child)) |found| return found;
            },
        }
    }
    return null;
}

const ZxAttribute = struct {
    name: []const u8,
    name_byte_offset: u32,
    value: []const u8,
    value_byte_offset: u32,
    is_builtin: bool,
    /// Optional zx_block node for attribute values that contain ZX elements
    zx_block_node: ?ts.Node = null,
    /// Optional template string node for attribute values that are template strings
    template_string_node: ?ts.Node = null,
    /// True if this is a shorthand attribute {name} -> name={name}
    is_shorthand: bool = false,
    /// True if this is a spread attribute {..expr}
    is_spread: bool = false,

    /// Check if attribute is valid (has name or is spread)
    fn isValid(self: ZxAttribute) bool {
        return self.name.len > 0 or self.is_spread;
    }

    /// Check if any attributes in the list are regular (non-builtin, non-spread)
    fn hasRegular(attrs: []const ZxAttribute) bool {
        for (attrs) |attr| {
            if (!attr.is_builtin and !attr.is_spread) return true;
        }
        return false;
    }

    /// Check if any attributes in the list are spread attributes
    fn hasSpread(attrs: []const ZxAttribute) bool {
        for (attrs) |attr| {
            if (attr.is_spread) return true;
        }
        return false;
    }
};

/// Write builtin and regular attributes to the transpile context
fn writeAttributes(self: *Transpile, attributes: []const ZxAttribute, in_function: bool) error{OutOfMemory}!void {
    // `@src()` is only valid inside a function scope.
    const src_arg = if (in_function) "@src()" else "null";
    // Write builtin attributes first (like @allocator), but skip transpiler directives
    for (attributes) |attr| {
        if (!attr.is_builtin) continue;
        // Skip transpiler directives - not runtime attributes
        if (std.mem.eql(u8, attr.name, "@client")) continue;
        try self.writeIndent();
        try self.write(".");
        try self.write(attr.name[1..]); // Skip @ prefix
        try self.write(" = ");

        // @fallback={(<UserProfile user_id={0} />)}
        const is_fallback = std.mem.eql(u8, attr.name, "@fallback");
        const is_caching = std.mem.eql(u8, attr.name, "@caching");
        if (is_fallback) try self.print("{s}.ptr(", .{self.zx_name});

        // If value contains a zx_block, transpile it instead of writing raw text
        if (attr.zx_block_node) |zx_node| {
            try self.transpileBlock(zx_node);
        } else if (is_caching) {
            // String value for @caching - wrap with comptime .tag()
            try self.write("comptime .tag(");
            try self.writeM(attr.value, attr.value_byte_offset);
            try self.write(")");
        } else {
            try self.writeM(attr.value, attr.value_byte_offset);
        }

        if (is_fallback) try self.write(")");
        try self.write(",\n");
    }

    // Write regular attributes using _zx.attrs() and _zx.attr() for type-aware handling
    const has_regular = ZxAttribute.hasRegular(attributes);
    const has_spread = ZxAttribute.hasSpread(attributes);

    if (!has_regular and !has_spread) return;

    try self.writeIndent();

    // If we have spread attributes, use _zx.attrsM to merge regular and spread attributes
    if (has_spread) {
        try self.print(".attributes = {s}.attrsM(.{{\n", .{self.zx_name});
    } else {
        try self.print(".attributes = {s}.attrs(.{{\n", .{self.zx_name});
    }
    self.indent_level += 1;

    for (attributes) |attr| {
        if (attr.is_builtin) continue;

        try self.writeIndent();

        // Handle spread attributes
        if (attr.is_spread) {
            try self.print("{s}.attrSpr(", .{self.zx_name});
            try self.writeM(attr.value, attr.value_byte_offset);
            try self.write("),\n");
            continue;
        }

        // Handle template strings with _zx.attrf
        if (attr.template_string_node) |template_node| {
            try self.transpileTemplateStringAttr(attr, template_node);
        } else if (attr.zx_block_node) |zx_node| {
            // If value contains a zx_block, transpile it instead of writing raw text
            try self.print("{s}.attr(", .{self.zx_name});
            try self.write(src_arg);
            try self.write(", \"");
            try self.writeM(attr.name, attr.name_byte_offset);
            try self.write("\", ");
            try self.transpileBlock(zx_node);
            try self.write("),\n");
        } else {
            try self.print("{s}.attr(", .{self.zx_name});
            try self.write(src_arg);
            try self.write(", \"");
            try self.writeM(attr.name, attr.name_byte_offset);
            try self.write("\", ");
            try self.writeM(attr.value, attr.value_byte_offset);
            try self.write("),\n");
        }
    }

    self.indent_level -= 1;
    try self.writeIndent();
    try self.write("}),\n");
}

/// Transpile a template string for component props to _zx.propf("format", .{ values })
fn transpileTemplateStringProp(self: *Transpile, template_node: ts.Node) error{OutOfMemory}!void {
    var format_parts = std.ArrayList(u8).empty;
    defer format_parts.deinit(self.output.allocator);
    var substitutions = std.ArrayList(ts.Node).empty;
    defer substitutions.deinit(self.output.allocator);

    const template_start = template_node.startByte();
    const template_end = template_node.endByte();

    // Track current position to capture gaps between children (like spaces)
    var current_pos = template_start + 1; // Skip opening backtick

    const child_count = template_node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = template_node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);
        const child_start = child.startByte();
        const child_end = child.endByte();

        // Capture any gap (like spaces) between previous position and this child
        if (current_pos < child_start and child_start <= self.ast.source.len) {
            try format_parts.appendSlice(self.output.allocator, self.ast.source[current_pos..child_start]);
        }

        switch (child_kind) {
            .zx_template_content => {
                // Add text content to format string
                const text = try self.ast.getNodeText(child);
                try format_parts.appendSlice(self.output.allocator, text);
            },
            .zx_template_substitution => {
                // Tree-sitter may include leading whitespace in the substitution node.
                // Find the actual '{' position and capture any text before it.
                const sub_source = self.ast.source[child_start..child_end];
                const brace_pos = std.mem.indexOfScalar(u8, sub_source, '{');
                if (brace_pos) |pos| {
                    if (pos > 0) {
                        // There's text before the '{' (like a space)
                        try format_parts.appendSlice(self.output.allocator, sub_source[0..pos]);
                    }
                }

                // Replace with {s} and save the expression node
                try format_parts.appendSlice(self.output.allocator, "{s}");

                // Get the expression using field name
                const expr_node = child.childByFieldName("expression");
                if (expr_node) |expr| {
                    try substitutions.append(self.output.allocator, expr);
                }
            },
            else => {},
        }

        current_pos = child_end;
    }

    // Capture any remaining content before closing backtick (unlikely but safe)
    if (current_pos < template_end - 1 and template_end <= self.ast.source.len) {
        try format_parts.appendSlice(self.output.allocator, self.ast.source[current_pos .. template_end - 1]);
    }

    // Write _zx.propf("format", .{ values })
    try self.print("{s}.propf(\"", .{self.zx_name});
    try self.write(format_parts.items);
    try self.write("\", .{");

    for (substitutions.items, 0..) |sub_node, idx| {
        if (idx > 0) try self.write(",");
        try self.print(" {s}.propv(", .{self.zx_name});
        const expr_text = try self.ast.getNodeText(sub_node);
        try self.writeM(expr_text, sub_node.startByte());
        try self.write(")");
    }

    try self.write(" })");
}

/// Transpile a template string attribute to _zx.attrf("name", "format", .{ values })
fn transpileTemplateStringAttr(self: *Transpile, attr: ZxAttribute, template_node: ts.Node) error{OutOfMemory}!void {
    // Collect template content and substitutions
    var format_parts = std.ArrayList(u8).empty;
    defer format_parts.deinit(self.output.allocator);
    var substitutions = std.ArrayList(ts.Node).empty;
    defer substitutions.deinit(self.output.allocator);

    const template_start = template_node.startByte();
    const template_end = template_node.endByte();

    // Track current position to capture gaps between children (like spaces)
    var current_pos = template_start + 1; // Skip opening backtick

    const child_count = template_node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = template_node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);
        const child_start = child.startByte();
        const child_end = child.endByte();

        // Capture any gap (like spaces) between previous position and this child
        if (current_pos < child_start and child_start <= self.ast.source.len) {
            try format_parts.appendSlice(self.output.allocator, self.ast.source[current_pos..child_start]);
        }

        switch (child_kind) {
            .zx_template_content => {
                // Add text content to format string
                const text = try self.ast.getNodeText(child);
                try format_parts.appendSlice(self.output.allocator, text);
            },
            .zx_template_substitution => {
                // Tree-sitter may include leading whitespace in the substitution node.
                // Find the actual '{' position and capture any text before it.
                const sub_source = self.ast.source[child_start..child_end];
                const brace_pos = std.mem.indexOfScalar(u8, sub_source, '{');
                if (brace_pos) |pos| {
                    if (pos > 0) {
                        // There's text before the '{' (like a space)
                        try format_parts.appendSlice(self.output.allocator, sub_source[0..pos]);
                    }
                }

                // Replace with {s} and save the expression node
                try format_parts.appendSlice(self.output.allocator, "{s}");

                // Get the expression using field name
                const expr_node = child.childByFieldName("expression");
                if (expr_node) |expr| {
                    try substitutions.append(self.output.allocator, expr);
                }
            },
            else => {},
        }

        current_pos = child_end;
    }

    // Capture any remaining content before closing backtick (unlikely but safe)
    if (current_pos < template_end - 1 and template_end <= self.ast.source.len) {
        try format_parts.appendSlice(self.output.allocator, self.ast.source[current_pos .. template_end - 1]);
    }

    // Write _zx.attrf("name", "format", .{ values })
    try self.print("{s}.attrf(\"", .{self.zx_name});
    try self.writeM(attr.name, attr.name_byte_offset);
    try self.write("\", \"");
    try self.write(format_parts.items);
    try self.write("\", .{\n");

    self.indent_level += 1;
    for (substitutions.items) |sub_node| {
        try self.writeIndent();
        try self.print("{s}.attrv(", .{self.zx_name});
        const expr_text = try self.ast.getNodeText(sub_node);
        try self.writeM(expr_text, sub_node.startByte());
        try self.write("),\n");
    }
    self.indent_level -= 1;

    try self.writeIndent();
    try self.write("}),\n");
}

fn parseAttribute(self: *Transpile, node: ts.Node) !ZxAttribute {
    const node_kind = NodeKind.fromNode(node);

    // Handle nested attribute structure: zx_attribute contains zx_builtin_attribute, zx_regular_attribute, or zx_shorthand_attribute
    const attr_node = switch (node_kind) {
        .zx_attribute => node.child(0) orelse return ZxAttribute{
            .name = "",
            .name_byte_offset = node.startByte(),
            .value = "\"\"",
            .value_byte_offset = node.startByte(),
            .is_builtin = false,
        },
        else => node,
    };

    const attr_kind = NodeKind.fromNode(attr_node);

    // Handle shorthand attribute: {identifier} -> name=identifier, value=identifier
    if (attr_kind == .zx_shorthand_attribute) {
        const name_node = attr_node.childByFieldName("name");
        if (name_node) |n| {
            const full_name = try self.ast.getNodeText(n);
            // Extract clean name for HTML attribute (strip @"..." wrapper if present)
            const clean_name = extractCleanIdentifierName(full_name);
            return ZxAttribute{
                .name = clean_name,
                .name_byte_offset = n.startByte(),
                .value = full_name,
                .value_byte_offset = n.startByte(),
                .is_builtin = false,
                .is_shorthand = true,
            };
        }
        return ZxAttribute{
            .name = "",
            .name_byte_offset = node.startByte(),
            .value = "\"\"",
            .value_byte_offset = node.startByte(),
            .is_builtin = false,
        };
    }

    // Handle builtin shorthand attribute: @{identifier} -> @identifier=identifier
    if (attr_kind == .zx_builtin_shorthand_attribute) {
        const name_node = attr_node.childByFieldName("name");
        if (name_node) |n| {
            const var_name = try self.ast.getNodeText(n);
            // Prepend @ to create the builtin attribute name
            const attr_name = try std.fmt.allocPrint(self.allocator, "@{s}", .{var_name});
            return ZxAttribute{
                .name = attr_name,
                .name_byte_offset = n.startByte(),
                .value = var_name,
                .value_byte_offset = n.startByte(),
                .is_builtin = true,
                .is_shorthand = true,
            };
        }
        return ZxAttribute{
            .name = "",
            .name_byte_offset = node.startByte(),
            .value = "\"\"",
            .value_byte_offset = node.startByte(),
            .is_builtin = false,
        };
    }

    // Handle spread attribute: {..expr} -> spread all properties of expr
    if (attr_kind == .zx_spread_attribute) {
        const expr_node = attr_node.childByFieldName("expression");
        if (expr_node) |e| {
            const expr_text = try self.ast.getNodeText(e);
            return ZxAttribute{
                .name = "",
                .name_byte_offset = e.startByte(),
                .value = expr_text,
                .value_byte_offset = e.startByte(),
                .is_builtin = false,
                .is_spread = true,
            };
        }
        return ZxAttribute{
            .name = "",
            .name_byte_offset = node.startByte(),
            .value = "",
            .value_byte_offset = node.startByte(),
            .is_builtin = false,
            .is_spread = true,
        };
    }

    // Use field names to get name and value directly
    const name_node = attr_node.childByFieldName("name");
    const value_node = attr_node.childByFieldName("value");

    const name = if (name_node) |n| try self.ast.getNodeText(n) else "";
    const is_builtin = name.len > 0 and name[0] == '@';

    // Check if value contains a zx_block
    const zx_block_node = if (value_node) |v| findZxBlockInValue(v) else null;

    // Check if value is a template string
    const template_string_node = if (value_node) |v| findTemplateStringInValue(v) else null;

    const value = if (value_node) |v| try self.getAttributeValue(v) else "\"\"";
    const value_offset = if (value_node) |v| v.startByte() else node.startByte();

    return ZxAttribute{
        .name = name,
        .name_byte_offset = if (name_node) |n| n.startByte() else node.startByte(),
        .value = value,
        .value_byte_offset = value_offset,
        .is_builtin = is_builtin,
        .zx_block_node = zx_block_node,
        .template_string_node = template_string_node,
    };
}

/// Extract clean identifier name for HTML attributes
/// For quoted identifiers like @"data-name", returns "data-name"
/// For regular identifiers like "class", returns "class"
fn extractCleanIdentifierName(name: []const u8) []const u8 {
    // Check if it's a quoted identifier: @"..."
    if (name.len >= 3 and name[0] == '@' and name[1] == '"') {
        // Strip @" prefix and " suffix
        if (name[name.len - 1] == '"') {
            return name[2 .. name.len - 1];
        }
    }
    return name;
}

/// Find a zx_block node within an attribute value (for values like attr={<div>...</div>})
fn findZxBlockInValue(node: ts.Node) ?ts.Node {
    const node_kind = NodeKind.fromNode(node);

    // Direct zx_block
    if (node_kind == .zx_block) {
        return node;
    }

    // Check children for zx_block
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (findZxBlockInValue(child)) |found| {
            return found;
        }
    }

    return null;
}

/// Find a template string node within an attribute value (for values like attr=`text-{expr}`)
fn findTemplateStringInValue(node: ts.Node) ?ts.Node {
    const node_kind = NodeKind.fromNode(node);

    // Direct template string
    if (node_kind == .zx_template_string) {
        return node;
    }

    // Check children for template string
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (findTemplateStringInValue(child)) |found| {
            return found;
        }
    }

    return null;
}

fn getAttributeValue(self: *Transpile, node: ts.Node) ![]const u8 {
    return (try self.getAttributeValueExpr(node)).value;
}

fn getAttributeValueExpr(self: *Transpile, node: ts.Node) !AllocatorExpr {
    const node_kind = NodeKind.fromNode(node);

    // For expression blocks, extract the inner expression using field name
    if (node_kind == .zx_expression_block) {
        const expr_node = node.childByFieldName("expression") orelse {
            return .{
                .value = try self.ast.getNodeText(node),
                .byte_offset = node.startByte(),
            };
        };
        return .{
            .value = try self.ast.getNodeText(expr_node),
            .byte_offset = expr_node.startByte(),
        };
    }

    // For attribute values containing expression blocks, recurse
    if (node_kind == .zx_attribute_value) {
        const child_count = node.childCount();
        var i: u32 = 0;
        while (i < child_count) : (i += 1) {
            const child = node.child(i) orelse continue;
            if (NodeKind.fromNode(child) == .zx_expression_block) {
                return try self.getAttributeValueExpr(child);
            }
            // Skip braces, return first non-brace content
            if (SkipTokens.from(child.kind()) == .other) {
                return .{
                    .value = try self.ast.getNodeText(child),
                    .byte_offset = child.startByte(),
                };
            }
        }
    }

    return .{
        .value = try self.ast.getNodeText(node),
        .byte_offset = node.startByte(),
    };
}

fn isInFunction(node: ts.Node) bool {
    var current: ?ts.Node = node.parent();
    while (current) |n| {
        if (NodeKind.fromNode(n) == .function_declaration) return true;
        current = n.parent();
    }
    return false;
}
