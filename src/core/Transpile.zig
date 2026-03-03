const std = @import("std");
const ts = @import("tree_sitter");
const sourcemap = @import("sourcemap.zig");
const Parse = @import("Parse.zig");
const zx = @import("../root.zig");

const Ast = Parse.Parse;
const NodeKind = Parse.NodeKind;

pub const ClientComponentMetadata = struct {
    pub const Type = zx.BuiltinAttribute.Rendering;

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

pub const TranspileContext = struct {
    output: std.array_list.Managed(u8),
    source: []const u8,
    sourcemap_builder: sourcemap.Builder,
    current_line: i32 = 0,
    current_column: i32 = 0,
    track_mappings: bool,
    indent_level: u32 = 0,
    /// Maps component name to its import path (from @jsImport)
    js_imports: std.StringHashMap([]const u8),
    /// Flag to track if we've done the pre-pass for @jsImport collection
    js_imports_collected: bool = false,
    /// The file path of the source file being transpiled (relative to cwd)
    file_path: ?[]const u8 = null,
    /// Counter for generating unique block labels and variable names (for nested loops)
    block_counter: u32 = 0,
    /// Flag to track if _zx has been initialized in the current scope (e.g., inside a return statement)
    zx_initialized: bool = false,
    /// Track client components (components with @rendering attribute)
    client_components: std.ArrayList(ClientComponentMetadata),
    allocator: std.mem.Allocator,

    pub const TranspileOptions = struct {
        sourcemap: bool,
        path: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, source: []const u8, options: TranspileOptions) TranspileContext {
        return .{
            .output = std.array_list.Managed(u8).init(allocator),
            .source = source,
            .sourcemap_builder = sourcemap.Builder.init(allocator),
            .track_mappings = options.sourcemap,
            .js_imports = std.StringHashMap([]const u8).init(allocator),
            .file_path = options.path,
            .client_components = std.ArrayList(ClientComponentMetadata){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TranspileContext) void {
        self.output.deinit();
        self.sourcemap_builder.deinit();
        self.js_imports.deinit();
        self.client_components.deinit(self.allocator);
    }

    fn write(self: *TranspileContext, bytes: []const u8) !void {
        try self.output.appendSlice(bytes);
        self.updatePosition(bytes);
    }

    fn writeWithMapping(self: *TranspileContext, bytes: []const u8, source_line: i32, source_column: i32) !void {
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

    fn writeM(self: *TranspileContext, bytes: []const u8, source_byte: u32, ast: *const Ast) !void {
        const pos = ast.getLineColumn(source_byte);
        try self.writeWithMapping(bytes, pos.line, pos.column);
    }

    fn updatePosition(self: *TranspileContext, bytes: []const u8) void {
        for (bytes) |byte| {
            if (byte == '\n') {
                self.current_line += 1;
                self.current_column = 0;
            } else {
                self.current_column += 1;
            }
        }
    }

    fn writeIndent(self: *TranspileContext) !void {
        const spaces = self.indent_level * 4;
        var i: u32 = 0;
        while (i < spaces) : (i += 1) {
            try self.write(" ");
        }
    }

    pub fn finalizeSourceMap(self: *TranspileContext) !sourcemap.SourceMap {
        return try self.sourcemap_builder.build();
    }

    /// Get the next unique block index for generating unique labels/variable names
    pub fn nextBlockIndex(self: *TranspileContext) u32 {
        const idx = self.block_counter;
        self.block_counter += 1;
        return idx;
    }
};

/// Pre-pass to collect all @jsImport mappings from the entire AST
fn collectJsImports(self: *Ast, node: ts.Node, ctx: *TranspileContext) error{OutOfMemory}!void {
    const node_kind = NodeKind.fromNode(node);

    if (node_kind == .variable_declaration) {
        if (try extractJsImport(self, node)) |js_import| {
            try ctx.js_imports.put(js_import.name, js_import.path);
        }
    }

    // Recursively collect from children
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        try collectJsImports(self, child, ctx);
    }
}

pub fn transpileNode(self: *Ast, node: ts.Node, ctx: *TranspileContext) error{OutOfMemory}!void {
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    const node_kind = NodeKind.fromNode(node);

    // On first call, do a pre-pass to collect all @jsImport mappings
    if (!ctx.js_imports_collected) {
        ctx.js_imports_collected = true;
        try collectJsImports(self, node, ctx);
    }

    // Check if this is a ZX block or return expression that needs special handling
    switch (node_kind) {
        .zx_block => {
            // For inline zx_blocks (not in return statements), just transpile the content
            try transpileBlock(self, node, ctx);
            return;
        },
        .variable_declaration => {
            // Check if this variable declaration contains @jsImport
            if (try extractJsImport(self, node)) |js_import| {
                // Store the mapping for later use
                try ctx.js_imports.put(js_import.name, js_import.path);
                // Comment out the entire declaration
                try ctx.writeM("// ", start_byte, self);
                if (start_byte < end_byte and end_byte <= self.source.len) {
                    try ctx.write(self.source[start_byte..end_byte]);
                }
                return;
            }
        },
        .return_expression => {
            const has_zx_block = findZxBlockInReturn(node) != null;

            if (has_zx_block) {
                // Special handling for return (ZX)
                try transpileReturn(self, node, ctx);
                return;
            }
        },
        .builtin_function => {
            const had_output = try transpileBuiltin(self, node, ctx);
            if (had_output)
                return;
        },
        else => {},
    }

    // For regular Zig code, copy as-is with source mapping
    const child_count = node.childCount();
    if (child_count == 0) {
        if (start_byte < end_byte and end_byte <= self.source.len) {
            const text = self.source[start_byte..end_byte];
            try ctx.writeM(text, start_byte, self);
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

        if (current_pos < child_start and child_start <= self.source.len) {
            const text = self.source[current_pos..child_start];
            try ctx.writeM(text, current_pos, self);
        }

        try transpileNode(self, child, ctx);
        current_pos = child_end;
    }

    if (current_pos < end_byte and end_byte <= self.source.len) {
        const text = self.source[current_pos..end_byte];
        try ctx.writeM(text, current_pos, self);
    }
}

const JsImportInfo = struct {
    name: []const u8,
    path: []const u8,
};

/// Extract @jsImport info from a variable declaration: const Name = @jsImport("path");
fn extractJsImport(self: *Ast, node: ts.Node) !?JsImportInfo {
    var component_name: ?[]const u8 = null;
    var import_path: ?[]const u8 = null;

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = NodeKind.fromNode(child);

        // Get the variable name (identifier)
        if (child_kind == .identifier) {
            component_name = try self.getNodeText(child);
        }

        // Check for @jsImport builtin
        if (child_kind == .builtin_function) {
            var is_js_import = false;
            const builtin_child_count = child.childCount();
            var j: u32 = 0;
            while (j < builtin_child_count) : (j += 1) {
                const builtin_child = child.child(j) orelse continue;
                const builtin_child_kind = NodeKind.fromNode(builtin_child);

                if (builtin_child_kind == .builtin_identifier) {
                    const ident = try self.getNodeText(builtin_child);
                    if (std.mem.eql(u8, ident, "@jsImport")) {
                        is_js_import = true;
                    }
                }

                // Extract the path from arguments
                if (is_js_import and builtin_child_kind == .arguments) {
                    const args_count = builtin_child.childCount();
                    var k: u32 = 0;
                    while (k < args_count) : (k += 1) {
                        const arg = builtin_child.child(k) orelse continue;
                        if (NodeKind.fromNode(arg) == .string) {
                            // Get string content (strip quotes)
                            const str_count = arg.childCount();
                            var m: u32 = 0;
                            while (m < str_count) : (m += 1) {
                                const str_child = arg.child(m) orelse continue;
                                if (NodeKind.fromNode(str_child) == .string_content) {
                                    import_path = try self.getNodeText(str_child);
                                    break;
                                }
                            }
                            // Fallback: strip quotes manually
                            if (import_path == null) {
                                const full = try self.getNodeText(arg);
                                if (full.len >= 2) {
                                    import_path = full[1 .. full.len - 1];
                                }
                            }
                            break;
                        }
                    }
                }
            }

            if (is_js_import) {
                if (component_name != null and import_path != null) {
                    return JsImportInfo{
                        .name = component_name.?,
                        .path = import_path.?,
                    };
                }
                // Has @jsImport but couldn't extract all info - still return something
                return JsImportInfo{
                    .name = component_name orelse "Unknown",
                    .path = import_path orelse "",
                };
            }
        }

        // Recursively check children
        if (try extractJsImport(self, child)) |info| {
            return info;
        }
    }
    return null;
}

// @import("component.zx") --> @import("component.zig")
pub fn transpileBuiltin(self: *Ast, node: ts.Node, ctx: *TranspileContext) !bool {
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
                builtin_identifier = try self.getNodeText(child);
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
                        const full_string = try self.getNodeText(arg_child);

                        // Look for string_content inside
                        const string_child_count = arg_child.childCount();
                        var k: u32 = 0;
                        while (k < string_child_count) : (k += 1) {
                            const str_child = arg_child.child(k) orelse continue;
                            const str_child_kind = NodeKind.fromNode(str_child);

                            if (str_child_kind == .string_content) {
                                import_string = try self.getNodeText(str_child);
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
                // Check if it ends with .zx
                if (std.mem.endsWith(u8, import_path, ".zx")) {
                    // Write @import with transformed path
                    try ctx.writeM("@import", node.startByte(), self);
                    try ctx.write("(\"");

                    // Write path with .zig instead of .zx
                    const base_path = import_path[0 .. import_path.len - 3]; // Remove ".zx"
                    try ctx.write(base_path);
                    try ctx.write(".zig\")");

                    had_output = true;
                }
            }
        }
    }

    return had_output;
}

pub fn transpileReturn(self: *Ast, node: ts.Node, ctx: *TranspileContext) !void {
    // Handle: return (<zx>...</zx>) or return ((<zx>...</zx>))
    // This should NOT initialize _zx here - that's done in the parent block
    const zx_block_node = findZxBlockInReturn(node);

    if (zx_block_node) |zx_node| {
        // Find the element inside the zx_block
        const zx_child_count = zx_node.childCount();
        var j: u32 = 0;
        while (j < zx_child_count) : (j += 1) {
            const child = zx_node.child(j) orelse continue;
            const child_kind = NodeKind.fromNode(child);

            switch (child_kind) {
                .zx_element, .zx_self_closing_element, .zx_fragment => {
                    // Check if we need to initialize _zx with allocator
                    const allocator_value = try getAllocatorAttribute(self, child);

                    try ctx.writeM("var", node.startByte(), self);
                    try ctx.write(" _zx = @import(\"zx\").");
                    if (allocator_value) |alloc| {
                        try ctx.write("allocInit(");
                        try ctx.write(alloc);
                        try ctx.write(")");
                    } else {
                        try ctx.write("init()");
                    }
                    try ctx.write(";\n");
                    // Mark that _zx is now initialized for nested ZX blocks
                    ctx.zx_initialized = true;
                    try ctx.writeIndent();
                    try ctx.writeM("return", node.startByte(), self);
                    try ctx.write(" ");
                    try transpileElement(self, child, ctx, true);
                    // Reset the flag after processing the return statement
                    ctx.zx_initialized = false;
                    return;
                },
                else => {},
            }
        }
    }
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

pub fn transpileBlock(self: *Ast, node: ts.Node, ctx: *TranspileContext) !void {
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
                if (ctx.zx_initialized) {
                    try transpileElement(self, child, ctx, false);
                    return;
                }

                // Otherwise, wrap in a self-contained labeled block with local _zx initialization
                // Get unique block index for this inline ZX expression
                const block_idx = ctx.nextBlockIndex();
                var idx_buf: [16]u8 = undefined;
                const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{block_idx}) catch unreachable;

                // Check if element has @allocator attribute
                const allocator_value = try getAllocatorAttribute(self, child);

                // Generate: _zx_ele_blk_N: { var _zx = @import("zx").init(); break :_zx_ele_blk_N _zx.ele(...); }
                try ctx.write("_zx_ele_blk_");
                try ctx.write(idx_str);
                try ctx.write(": {\n");

                ctx.indent_level += 1;
                try ctx.writeIndent();
                try ctx.write("var _zx = @import(\"zx\").");
                if (allocator_value) |alloc| {
                    try ctx.write("allocInit(");
                    try ctx.write(alloc);
                    try ctx.write(")");
                } else {
                    try ctx.write("init()");
                }
                try ctx.write(";\n");

                try ctx.writeIndent();
                try ctx.write("break :_zx_ele_blk_");
                try ctx.write(idx_str);
                try ctx.write(" ");
                try transpileElement(self, child, ctx, false);
                try ctx.write(";\n");

                ctx.indent_level -= 1;
                try ctx.writeIndent();
                try ctx.write("}");
                return;
            },
            else => {},
        }
    }
}

