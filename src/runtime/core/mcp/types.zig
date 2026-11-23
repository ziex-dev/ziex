const std = @import("std");

pub const stringify_opts: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, stringify_opts);
}

// Embeds pre-serialized JSON as a value (not a string).
pub const RawJson = struct {
    bytes: []const u8,

    pub fn jsonStringify(self: RawJson, jw: anytype) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeAll(self.bytes);
        jw.endWriteRaw();
    }
};

pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
};

pub const ServerCapabilities = struct {
    tools: ?struct { listChanged: bool = false } = null,
    resources: ?struct { subscribe: bool = false, listChanged: bool = false } = null,
    prompts: ?struct { listChanged: bool = false } = null,
};

pub const ToolAnnotations = struct {
    title: ?[]const u8 = null,
    readOnlyHint: ?bool = null,
    destructiveHint: ?bool = null,
    idempotentHint: ?bool = null,
    openWorldHint: ?bool = null,
};

pub const empty_object_schema =
    \\{"type":"object","properties":{},"additionalProperties":false}
;

pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    input_schema_json: []const u8 = empty_object_schema,
    annotations: ?ToolAnnotations = null,
};

pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

pub const ToolResult = struct {
    content: []const TextContent,
    isError: bool = false,
    structuredContent: ?RawJson = null,

    pub fn text(allocator: std.mem.Allocator, message: []const u8) !ToolResult {
        const owned = try allocator.dupe(u8, message);
        const block = try allocator.alloc(TextContent, 1);
        block[0] = .{ .text = owned };
        return .{ .content = block };
    }

    pub fn err(allocator: std.mem.Allocator, message: []const u8) !ToolResult {
        var r = try text(allocator, message);
        r.isError = true;
        return r;
    }

    pub fn fromValue(allocator: std.mem.Allocator, value: anytype) !ToolResult {
        const bytes = try stringify(allocator, value);
        var r = try text(allocator, bytes);
        r.structuredContent = .{ .bytes = bytes };
        return r;
    }
};

pub const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: ServerCapabilities,
    serverInfo: Implementation,
    instructions: ?[]const u8 = null,
};

pub const ToolsListResult = struct {
    tools: []const ToolDescriptor,
};

pub const ToolDescriptor = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    inputSchema: RawJson,
    annotations: ?ToolAnnotations = null,
};

pub const CallToolResult = struct {
    content: []const TextContent,
    isError: bool = false,
    structuredContent: ?RawJson = null,
};

// Client-side shapes; unknown fields are ignored when parsing.
pub const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

pub const Content = struct {
    type: []const u8,
    text: ?[]const u8 = null,
};

pub const ToolInfo = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    inputSchema: std.json.Value = .null,
    annotations: ?ToolAnnotations = null,
};

pub const CallResult = struct {
    content: []const Content = &.{},
    isError: bool = false,
    structuredContent: ?std.json.Value = null,

    // Text blocks joined by newlines.
    pub fn text(self: CallResult, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.content) |c| {
            const t = c.text orelse continue;
            if (out.items.len > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, t);
        }
        return out.toOwnedSlice(allocator);
    }
};