/// Returns the allocator attribute value text if found, null otherwise
pub fn getAllocatorAttribute(self: *Ast, node: ts.Node) !?[]const u8 {
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
                if (try checkAllocatorAttr(self, attr)) |value| return value;
            }
        }

        // Self-closing elements (like <Button @allocator={allocator} /> or <Button @{allocator} />)
        if (child_kind == .zx_attribute or child_kind == .zx_builtin_attribute or child_kind == .zx_shorthand_attribute or child_kind == .zx_builtin_shorthand_attribute) {
            if (try checkAllocatorAttr(self, child)) |value| return value;
        }
    }
    return null;
}

fn checkAllocatorAttr(self: *Ast, attr: ts.Node) !?[]const u8 {
    const attr_kind = NodeKind.fromNode(attr);
    if (attr_kind != .zx_attribute and attr_kind != .zx_builtin_attribute and attr_kind != .zx_shorthand_attribute and attr_kind != .zx_builtin_shorthand_attribute) return null;

    const actual_attr = if (attr_kind == .zx_attribute) attr.child(0) orelse return null else attr;
    const actual_kind = NodeKind.fromNode(actual_attr);

    // Regular shorthand attributes can't be @allocator since they don't have @ prefix
    if (actual_kind == .zx_shorthand_attribute) return null;

    // Handle builtin shorthand: @{allocator} -> @allocator={allocator}
    if (actual_kind == .zx_builtin_shorthand_attribute) {
        const name_node = actual_attr.childByFieldName("name") orelse return null;
        const name = try self.getNodeText(name_node);
        if (std.mem.eql(u8, name, "allocator")) {
            return name; // The variable name is "allocator"
        }
        return null;
    }

    const name_node = actual_attr.childByFieldName("name") orelse return null;
    const name = try self.getNodeText(name_node);

    if (std.mem.eql(u8, name, "@allocator")) {
        const value_node = actual_attr.childByFieldName("value") orelse return "allocator"; // TODO: need to catch and add to errors list in case of no value
        return try getAttributeValue(self, value_node);
    }
    return null;
}

pub fn transpileElement(self: *Ast, node: ts.Node, ctx: *TranspileContext, is_root: bool) !void {
    const node_kind = NodeKind.fromNode(node);
    switch (node_kind) {
        .zx_fragment => try transpileFragment(self, node, ctx, is_root),
        .zx_self_closing_element => try transpileSelfClosing(self, node, ctx, is_root),
        .zx_element => try transpileFullElement(self, node, ctx, is_root, false),
        else => unreachable,
    }
}

pub fn transpileFragment(self: *Ast, node: ts.Node, ctx: *TranspileContext, is_root: bool) !void {
    _ = is_root;

    // Collect all zx_child nodes from the fragment
    var children = std.ArrayList(ts.Node){};
    defer children.deinit(ctx.output.allocator);

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) == .zx_child) {
            try children.append(ctx.output.allocator, child);
        }
    }

    // Fragment is just like a regular element but with .fragment tag and no attributes
    try ctx.writeM("_zx.ele", node.startByte(), self);
    try ctx.write("(\n");

    ctx.indent_level += 1;
    try ctx.writeIndent();
    try ctx.write(".fragment,\n");

    try ctx.writeIndent();
    try ctx.write(".{\n");
    ctx.indent_level += 1;

    // Write children
    if (children.items.len > 0) {
        try ctx.writeIndent();
        try ctx.write(".children = &.{\n");
        ctx.indent_level += 1;

        for (children.items, 0..) |child, idx| {
            const saved_len = ctx.output.items.len;
            try ctx.writeIndent();
            const is_last_child = idx == children.items.len - 1;
            const had_output = try transpileChild(self, child, ctx, false, is_last_child);

            if (had_output) {
                try ctx.write(",\n");
            } else {
                ctx.output.shrinkRetainingCapacity(saved_len);
            }
        }

        ctx.indent_level -= 1;
        try ctx.writeIndent();
        try ctx.write("},\n");
    }

    ctx.indent_level -= 1;
    try ctx.writeIndent();
    try ctx.write("},\n");
    ctx.indent_level -= 1;

    try ctx.writeIndent();
    try ctx.write(")");
}

pub fn isCustomComponent(tag: []const u8) bool {
    // Namespaced components (e.g., components.Button, icons.GitHub) are always custom
    if (std.mem.indexOfScalar(u8, tag, '.') != null) return true;
    return tag.len > 0 and std.ascii.isUpper(tag[0]);
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

/// Escape text for use in Zig string literal
fn escapeZigString(text: []const u8, ctx: *TranspileContext) !void {
    for (text) |c| {
        switch (c) {
            '\\' => try ctx.write("\\\\"),
            '"' => try ctx.write("\\\""),
            '\n' => try ctx.write("\\n"),
            '\r' => try ctx.write("\\r"),
            '\t' => try ctx.write("\\t"),
            else => try ctx.write(&[_]u8{c}),
        }
    }
}

pub fn transpileSelfClosing(self: *Ast, node: ts.Node, ctx: *TranspileContext, is_root: bool) !void {
    _ = is_root;

    var tag_name: ?[]const u8 = null;
    var attributes = std.ArrayList(ZxAttribute){};
    defer attributes.deinit(ctx.output.allocator);

    // Parse the self-closing element
    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;

        switch (NodeKind.fromNode(child)) {
            .zx_tag_name => tag_name = try self.getNodeText(child),
            .zx_attribute, .zx_builtin_attribute, .zx_regular_attribute, .zx_shorthand_attribute, .zx_builtin_shorthand_attribute, .zx_spread_attribute => {
                const attr = try parseAttribute(self, child);
                if (attr.isValid()) {
                    try attributes.append(ctx.output.allocator, attr);
                }
            },
            else => {},
        }
    }

    const tag = tag_name orelse return;

    if (isCustomComponent(tag)) {
        try writeCustomComponent(self, node, tag, attributes.items, &.{}, ctx);
    } else {
        try writeHtmlElement(self, node, tag, attributes.items, &.{}, ctx, false);
    }
}

pub fn transpileFullElement(self: *Ast, node: ts.Node, ctx: *TranspileContext, is_root: bool, parent_preserve_whitespace: bool) !void {
    _ = is_root;

    // Parse element structure
    var tag_name: ?[]const u8 = null;
    var attributes = std.ArrayList(ZxAttribute){};
    defer attributes.deinit(ctx.output.allocator);
    var children = std.ArrayList(ts.Node){};
    defer children.deinit(ctx.output.allocator);

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
                        .zx_tag_name => tag_name = try self.getNodeText(tag_child),
                        .zx_attribute, .zx_builtin_attribute, .zx_regular_attribute, .zx_shorthand_attribute, .zx_builtin_shorthand_attribute, .zx_spread_attribute => {
                            const attr = try parseAttribute(self, tag_child);
                            if (attr.isValid()) {
                                try attributes.append(ctx.output.allocator, attr);
                            }
                        },
                        else => {},
                    }
                }
            },
            .zx_child => try children.append(ctx.output.allocator, child),
            else => {},
        }
    }

    const tag = tag_name orelse return;

    // Custom component with children
    if (isCustomComponent(tag)) {
        try writeCustomComponent(self, node, tag, attributes.items, children.items, ctx);
        return;
    }

    // Check for <pre> tag - preserve whitespace but still process children normally
    // Also inherit preserve_whitespace from parent (e.g., nested elements inside <pre>)
    const preserve_whitespace = parent_preserve_whitespace or isPreElement(tag);

    // Regular HTML element (with optional whitespace preservation for <pre>)
    try writeHtmlElement(self, node, tag, attributes.items, children.items, ctx, preserve_whitespace);
}

/// Write a custom component: _zx.cmp(Component, .{ .prop = value }) or _zx.client(...) for React CSR
fn writeCustomComponent(self: *Ast, node: ts.Node, tag: []const u8, attributes: []const ZxAttribute, children: []const ts.Node, ctx: *TranspileContext) error{OutOfMemory}!void {
    // Check if this is a client-side rendered component (@rendering={.react} or @rendering={.client})
    var rendering_value: ?[]const u8 = null;
    for (attributes) |attr| {
        if (attr.is_builtin and std.mem.eql(u8, attr.name, "@rendering")) {
            rendering_value = attr.value;
            break;
        }
    }

    const is_csr = if (rendering_value) |rv| std.mem.eql(u8, rv, ".react") else false;
    const is_client = if (rendering_value) |rv| std.mem.eql(u8, rv, ".client") else false;

    // React CSR components use _zx.client() directly
    if (is_csr) {
        var path_buf: [512]u8 = undefined;
        var full_path: []const u8 = undefined;

        // CSR: use current file's directory + @jsImport path
        const raw_path = ctx.js_imports.get(tag) orelse "unknown.tsx";

        // Get the directory of the current file
        if (ctx.file_path) |fp| {
            // Find the last slash to get the directory
            if (std.mem.lastIndexOfScalar(u8, fp, '/')) |last_slash| {
                const dir = fp[0 .. last_slash + 1];
                // Strip leading ./ from raw_path if present
                const clean_path = if (std.mem.startsWith(u8, raw_path, "./"))
                    raw_path[2..]
                else
                    raw_path;
                const len = dir.len + clean_path.len;
                if (len <= path_buf.len) {
                    @memcpy(path_buf[0..dir.len], dir);
                    @memcpy(path_buf[dir.len..][0..clean_path.len], clean_path);
                    full_path = path_buf[0..len];
                } else {
                    full_path = raw_path;
                }
            } else {
                // No directory, just use the raw path with ./
                if (std.mem.startsWith(u8, raw_path, "./")) {
                    full_path = raw_path;
                } else {
                    const len = 2 + raw_path.len;
                    if (len <= path_buf.len) {
                        @memcpy(path_buf[0..2], "./");
                        @memcpy(path_buf[2..][0..raw_path.len], raw_path);
                        full_path = path_buf[0..len];
                    } else {
                        full_path = raw_path;
                    }
                }
            }
        } else {
            // No file path, fallback to ./ + raw_path
            if (std.mem.startsWith(u8, raw_path, "./")) {
                full_path = raw_path;
            } else {
                const len = 2 + raw_path.len;
                if (len <= path_buf.len) {
                    @memcpy(path_buf[0..2], "./");
                    @memcpy(path_buf[2..][0..raw_path.len], raw_path);
                    full_path = path_buf[0..len];
                } else {
                    full_path = raw_path;
                }
            }
        }

        // Add to client components list (use current list length as stable index)
        const rendering_type = ClientComponentMetadata.Type.from(rendering_value orelse "react");
        const component_index = ctx.client_components.items.len;
        const client_cmp = try ClientComponentMetadata.init(ctx.allocator, tag, full_path, rendering_type, component_index);
        try ctx.client_components.append(ctx.allocator, client_cmp);

        // Write _zx.client(.{ .name = "Name", .path = "path", .id = "id" }, .{ props })
        try ctx.writeM("_zx.client", node.startByte(), self);
        try ctx.write("(.{ .name = \"");
        try ctx.write(componentDisplayName(tag));
        try ctx.write("\", .path = \"");
        try ctx.write(full_path);
        try ctx.write("\", .id = \"");
        try ctx.write(client_cmp.id);
        try ctx.write("\" }, .{");

        // Write props (non-builtin attributes)
        var first_prop = true;
        for (attributes) |attr| {
            if (attr.is_builtin) continue;
            if (!first_prop) try ctx.write(",");
            first_prop = false;

            try ctx.write(" .");
            try ctx.write(attr.name);
            try ctx.write(" = ");
            // Handle template strings, zx_blocks, and regular values
            if (attr.template_string_node) |template_node| {
                try transpileTemplateStringProp(self, template_node, ctx);
            } else if (attr.zx_block_node) |zx_node| {
                try transpileBlock(self, zx_node, ctx);
            } else {
                try ctx.writeM(attr.value, attr.value_byte_offset, self);
            }
        }

        try ctx.write(" })");
        return;
    }

    // Zig client components (@rendering={.client}) use _zx.cmp() with client option
    if (is_client) {
        var path_buf: [512]u8 = undefined;
        var full_path: []const u8 = undefined;

        // Client: use file path with .zig extension (relative to cwd)
        if (ctx.file_path) |fp| {
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
        const rendering_type = ClientComponentMetadata.Type.from(rendering_value orelse "client");
        const component_index = ctx.client_components.items.len;
        const client_cmp = try ClientComponentMetadata.init(ctx.allocator, tag, full_path, rendering_type, component_index);
        try ctx.client_components.append(ctx.allocator, client_cmp);

        // Write _zx.cmp(Component, .{ .name = ..., .client = .{ .name = ..., .id = ... } }, .{ props })
        try ctx.writeM("_zx.cmp", node.startByte(), self);
        try ctx.write("(");
        try ctx.write(tag);
        try ctx.write(", ");
        try ctx.write(".{ .name = \"");
        try ctx.write(componentDisplayName(tag));
        try ctx.write("\", .client = .{ .name = \"");
        try ctx.write(componentDisplayName(tag));
        // try ctx.write("\", .path = \"");
        // try ctx.write(full_path);
        try ctx.write("\", .id = \"");
        try ctx.write(client_cmp.id);
        try ctx.write("\" } }, .{");

        // Write props (non-builtin attributes)
        var first_prop = true;
        for (attributes) |attr| {
            if (attr.is_builtin) continue;
            if (!first_prop) try ctx.write(",");
            first_prop = false;

            try ctx.write(" .");
            try ctx.write(attr.name);
            try ctx.write(" = ");
            // Handle template strings, zx_blocks, and regular values
            if (attr.template_string_node) |template_node| {
                try transpileTemplateStringProp(self, template_node, ctx);
            } else if (attr.zx_block_node) |zx_node| {
                try transpileBlock(self, zx_node, ctx);
            } else {
                try ctx.writeM(attr.value, attr.value_byte_offset, self);
            }
        }

        try ctx.write(" },)");
        return;
    }

    {
        // Regular cmp component: _zx.cmp(Func, .{ .name = ..., options }, .{ props })
        try ctx.writeM("_zx.cmp", node.startByte(), self);
        try ctx.write("(");
        try ctx.write(tag);
        try ctx.write(", ");

        var spreads = std.ArrayList(ZxAttribute){};
        defer spreads.deinit(ctx.output.allocator);
        var regular_props = std.ArrayList(ZxAttribute){};
        defer regular_props.deinit(ctx.output.allocator);
        var builtin_attrs = std.ArrayList(ZxAttribute){};
        defer builtin_attrs.deinit(ctx.output.allocator);

        for (attributes) |attr| {
            if (attr.is_builtin) {
                // Collect builtin attributes for the options parameter
                try builtin_attrs.append(ctx.output.allocator, attr);
                continue;
            }
            if (attr.is_spread) {
                try spreads.append(ctx.output.allocator, attr);
            } else {
                try regular_props.append(ctx.output.allocator, attr);
            }
        }

        const has_spread = spreads.items.len > 0;
        const has_regular_props = regular_props.items.len > 0;
        const has_children = children.len > 0;

        // Write options parameter first (name + builtin attributes)
        try ctx.write(".{ .name = \"");
        try ctx.write(componentDisplayName(tag));
        try ctx.write("\"");
        try writeComponentBuiltinOptions(self, builtin_attrs.items, ctx, true);
        try ctx.write(" }, ");

        // Case 1: Single spread
        if (spreads.items.len == 1 and !has_regular_props and !has_children) {
            try ctx.writeM(spreads.items[0].value, spreads.items[0].value_byte_offset, self);
        }
        // Case 2: Multiple spreads with other props or children - use propsM
        else if (has_spread) {
            var need_merge = false;
            if (spreads.items.len > 0) {
                try ctx.write("_zx.propsM(");
                try ctx.writeM(spreads.items[0].value, spreads.items[0].value_byte_offset, self);
                need_merge = true;
            }

            for (spreads.items[1..]) |spread| {
                try ctx.write(", ");
                try ctx.writeM(spread.value, spread.value_byte_offset, self);
            }

            if (has_regular_props or has_children) {
                if (need_merge) try ctx.write(", ");
                try ctx.write(".{");

                var first_prop = true;
                for (regular_props.items) |attr| {
                    if (!first_prop) try ctx.write(",");
                    first_prop = false;

                    try ctx.write(" .");
                    try ctx.write(attr.name);
                    try ctx.write(" = ");
                    // Handle template strings, zx_blocks, and regular values
                    if (attr.template_string_node) |template_node| {
                        try transpileTemplateStringProp(self, template_node, ctx);
                    } else if (attr.zx_block_node) |zx_node| {
                        try transpileBlock(self, zx_node, ctx);
                    } else {
                        try ctx.writeM(attr.value, attr.value_byte_offset, self);
                    }
                }

                // Add children prop
                if (has_children) {
                    if (!first_prop) try ctx.write(",");
                    try ctx.write(" .children = ");
                    try writeChildrenValue(self, children, ctx);
                }

                try ctx.write(" }");
            }

            if (need_merge) try ctx.write(")");
        }
        // Case 3: Regular attrs
        else {
            try ctx.write(".{");

            var first_prop = true;
            for (regular_props.items) |attr| {
                if (!first_prop) try ctx.write(",");
                first_prop = false;

                try ctx.write(" .");
                try ctx.write(attr.name);
                try ctx.write(" = ");
                // Handle template strings, zx_blocks, and regular values
                if (attr.template_string_node) |template_node| {
                    try transpileTemplateStringProp(self, template_node, ctx);
                } else if (attr.zx_block_node) |zx_node| {
                    try transpileBlock(self, zx_node, ctx);
                } else {
                    try ctx.writeM(attr.value, attr.value_byte_offset, self);
                }
            }

            // Add children prop
            if (has_children) {
                if (!first_prop) try ctx.write(",");
                try ctx.write(" .children = ");
                try writeChildrenValue(self, children, ctx);
            }

            try ctx.write(" }");
        }

        try ctx.write(",)");
    }
}

/// Write builtin options for component (cmp) calls.
/// `has_prior_field` should be true when a field (e.g. `.name`) was already written
/// so the first builtin attr is prefixed with a comma separator.
fn writeComponentBuiltinOptions(self: *Ast, builtin_attrs: []const ZxAttribute, ctx: *TranspileContext, has_prior_field: bool) !void {
    var first = !has_prior_field;
    for (builtin_attrs) |attr| {
        // Skip @rendering which is handled separately for CSR components
        if (std.mem.eql(u8, attr.name, "@rendering")) continue;
        // Skip @allocator which is not relevant for components
        if (std.mem.eql(u8, attr.name, "@allocator")) continue;

        if (!first) try ctx.write(",");
        first = false;

        // Map attribute names to Zig field names
        if (std.mem.eql(u8, attr.name, "@async")) {
            try ctx.write(" .@\"async\" = ");
        } else if (std.mem.eql(u8, attr.name, "@fallback")) {
            try ctx.write(" .fallback = _zx.ptr(");
        } else if (std.mem.eql(u8, attr.name, "@caching")) {
            try ctx.write(" .caching = ");
            // If it's a string value (not a zx_block), wrap with comptime .tag()
            if (attr.zx_block_node == null) {
                try ctx.write("comptime .tag(");
                try ctx.writeM(attr.value, attr.value_byte_offset, self);
                try ctx.write(")");
                continue;
            }
        } else {
            try ctx.write(" .");
            try ctx.write(attr.name[1..]); // Skip @ prefix
            try ctx.write(" = ");
        }

        // Write the value
        if (attr.zx_block_node) |zx_node| {
            try transpileBlock(self, zx_node, ctx);
        } else {
            try ctx.writeM(attr.value, attr.value_byte_offset, self);
        }

        // Close the ptr() wrapper for @fallback
        if (std.mem.eql(u8, attr.name, "@fallback")) {
            try ctx.write(")");
        }
    }
}

fn writeChildrenValue(self: *Ast, children: []const ts.Node, ctx: *TranspileContext) !void {
    if (children.len == 1) {
        _ = try transpileChild(self, children[0], ctx, false, true);
    } else {
        try ctx.write("_zx.ele(.fragment, .{ .children = &.{");
        for (children, 0..) |child, idx| {
            const saved_len = ctx.output.items.len;
            const had_output = try transpileChild(self, child, ctx, false, idx == children.len - 1);
            if (had_output) {
                try ctx.write(", ");
            } else {
                ctx.output.shrinkRetainingCapacity(saved_len);
            }
        }
        try ctx.write("} })");
    }
}

/// Write a regular HTML element: _zx.ele(.tag, .{ ... })
/// When preserve_whitespace is true (e.g. for <pre>), text nodes won't be trimmed
fn writeHtmlElement(self: *Ast, node: ts.Node, tag: []const u8, attributes: []const ZxAttribute, children: []const ts.Node, ctx: *TranspileContext, preserve_whitespace: bool) !void {
    try ctx.writeM("_zx.ele", node.startByte(), self);
    try ctx.write("(\n");

    ctx.indent_level += 1;
    try ctx.writeIndent();
    try ctx.writeM(".", node.startByte(), self);
    try ctx.write(tag);
    try ctx.write(",\n");

    // Write options struct
    try ctx.writeIndent();
    try ctx.write(".{\n");
    ctx.indent_level += 1;

    try writeAttributes(self, attributes, ctx);

    // Write children
    if (children.len > 0) {
        try ctx.writeIndent();
        try ctx.write(".children = &.{\n");
        ctx.indent_level += 1;

        for (children, 0..) |child, idx| {
            const saved_len = ctx.output.items.len;
            try ctx.writeIndent();
            const is_last_child = idx == children.len - 1;
            const had_output = try transpileChild(self, child, ctx, preserve_whitespace, is_last_child);

            if (had_output) {
                try ctx.write(",\n");
            } else {
                ctx.output.shrinkRetainingCapacity(saved_len);
            }
        }

        ctx.indent_level -= 1;
        try ctx.writeIndent();
        try ctx.write("},\n");
    }

    ctx.indent_level -= 1;
    try ctx.writeIndent();
    try ctx.write("},\n");
    ctx.indent_level -= 1;

    try ctx.writeIndent();
    try ctx.write(")");
}

/// Transpile a child node. When preserve_whitespace is true (e.g. inside <pre>),
/// text nodes are not trimmed and whitespace is preserved exactly.
/// is_last_child indicates if this is the last child in the parent (used for newline handling in <pre>).
pub fn transpileChild(self: *Ast, node: ts.Node, ctx: *TranspileContext, preserve_whitespace: bool, is_last_child: bool) error{OutOfMemory}!bool {
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
                const text = try self.getNodeText(child);

                if (preserve_whitespace) {
                    // For <pre> and similar: preserve whitespace exactly
                    // Add \n at end of each text node except the last child
                    if (text.len == 0) continue;

                    try ctx.writeM("_zx.txt(\"", child.startByte(), self);
                    try escapeZigString(text, ctx);
                    // Add newline at end unless this is the last child
                    if (!is_last_child) try ctx.write("\\n");
                    try ctx.write("\")");
                    had_output = true;
                } else {
                    // Normal mode: trim and normalize whitespace
                    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
                    if (trimmed.len == 0) continue;

                    // JSX-like whitespace handling: preserve leading/trailing single space
                    // when adjacent to expressions or other inline content
                    const has_leading_ws = text.len > 0 and std.ascii.isWhitespace(text[0]);
                    const has_trailing_ws = text.len > 0 and std.ascii.isWhitespace(text[text.len - 1]);

                    try ctx.writeM("_zx.txt(\"", child.startByte(), self);
                    if (has_leading_ws) try ctx.write(" ");
                    try escapeZigString(trimmed, ctx);
                    if (has_trailing_ws) try ctx.write(" ");
                    try ctx.write("\")");
                    had_output = true;
                }
            },
            .zx_expression_block => {
                try transpileExprBlock(self, child, ctx);
                had_output = true;
            },
            .zx_element => {
                // Pass preserve_whitespace to nested elements (e.g., elements inside <pre>)
                try transpileFullElement(self, child, ctx, false, preserve_whitespace);
                had_output = true;
            },
            .zx_self_closing_element => {
                try transpileSelfClosing(self, child, ctx, false);
                had_output = true;
            },
            .zx_fragment => {
                try transpileFragment(self, child, ctx, false);
                had_output = true;
            },
            else => {},
        }
    }
    return had_output;
}

pub fn transpileExprBlock(self: *Ast, node: ts.Node, ctx: *TranspileContext) error{OutOfMemory}!void {
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
                try ctx.write(child_type);
                continue;
            },
            .other => {},
        }

        // Handle control flow and special expressions
        switch (NodeKind.fromNode(child)) {
            .if_expression => {
                try transpileIf(self, child, ctx);
                continue;
            },
            .for_expression => {
                try transpileFor(self, child, ctx);
                continue;
            },
            .while_expression => {
                try transpileWhile(self, child, ctx);
                continue;
            },
            .switch_expression => {
                try transpileSwitch(self, child, ctx);
                continue;
            },
            .multiline_string => {
                try transpileMultilineString(self, child, ctx);
                continue;
            },
            else => {},
        }

        // Regular expression handling
        const expr_text = try self.getNodeText(child);
        const trimmed = std.mem.trim(u8, expr_text, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // Regular expression like {user.name}
        try ctx.writeM("_zx.expr(", child.startByte(), self);
        try ctx.writeM(trimmed, child.startByte(), self);
        try ctx.write(")");
    }
}

/// Transpile multiline string expression with proper formatting
fn transpileMultilineString(self: *Ast, node: ts.Node, ctx: *TranspileContext) !void {
    const expr_text = try self.getNodeText(node);

    // Write _zx.expr( followed by newline
    try ctx.writeM("_zx.expr(", node.startByte(), self);
    try ctx.write("\n");

    ctx.indent_level += 1;

    // Split by newlines and write each line with proper indentation
    var lines = std.mem.splitScalar(u8, expr_text, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trimLeft(u8, line, " \t");
        if (trimmed_line.len == 0) continue;

        try ctx.writeIndent();
        try ctx.write(trimmed_line);
        try ctx.write("\n");
    }

    ctx.indent_level -= 1;

    // Write closing paren with proper indentation
    try ctx.writeIndent();
    try ctx.write(")");
}

pub fn transpileIf(self: *Ast, node: ts.Node, ctx: *TranspileContext) !void {
    // if_expression: 'if' '(' condition ')' [payload] then_expr ['else' [else_payload] else_expr]
    var condition_text: ?[]const u8 = null;
    var payload_text: ?[]const u8 = null;
    var else_payload_text: ?[]const u8 = null;
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
        } else if (in_condition and condition_text == null) {
            condition_text = try self.getNodeText(child);
        } else if (in_then and child_kind == .payload) {
            // Capture payload like |un|
            payload_text = try self.getNodeText(child);
        } else if (in_then and then_node == null) {
            then_node = child;
        } else if (in_else and child_kind == .payload) {
            // Capture else payload like |err|
            else_payload_text = try self.getNodeText(child);
        } else if (in_else and else_node == null) {
            else_node = child;
        }
    }

    const cond = condition_text orelse return;
    const then_n = then_node orelse return;

    try ctx.writeM("if", node.startByte(), self);
    try ctx.write(" ");

    // Write condition - ensure wrapped in parens
    const cond_trimmed = std.mem.trim(u8, cond, &std.ascii.whitespace);
    if (cond_trimmed.len > 0 and cond_trimmed[0] == '(' and cond_trimmed[cond_trimmed.len - 1] == ')') {
        try ctx.write(cond_trimmed);
    } else {
        try ctx.write("(");
        try ctx.write(cond_trimmed);
        try ctx.write(")");
    }
    try ctx.write(" ");

    // Write payload if present (e.g., |un|)
    if (payload_text) |payload| {
        try ctx.write(payload);
        try ctx.write(" ");
    }

    // Handle then branch
    try transpileBranch(self, then_n, ctx);

    // Handle else branch
    if (else_node) |else_n| {
        try ctx.write(" else ");
        // Write else payload if present (e.g., |err|)
        if (else_payload_text) |else_payload| {
            try ctx.write(else_payload);
            try ctx.write(" ");
        }
        try transpileBranch(self, else_n, ctx);
    } else {
        try ctx.write(" else _zx.ele(.fragment, .{})");
    }
}

/// Helper to transpile if/else branches consistently
fn transpileBranch(self: *Ast, node: ts.Node, ctx: *TranspileContext) error{OutOfMemory}!void {
    switch (NodeKind.fromNode(node)) {
        .zx_block => try transpileBlock(self, node, ctx),
        .if_expression => try transpileIf(self, node, ctx), // Handle else-if chains
        .parenthesized_expression => {
            try ctx.write("_zx.ele(.fragment, .{ .children = &.{\n");
            try transpileExprBlock(self, node, ctx);
            try ctx.write(",},},)");
        },
        else => {
            try ctx.write("_zx.txt(");
            try ctx.writeM(try self.getNodeText(node), node.startByte(), self);
            try ctx.write(")");
        },
    }
}

pub fn transpileFor(self: *Ast, node: ts.Node, ctx: *TranspileContext) !void {
    // for_expression: 'for' '(' iterable ')' payload body
    var iterables = std.ArrayList(ts.Node){};
    defer iterables.deinit(ctx.allocator);
    var first_iterable_node: ?ts.Node = null;
    var payload_text: ?[]const u8 = null;
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
                payload_text = try self.getNodeText(child);
                seen_payload = true;
                continue;
            }

            if (first_iterable_node == null) first_iterable_node = child;
            if (!std.mem.eql(u8, child_type, ",")) {
                try iterables.append(ctx.allocator, child);
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

    if (first_iterable_node != null and payload_text != null and body_node != null) {
        // Get unique index for this block to avoid conflicts with nested loops
        const block_idx = ctx.nextBlockIndex();
        var idx_buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{block_idx}) catch unreachable;

        try ctx.write("_zx_for_blk_");
        try ctx.write(idx_str);
        try ctx.write(": {\n");
        ctx.indent_level += 1;
        try ctx.writeIndent();
        try ctx.write("const __zx_children_");
        try ctx.write(idx_str);
        try ctx.write(" = _zx.getAlloc().alloc(@import(\"zx\").Component, ");
        if (NodeKind.fromNode(first_iterable_node) == .range_expression) {
            const left_node = first_iterable_node.?.childByFieldName("left").?;
            const right_node = first_iterable_node.?.childByFieldName("right").?;
            try ctx.writeM(try self.getNodeText(right_node), right_node.startByte(), self);
            try ctx.write(" - ");
            try ctx.writeM(try self.getNodeText(left_node), left_node.startByte(), self);
        } else {
            try ctx.writeM(try self.getNodeText(first_iterable_node.?), first_iterable_node.?.startByte(), self);
            try ctx.write(".len");
        }
        try ctx.write(") catch unreachable;\n");
        try ctx.writeIndent();
        try ctx.write("for (");
        for (iterables.items, 0..) |it, it_idx| {
            if (it_idx > 0) try ctx.write(", ");
            try ctx.write(try self.getNodeText(it));
        }
        try ctx.write(", 0..) |");

        // Extract just the variable name from payload (remove pipes)
        const payload = payload_text.?;
        const payload_clean = if (std.mem.startsWith(u8, payload, "|") and std.mem.endsWith(u8, payload, "|"))
            payload[1 .. payload.len - 1]
        else
            payload;

        try ctx.write(payload_clean);
        try ctx.write(", _zx_i_");
        try ctx.write(idx_str);
        try ctx.write("| {\n");

        ctx.indent_level += 1;
        try ctx.writeIndent();
        try ctx.write("__zx_children_");
        try ctx.write(idx_str);
        try ctx.write("[_zx_i_");
        try ctx.write(idx_str);
        try ctx.write("] = ");
        try transpileBranch(self, body_node.?, ctx);
        try ctx.write(";\n");
        ctx.indent_level -= 1;

        try ctx.writeIndent();
        try ctx.write("}\n");

        try ctx.writeIndent();
        try ctx.write("break :_zx_for_blk_");
        try ctx.write(idx_str);
        try ctx.write(" _zx.ele(.fragment, .{ .children = __zx_children_");
        try ctx.write(idx_str);
        try ctx.write(" });\n");

        ctx.indent_level -= 1;
        try ctx.writeIndent();
        try ctx.write("}");
    }
}

pub fn transpileWhile(self: *Ast, node: ts.Node, ctx: *TranspileContext) !void {
    // while_expression: 'while' '(' condition ')' [payload] ':' '(' continue_expr ')' body ['else' [else_payload] else_body]
    var condition_text: ?[]const u8 = null;
    var payload_text: ?[]const u8 = null;
    var continue_text: ?[]const u8 = null;
    var body_node: ?ts.Node = null;
    var else_payload_text: ?[]const u8 = null;
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
                condition_text = try self.getNodeText(child);
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
                    // Else payload like |err|
                    else_payload_text = try self.getNodeText(child);
                } else if (body_node == null) {
                    // Condition payload like |value|
                    payload_text = try self.getNodeText(child);
                    in_body = true;
                }
            },
            .assignment_expression => {
                continue_text = try self.getNodeText(child);
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

    if (condition_text != null and body_node != null) {
        // Get unique index for this block to avoid conflicts with nested loops
        const block_idx = ctx.nextBlockIndex();
        var idx_buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{block_idx}) catch unreachable;

        // Generate: _zx_whl_blk_N: { var __zx_list_N = std.ArrayList(@import("zx").Component).init(_zx.getAlloc()); while (cond) |payload| : (cont) { __zx_list_N.append(...); } else |err| { ... }; break :_zx_whl_blk_N ...; }
        try ctx.writeM("_zx_whl_blk_", node.startByte(), self);
        try ctx.write(idx_str);
        try ctx.write(": {\n");

        ctx.indent_level += 1;
        try ctx.writeIndent();
        try ctx.write("var __zx_list_");
        try ctx.write(idx_str);
        try ctx.write(" = @import(\"std\").ArrayList(@import(\"zx\").Component).empty;\n");

        try ctx.writeIndent();
        try ctx.writeM("while", node.startByte(), self);
        try ctx.write(" (");
        try ctx.write(condition_text.?);
        try ctx.write(")");

        // Write payload if present (e.g., |value|)
        if (payload_text) |payload| {
            try ctx.write(" ");
            try ctx.write(payload);
        }

        if (continue_text) |cont| {
            try ctx.write(" : (");
            try ctx.write(std.mem.trim(u8, cont, &std.ascii.whitespace));
            try ctx.write(")");
        }

        try ctx.write(" {\n");

        ctx.indent_level += 1;
        try ctx.writeIndent();
        try ctx.write("__zx_list_");
        try ctx.write(idx_str);
        try ctx.write(".append(_zx.getAlloc(), ");
        try transpileBlock(self, body_node.?, ctx);
        try ctx.write(") catch unreachable;\n");
        ctx.indent_level -= 1;

        try ctx.writeIndent();
        try ctx.write("}");

        // Handle else branch - append to list instead of breaking
        if (else_node) |else_n| {
            try ctx.write(" else ");
            // Write else payload if present (e.g., |err|)
            if (else_payload_text) |else_payload| {
                try ctx.write(else_payload);
                try ctx.write(" ");
            }
            try ctx.write("{\n");
            ctx.indent_level += 1;
            try ctx.writeIndent();
            try ctx.write("__zx_list_");
            try ctx.write(idx_str);
            try ctx.write(".append(_zx.getAlloc(), ");
            try transpileBranch(self, else_n, ctx);
            try ctx.write(") catch unreachable;\n");
            ctx.indent_level -= 1;
            try ctx.writeIndent();
            try ctx.write("}\n");
        } else {
            try ctx.write("\n");
        }

        try ctx.writeIndent();
        try ctx.write("break :_zx_whl_blk_");
        try ctx.write(idx_str);
        try ctx.write(" _zx.ele(.fragment, .{ .children = __zx_list_");
        try ctx.write(idx_str);
        try ctx.write(".items });\n");

        ctx.indent_level -= 1;
        try ctx.writeIndent();
        try ctx.write("}");
    }
}

pub fn transpileSwitch(self: *Ast, node: ts.Node, ctx: *TranspileContext) error{OutOfMemory}!void {
    // switch_expression: 'switch' '(' expr ')' '{' switch_case... '}'
    var switch_expr: ?[]const u8 = null;

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

        if (found_switch and switch_expr == null) {
            switch_expr = try self.getNodeText(child);
            break;
        }
    }

    const expr = switch_expr orelse return;

    try ctx.writeM("switch", node.startByte(), self);
    try ctx.write(" (");
    try ctx.write(expr);
    try ctx.write(") {\n");

    ctx.indent_level += 1;

    // Parse switch cases
    i = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        if (NodeKind.fromNode(child) == .switch_case) {
            try transpileCase(self, child, ctx);
        }
    }

    ctx.indent_level -= 1;
    try ctx.writeIndent();
    try ctx.write("}");
}

pub fn transpileCase(self: *Ast, node: ts.Node, ctx: *TranspileContext) error{OutOfMemory}!void {
    // switch_case structure: pattern [payload] '=>' value
    try ctx.writeIndent();

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
        try ctx.writeM(self.source[start..end], start, self);
    }

    try ctx.write(" => ");

    if (payload_node) |pl| {
        try ctx.write(" ");
        try ctx.writeM(try self.getNodeText(pl), pl.startByte(), self);
    }

    if (value_node) |v| {
        try transpileCaseValue(self, v, ctx);
    }

    try ctx.write(",\n");
}

/// Transpile switch case value, handling parenthesized expressions with nested control flow/zx
fn transpileCaseValue(self: *Ast, node: ts.Node, ctx: *TranspileContext) !void {
    const kind = NodeKind.fromNode(node);

    switch (kind) {
        .zx_block => try transpileBlock(self, node, ctx),
        .if_expression => try transpileIf(self, node, ctx),
        .for_expression => try transpileFor(self, node, ctx),
        .while_expression => try transpileWhile(self, node, ctx),
        .switch_expression => try transpileSwitch(self, node, ctx),
        .string => {
            // String literal without parentheses like "Admin" -> _zx.txt("Admin")
            try ctx.writeM("_zx.txt(", node.startByte(), self);
            try ctx.writeM(try self.getNodeText(node), node.startByte(), self);
            try ctx.write(")");
        },
        .parenthesized_expression => {
            // Check if contains control flow or zx_block
            if (findSpecialChild(node)) |child| {
                try transpileCaseValue(self, child, ctx);
            } else {
                // Simple parenthesized expression like ("Admin")
                try ctx.writeM("_zx.txt", node.startByte(), self);
                try ctx.writeM(try self.getNodeText(node), node.startByte(), self);
            }
        },
        else => try ctx.writeM(try self.getNodeText(node), node.startByte(), self),
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

pub const ZxAttribute = struct {
    name: []const u8,
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
fn writeAttributes(self: *Ast, attributes: []const ZxAttribute, ctx: *TranspileContext) error{OutOfMemory}!void {
    // Write builtin attributes first (like @allocator), but skip transpiler directives
    for (attributes) |attr| {
        if (!attr.is_builtin) continue;
        // Skip transpiler directives - not runtime attributes
        if (std.mem.eql(u8, attr.name, "@rendering")) continue;
        try ctx.writeIndent();
        try ctx.write(".");
        try ctx.write(attr.name[1..]); // Skip @ prefix
        try ctx.write(" = ");

        // @fallback={(<UserProfile user_id={0} />)}
        const is_fallback = std.mem.eql(u8, attr.name, "@fallback");
        const is_caching = std.mem.eql(u8, attr.name, "@caching");
        if (is_fallback) try ctx.write("_zx.ptr(");

        // If value contains a zx_block, transpile it instead of writing raw text
        if (attr.zx_block_node) |zx_node| {
            try transpileBlock(self, zx_node, ctx);
        } else if (is_caching) {
            // String value for @caching - wrap with comptime .tag()
            try ctx.write("comptime .tag(");
            try ctx.writeM(attr.value, attr.value_byte_offset, self);
            try ctx.write(")");
        } else {
            try ctx.writeM(attr.value, attr.value_byte_offset, self);
        }

        if (is_fallback) try ctx.write(")");
        try ctx.write(",\n");
    }

    // Write regular attributes using _zx.attrs() and _zx.attr() for type-aware handling
    const has_regular = ZxAttribute.hasRegular(attributes);
    const has_spread = ZxAttribute.hasSpread(attributes);

    if (!has_regular and !has_spread) return;

    try ctx.writeIndent();

    // If we have spread attributes, use _zx.attrsM to merge regular and spread attributes
    if (has_spread) {
        try ctx.write(".attributes = _zx.attrsM(.{\n");
    } else {
        try ctx.write(".attributes = _zx.attrs(.{\n");
    }
    ctx.indent_level += 1;

    for (attributes) |attr| {
        if (attr.is_builtin) continue;

        try ctx.writeIndent();

        // Handle spread attributes
        if (attr.is_spread) {
            try ctx.write("_zx.attrSpr(");
            try ctx.writeM(attr.value, attr.value_byte_offset, self);
            try ctx.write("),\n");
            continue;
        }

        // Handle template strings with _zx.attrf
        if (attr.template_string_node) |template_node| {
            try transpileTemplateStringAttr(self, attr.name, template_node, ctx);
        } else if (attr.zx_block_node) |zx_node| {
            // If value contains a zx_block, transpile it instead of writing raw text
            try ctx.write("_zx.attr(\"");
            try ctx.write(attr.name);
            try ctx.write("\", ");
            try transpileBlock(self, zx_node, ctx);
            try ctx.write("),\n");
        } else {
            try ctx.write("_zx.attr(\"");
            try ctx.write(attr.name);
            try ctx.write("\", ");
            try ctx.writeM(attr.value, attr.value_byte_offset, self);
            try ctx.write("),\n");
        }
    }

    ctx.indent_level -= 1;
    try ctx.writeIndent();
    try ctx.write("}),\n");
}

/// Transpile a template string for component props to _zx.propf("format", .{ values })
fn transpileTemplateStringProp(self: *Ast, template_node: ts.Node, ctx: *TranspileContext) error{OutOfMemory}!void {
    var format_parts = std.ArrayList(u8){};
    defer format_parts.deinit(ctx.output.allocator);
    var substitutions = std.ArrayList(ts.Node){};
    defer substitutions.deinit(ctx.output.allocator);

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
        if (current_pos < child_start and child_start <= self.source.len) {
            try format_parts.appendSlice(ctx.output.allocator, self.source[current_pos..child_start]);
        }

        switch (child_kind) {
            .zx_template_content => {
                // Add text content to format string
                const text = try self.getNodeText(child);
                try format_parts.appendSlice(ctx.output.allocator, text);
            },
            .zx_template_substitution => {
                // Tree-sitter may include leading whitespace in the substitution node.
                // Find the actual '{' position and capture any text before it.
                const sub_source = self.source[child_start..child_end];
                const brace_pos = std.mem.indexOfScalar(u8, sub_source, '{');
                if (brace_pos) |pos| {
                    if (pos > 0) {
                        // There's text before the '{' (like a space)
                        try format_parts.appendSlice(ctx.output.allocator, sub_source[0..pos]);
                    }
                }

                // Replace with {s} and save the expression node
                try format_parts.appendSlice(ctx.output.allocator, "{s}");

                // Get the expression using field name
                const expr_node = child.childByFieldName("expression");
                if (expr_node) |expr| {
                    try substitutions.append(ctx.output.allocator, expr);
                }
            },
            else => {},
        }

        current_pos = child_end;
    }

    // Capture any remaining content before closing backtick (unlikely but safe)
    if (current_pos < template_end - 1 and template_end <= self.source.len) {
        try format_parts.appendSlice(ctx.output.allocator, self.source[current_pos .. template_end - 1]);
    }

    // Write _zx.propf("format", .{ values })
    try ctx.write("_zx.propf(\"");
    try ctx.write(format_parts.items);
    try ctx.write("\", .{");

    for (substitutions.items, 0..) |sub_node, idx| {
        if (idx > 0) try ctx.write(",");
        try ctx.write(" _zx.propv(");
        const expr_text = try self.getNodeText(sub_node);
        try ctx.writeM(expr_text, sub_node.startByte(), self);
        try ctx.write(")");
    }

    try ctx.write(" })");
}

/// Transpile a template string attribute to _zx.attrf("name", "format", .{ values })
fn transpileTemplateStringAttr(self: *Ast, attr_name: []const u8, template_node: ts.Node, ctx: *TranspileContext) error{OutOfMemory}!void {
    // Collect template content and substitutions
    var format_parts = std.ArrayList(u8){};
    defer format_parts.deinit(ctx.output.allocator);
    var substitutions = std.ArrayList(ts.Node){};
    defer substitutions.deinit(ctx.output.allocator);

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
        if (current_pos < child_start and child_start <= self.source.len) {
            try format_parts.appendSlice(ctx.output.allocator, self.source[current_pos..child_start]);
        }

        switch (child_kind) {
            .zx_template_content => {
                // Add text content to format string
                const text = try self.getNodeText(child);
                try format_parts.appendSlice(ctx.output.allocator, text);
            },
            .zx_template_substitution => {
                // Tree-sitter may include leading whitespace in the substitution node.
                // Find the actual '{' position and capture any text before it.
                const sub_source = self.source[child_start..child_end];
                const brace_pos = std.mem.indexOfScalar(u8, sub_source, '{');
                if (brace_pos) |pos| {
                    if (pos > 0) {
                        // There's text before the '{' (like a space)
                        try format_parts.appendSlice(ctx.output.allocator, sub_source[0..pos]);
                    }
                }

                // Replace with {s} and save the expression node
                try format_parts.appendSlice(ctx.output.allocator, "{s}");

                // Get the expression using field name
                const expr_node = child.childByFieldName("expression");
                if (expr_node) |expr| {
                    try substitutions.append(ctx.output.allocator, expr);
                }
            },
            else => {},
        }

        current_pos = child_end;
    }

    // Capture any remaining content before closing backtick (unlikely but safe)
    if (current_pos < template_end - 1 and template_end <= self.source.len) {
        try format_parts.appendSlice(ctx.output.allocator, self.source[current_pos .. template_end - 1]);
    }

    // Write _zx.attrf("name", "format", .{ values })
    try ctx.write("_zx.attrf(\"");
    try ctx.write(attr_name);
    try ctx.write("\", \"");
    try ctx.write(format_parts.items);
    try ctx.write("\", .{\n");

    ctx.indent_level += 1;
    for (substitutions.items) |sub_node| {
        try ctx.writeIndent();
        try ctx.write("_zx.attrv(");
        const expr_text = try self.getNodeText(sub_node);
        try ctx.writeM(expr_text, sub_node.startByte(), self);
        try ctx.write("),\n");
    }
    ctx.indent_level -= 1;

    try ctx.writeIndent();
    try ctx.write("}),\n");
}

pub fn parseAttribute(self: *Ast, node: ts.Node) !ZxAttribute {
    const node_kind = NodeKind.fromNode(node);

    // Handle nested attribute structure: zx_attribute contains zx_builtin_attribute, zx_regular_attribute, or zx_shorthand_attribute
    const attr_node = switch (node_kind) {
        .zx_attribute => node.child(0) orelse return ZxAttribute{
            .name = "",
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
            const full_name = try self.getNodeText(n);
            // Extract clean name for HTML attribute (strip @"..." wrapper if present)
            const clean_name = extractCleanIdentifierName(full_name);
            return ZxAttribute{
                .name = clean_name,
                .value = full_name,
                .value_byte_offset = n.startByte(),
                .is_builtin = false,
                .is_shorthand = true,
            };
        }
        return ZxAttribute{
            .name = "",
            .value = "\"\"",
            .value_byte_offset = node.startByte(),
            .is_builtin = false,
        };
    }

    // Handle builtin shorthand attribute: @{identifier} -> @identifier=identifier
    if (attr_kind == .zx_builtin_shorthand_attribute) {
        const name_node = attr_node.childByFieldName("name");
        if (name_node) |n| {
            const var_name = try self.getNodeText(n);
            // Prepend @ to create the builtin attribute name
            const attr_name = try std.fmt.allocPrint(self.allocator, "@{s}", .{var_name});
            return ZxAttribute{
                .name = attr_name,
                .value = var_name,
                .value_byte_offset = n.startByte(),
                .is_builtin = true,
                .is_shorthand = true,
            };
        }
        return ZxAttribute{
            .name = "",
            .value = "\"\"",
            .value_byte_offset = node.startByte(),
            .is_builtin = false,
        };
    }

    // Handle spread attribute: {..expr} -> spread all properties of expr
    if (attr_kind == .zx_spread_attribute) {
        const expr_node = attr_node.childByFieldName("expression");
        if (expr_node) |e| {
            const expr_text = try self.getNodeText(e);
            return ZxAttribute{
                .name = "",
                .value = expr_text,
                .value_byte_offset = e.startByte(),
                .is_builtin = false,
                .is_spread = true,
            };
        }
        return ZxAttribute{
            .name = "",
            .value = "",
            .value_byte_offset = node.startByte(),
            .is_builtin = false,
            .is_spread = true,
        };
    }

    // Use field names to get name and value directly
    const name_node = attr_node.childByFieldName("name");
    const value_node = attr_node.childByFieldName("value");

    const name = if (name_node) |n| try self.getNodeText(n) else "";
    const is_builtin = name.len > 0 and name[0] == '@';

    // Check if value contains a zx_block
    const zx_block_node = if (value_node) |v| findZxBlockInValue(v) else null;

    // Check if value is a template string
    const template_string_node = if (value_node) |v| findTemplateStringInValue(v) else null;

    const value = if (value_node) |v| try getAttributeValue(self, v) else "\"\"";
    const value_offset = if (value_node) |v| v.startByte() else node.startByte();

    return ZxAttribute{
        .name = name,
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

pub fn getAttributeValue(self: *Ast, node: ts.Node) ![]const u8 {
    const node_kind = NodeKind.fromNode(node);

    // For expression blocks, extract the inner expression using field name
    if (node_kind == .zx_expression_block) {
        const expr_node = node.childByFieldName("expression") orelse return try self.getNodeText(node);
        return try self.getNodeText(expr_node);
    }

    // For attribute values containing expression blocks, recurse
    if (node_kind == .zx_attribute_value) {
        const child_count = node.childCount();
        var i: u32 = 0;
        while (i < child_count) : (i += 1) {
            const child = node.child(i) orelse continue;
            if (NodeKind.fromNode(child) == .zx_expression_block) {
                return try getAttributeValue(self, child);
            }
            // Skip braces, return first non-brace content
            if (SkipTokens.from(child.kind()) == .other) {
                return try self.getNodeText(child);
            }
        }
    }

    return try self.getNodeText(node);
}
