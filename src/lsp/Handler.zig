const Handler = @This();

const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp");
const lang = @import("lang");
const zx_info = @import("zx_info");
const html_hover = @import("features/hover.zig");
const html_complete = @import("features/autocomplete.zig");
const text = @import("text.zig");
pub const Zls = @import("Handler/Zls.zig");

const ByteRange = struct {
    start: usize,
    end: usize,
};

const ZxFileState = struct {
    zig_uri: []const u8,
    source: []const u8,
    zx_block_ranges: []const ByteRange,

    fn deinit(self: *ZxFileState, allocator: std.mem.Allocator) void {
        allocator.free(self.zig_uri);
        allocator.free(self.source);
        allocator.free(self.zx_block_ranges);
    }
};

/// Type-erased backing language server (typically ZLS).
/// ZX-specific features live on `Handler`; Zig IDE features go through this vtable.
pub const VTable = struct {
    destroy: *const fn (ptr: *anyopaque) void,

    /// Handle an LSP request. Write the result into `result` (typed as `lsp.ResultType(method)`).
    /// Noop implementations leave `result` untouched (caller pre-fills a null/empty default).
    request: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        method: []const u8,
        params: *const anyopaque,
        result: *anyopaque,
    ) anyerror!void,

    /// Handle an LSP notification.
    notification: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        method: []const u8,
        params: *const anyopaque,
    ) anyerror!void,

    /// Forward a JSON-RPC response from the client (e.g. workspace/configuration).
    onResponse: *const fn (
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        response: lsp.JsonRPCMessage.Response,
    ) void,
};

fn destroyNoop(_: *anyopaque) void {}

fn requestNoop(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: *const anyopaque,
    _: *anyopaque,
) anyerror!void {}

fn notificationNoop(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: *const anyopaque,
) anyerror!void {}

fn onResponseNoop(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: lsp.JsonRPCMessage.Response,
) void {}

pub const noop_vtable: VTable = .{
    .destroy = destroyNoop,
    .request = requestNoop,
    .notification = notificationNoop,
    .onResponse = onResponseNoop,
};

/// Sentinel backing used when no Zig language server is attached.
pub const noop_ptr: *anyopaque = @ptrFromInt(std.math.maxInt(usize));

allocator: std.mem.Allocator,
transport: *lsp.Transport,
io: std.Io,
offset_encoding: lsp.offsets.Encoding,
zx_files: std.StringHashMap(ZxFileState),
ptr: *anyopaque,
vtable: *const VTable,

pub fn init(
    allocator: std.mem.Allocator,
    transport: *lsp.Transport,
    io: std.Io,
) Handler {
    return .{
        .allocator = allocator,
        .transport = transport,
        .io = io,
        .offset_encoding = .@"utf-16",
        .zx_files = std.StringHashMap(ZxFileState).init(allocator),
        .ptr = noop_ptr,
        .vtable = &noop_vtable,
    };
}

/// Attach a backing LSP (e.g. ZLS). Replaces any previous backing.
pub fn setBacking(handler: *Handler, ptr: *anyopaque, vtable: *const VTable) void {
    if (handler.ptr != noop_ptr) {
        handler.vtable.destroy(handler.ptr);
    }
    handler.ptr = ptr;
    handler.vtable = vtable;
}

pub fn deinit(handler: *Handler) void {
    var it = handler.zx_files.iterator();
    while (it.next()) |entry| {
        handler.allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(handler.allocator);
    }
    handler.zx_files.deinit();
    if (handler.ptr != noop_ptr) {
        handler.vtable.destroy(handler.ptr);
    }
    handler.* = undefined;
}

fn emptyResult(comptime T: type) T {
    if (T == void) return {};
    return switch (@typeInfo(T)) {
        .optional => null,
        .void => {},
        else => @compileError("Handler.emptyResult: unsupported result type " ++ @typeName(T)),
    };
}

fn sendRequestSync(
    handler: *Handler,
    arena: std.mem.Allocator,
    comptime method: []const u8,
    params: lsp.ParamsType(method),
) !lsp.ResultType(method) {
    var result: lsp.ResultType(method) = emptyResult(lsp.ResultType(method));
    try handler.vtable.request(handler.ptr, arena, method, @ptrCast(&params), @ptrCast(&result));
    return result;
}

fn sendNotificationSync(
    handler: *Handler,
    arena: std.mem.Allocator,
    comptime method: []const u8,
    params: lsp.ParamsType(method),
) void {
    handler.vtable.notification(handler.ptr, arena, method, @ptrCast(&params)) catch {};
}

fn isZxUri(uri: []const u8) bool {
    return std.mem.endsWith(u8, uri, ".zx");
}

fn toZigUri(allocator: std.mem.Allocator, zx_uri: []const u8) ![]const u8 {
    return allocator.dupe(u8, zx_uri);
}

fn getZlsUri(handler: *Handler, uri: []const u8) []const u8 {
    _ = handler;
    return uri;
}

fn getEditorUri(handler: *Handler, uri: []const u8) []const u8 {
    _ = handler;
    return uri;
}

fn isByteSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .slice and pointer.child == u8 and pointer.attrs.@"const",
        else => false,
    };
}

fn fieldLooksLikeUri(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "uri") or std.mem.indexOf(u8, name, "Uri") != null;
}

fn remapUrisInValue(handler: *Handler, value: anytype) void {
    const T = @TypeOf(value.*);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |field_name, field_type| {
            const field_ptr = &@field(value.*, field_name);
            if (comptime fieldLooksLikeUri(field_name) and isByteSlice(field_type)) {
                @constCast(field_ptr).* = handler.getEditorUri(field_ptr.*);
            } else {
                handler.remapUrisInValue(field_ptr);
            }
        },
        .@"union" => |info| {
            if (info.tag_type) |Tag| {
                switch (value.*) {
                    inline else => |*payload, tag| {
                        _ = @as(Tag, tag);
                        handler.remapUrisInValue(payload);
                    },
                }
            }
        },
        .optional => {
            if (value.*) |*payload| handler.remapUrisInValue(payload);
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (pointer.child == u8) return;
                for (value.*) |*item| handler.remapUrisInValue(item);
            },
            else => {},
        },
        else => {},
    }
}

fn remapResponseUris(handler: *Handler, result: anytype) @TypeOf(result) {
    var remapped = result;
    handler.remapUrisInValue(&remapped);
    return remapped;
}

fn uriToPath(uri: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, uri, "file://")) return uri[7..];
    return null;
}

/// For each @import("*.zx") in source, ensure the referenced .zx file is opened in the backing LSP.
fn openZxImportsInBacking(handler: *Handler, arena: std.mem.Allocator, document_uri: []const u8, source: []const u8) void {
    const doc_path = uriToPath(document_uri) orelse return;
    const doc_dir = std.fs.path.dirname(doc_path) orelse return;

    const needle = "@import(\"";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, needle)) |start| {
        const path_start = start + needle.len;
        if (std.mem.indexOfPos(u8, source, path_start, "\")")) |path_end| {
            const import_path = source[path_start..path_end];
            if (std.mem.endsWith(u8, import_path, ".zx")) {
                handler.ensureZxFileOpenInBacking(arena, doc_dir, import_path);
            }
            pos = path_end + 2;
        } else break;
    }
}

fn ensureZxFileOpenInBacking(handler: *Handler, arena: std.mem.Allocator, doc_dir: []const u8, rel_path: []const u8) void {
    const joined = std.fs.path.join(handler.allocator, &.{ doc_dir, rel_path }) catch return;
    defer handler.allocator.free(joined);

    const resolved_path = switch (builtin.os.tag) {
        .wasi, .freestanding => handler.allocator.dupe(u8, joined) catch return,
        else => std.Io.Dir.cwd().realPathFileAlloc(handler.io, joined, handler.allocator) catch return,
    };
    defer handler.allocator.free(resolved_path);

    const zx_uri = std.fmt.allocPrint(handler.allocator, "file://{s}", .{resolved_path}) catch return;
    defer handler.allocator.free(zx_uri);

    if (handler.zx_files.contains(zx_uri)) return;

    const content = std.Io.Dir.cwd().readFileAlloc(handler.io, resolved_path, handler.allocator, .limited(4 * 1024 * 1024)) catch return;
    defer handler.allocator.free(content);

    handler.storeAndDiagnose(zx_uri, content);

    const zig_uri = handler.getZlsUri(zx_uri);

    const source_z = handler.allocator.dupeSentinel(u8, content, 0) catch return;
    defer handler.allocator.free(source_z);

    var parse_result = lang.Ast.parse(handler.allocator, source_z, .{}) catch null;
    defer if (parse_result) |*r| r.deinit(handler.allocator);

    const backing_text: []const u8 = if (parse_result) |r| r.zig_source else content;

    handler.openZxImportsInBacking(arena, zx_uri, content);

    handler.sendNotificationSync(arena, "textDocument/didOpen", .{
        .textDocument = .{
            .uri = zig_uri,
            .languageId = .{ .custom_value = "zig" },
            .version = @as(i32, 0),
            .text = backing_text,
        },
    });
}

fn storeAndDiagnose(handler: *Handler, uri: []const u8, source: []const u8) void {
    const source_z = handler.allocator.dupeSentinel(u8, source, 0) catch return;
    defer handler.allocator.free(source_z);

    var result = lang.Ast.parse(handler.allocator, source_z, .{}) catch return;
    defer result.deinit(handler.allocator);

    handler.publishZxDiagnostics(uri, source, result.diagnostics) catch {};

    const zx_block_ranges = handler.collectZxBlockRanges(source) catch (handler.allocator.alloc(ByteRange, 0) catch return);

    const zig_uri = toZigUri(handler.allocator, uri) catch return;
    const uri_key = handler.allocator.dupe(u8, uri) catch {
        handler.allocator.free(zx_block_ranges);
        handler.allocator.free(zig_uri);
        return;
    };
    const source_owned = handler.allocator.dupe(u8, source) catch {
        handler.allocator.free(zx_block_ranges);
        handler.allocator.free(zig_uri);
        handler.allocator.free(uri_key);
        return;
    };

    if (handler.zx_files.fetchRemove(uri)) |old| {
        handler.allocator.free(old.key);
        var old_state = old.value;
        old_state.deinit(handler.allocator);
    }

    handler.zx_files.put(uri_key, .{
        .zig_uri = zig_uri,
        .source = source_owned,
        .zx_block_ranges = zx_block_ranges,
    }) catch {
        handler.allocator.free(zx_block_ranges);
        handler.allocator.free(zig_uri);
        handler.allocator.free(uri_key);
        handler.allocator.free(source_owned);
    };
}

fn collectZxBlockRanges(handler: *Handler, source: []const u8) ![]const ByteRange {
    var parse = try lang.Parse.parse(handler.allocator, source, .zx);
    defer parse.deinit(handler.allocator);

    var ranges = std.ArrayList(ByteRange).empty;
    defer ranges.deinit(handler.allocator);

    try collectZxBlockRangesNode(parse.tree.rootNode(), &ranges, handler.allocator);
    return try ranges.toOwnedSlice(handler.allocator);
}

fn collectZxBlockRangesNode(node: anytype, ranges: *std.ArrayList(ByteRange), allocator: std.mem.Allocator) !void {
    if (lang.Parse.NodeKind.fromNode(node) == .zx_block) {
        try ranges.append(allocator, .{
            .start = node.startByte(),
            .end = node.endByte(),
        });
        return;
    }

    const child_count = node.childCount();
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = node.child(i) orelse continue;
        try collectZxBlockRangesNode(child, ranges, allocator);
    }
}

fn offsetInAnyRange(offset: usize, ranges: []const ByteRange) bool {
    for (ranges) |range| {
        if (offset >= range.start and offset < range.end) return true;
    }
    return false;
}

fn filterInlayHintsForZxBlocks(
    arena: std.mem.Allocator,
    hints: []const lsp.types.flat.InlayHint,
    state: *const ZxFileState,
    encoding: lsp.offsets.Encoding,
) ![]const lsp.types.flat.InlayHint {
    if (hints.len == 0 or state.zx_block_ranges.len == 0) return hints;

    var filtered = std.ArrayList(lsp.types.flat.InlayHint).empty;
    defer filtered.deinit(arena);
    try filtered.ensureTotalCapacity(arena, hints.len);

    for (hints) |hint| {
        const offset = text.positionToOffset(state.source, hint.position, encoding);

        if (offsetInAnyRange(offset, state.zx_block_ranges)) continue;
        try filtered.append(arena, hint);
    }

    return try filtered.toOwnedSlice(arena);
}

fn publishZxDiagnostics(handler: *Handler, uri: []const u8, source: []const u8, diag_list: lang.Ast.check.DiagnosticList) !void {
    var aa = std.heap.ArenaAllocator.init(handler.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    const encoding = handler.offset_encoding;
    const lsp_diags = try arena.alloc(lsp.types.flat.Diagnostic, diag_list.items.len);
    for (diag_list.items, 0..) |d, i| {
        lsp_diags[i] = .{
            .range = .{
                .start = text.byteColumnToPosition(source, d.start_line, d.start_column, encoding),
                .end = text.byteColumnToPosition(source, d.end_line, d.end_column, encoding),
            },
            .severity = switch (d.severity) {
                .err => .Error,
                .warning => .Warning,
            },
            .source = "zx",
            .message = .{ .string = d.message },
        };
    }

    handler.transport.writeNotification(
        handler.io,
        arena,
        "textDocument/publishDiagnostics",
        lsp.types.flat.PublishDiagnosticsParams,
        .{ .uri = uri, .diagnostics = lsp_diags },
        .{ .emit_null_optional_fields = false },
    ) catch |err| {
        std.log.err("Failed to write publishDiagnostics: {}", .{err});
    };
}

fn remapUri(handler: *Handler, comptime T: type, params: T) T {
    if (!isZxUri(params.textDocument.uri)) return params;
    var new_params = params;
    new_params.textDocument = .{ .uri = handler.getZlsUri(params.textDocument.uri) };
    return new_params;
}

fn zxServerCapabilities(position_encoding: lsp.types.flat.PositionEncodingKind) lsp.types.flat.ServerCapabilities {
    return .{
        .positionEncoding = position_encoding,
        .textDocumentSync = .{
            .text_document_sync_options = .{
                .openClose = true,
                .change = .Incremental,
                .save = .{ .bool = true },
            },
        },
        .hoverProvider = .{ .bool = true },
        .completionProvider = .{
            .triggerCharacters = &.{ "<", "/", " ", "@", "\"" },
        },
        .documentFormattingProvider = .{ .bool = true },
    };
}

fn mergeCapabilities(base: lsp.types.flat.ServerCapabilities, zx: lsp.types.flat.ServerCapabilities) lsp.types.flat.ServerCapabilities {
    var merged = base;
    if (zx.positionEncoding) |enc| merged.positionEncoding = enc;
    if (zx.textDocumentSync) |sync| merged.textDocumentSync = sync;
    if (zx.hoverProvider) |hover| merged.hoverProvider = hover;
    if (zx.completionProvider) |completion| merged.completionProvider = completion;
    if (zx.documentFormattingProvider) |fmt| merged.documentFormattingProvider = fmt;
    return merged;
}

// -- Lifecycle handlers --

pub fn initialize(
    handler: *Handler,
    arena: std.mem.Allocator,
    request: lsp.types.flat.InitializeParams,
) lsp.types.flat.InitializeResult {
    const client_encoding = choosePositionEncodingKind(request);
    handler.offset_encoding = toOffsetEncoding(client_encoding);

    var backing_request = request;
    if (backing_request.capabilities.textDocument) |*text_document| {
        text_document.publishDiagnostics = null;
    }
    if (backing_request.capabilities.general) |*general| {
        general.positionEncodings = &.{client_encoding};
    }

    const zx_caps = zxServerCapabilities(client_encoding);

    // initialize is non-optional; ask backing via a specialized path.
    var backing_result: lsp.types.flat.InitializeResult = .{
        .serverInfo = .{ .name = "ziex", .version = zx_info.version },
        .capabilities = .{},
    };
    handler.vtable.request(
        handler.ptr,
        arena,
        "initialize",
        @ptrCast(&backing_request),
        @ptrCast(&backing_result),
    ) catch {};

    backing_result.serverInfo = .{ .name = "ziex", .version = zx_info.version };
    backing_result.capabilities = mergeCapabilities(backing_result.capabilities, zx_caps);
    return backing_result;
}

fn choosePositionEncodingKind(request: lsp.types.flat.InitializeParams) lsp.types.flat.PositionEncodingKind {
    if (request.capabilities.general) |general| {
        if (general.positionEncodings) |encodings| {
            for (encodings) |encoding| {
                if (encoding == .@"utf-16") return .@"utf-16";
            }
            for (encodings) |encoding| {
                if (encoding == .@"utf-8") return .@"utf-8";
            }
            for (encodings) |encoding| {
                switch (encoding) {
                    .@"utf-32" => return .@"utf-32",
                    .custom_value => return .@"utf-16",
                    else => {},
                }
            }
        }
    }

    return .@"utf-16";
}

fn toOffsetEncoding(encoding: lsp.types.flat.PositionEncodingKind) lsp.offsets.Encoding {
    return switch (encoding) {
        .@"utf-8" => .@"utf-8",
        .@"utf-16" => .@"utf-16",
        .@"utf-32" => .@"utf-32",
        .custom_value => .@"utf-16",
    };
}

pub fn initialized(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.InitializedParams,
) void {
    handler.sendNotificationSync(arena, "initialized", params);
}

pub fn shutdown(
    handler: *Handler,
    arena: std.mem.Allocator,
    _: void,
) ?void {
    return handler.sendRequestSync(arena, "shutdown", {}) catch null;
}

pub fn exit(
    handler: *Handler,
    arena: std.mem.Allocator,
    _: void,
) void {
    handler.sendNotificationSync(arena, "exit", {});
}

// -- Document sync --

pub fn @"textDocument/didOpen"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DidOpenTextDocumentParams,
) !void {
    if (isZxUri(params.textDocument.uri)) {
        handler.storeAndDiagnose(params.textDocument.uri, params.textDocument.text);
        const zig_uri = handler.getZlsUri(params.textDocument.uri);

        handler.openZxImportsInBacking(arena, params.textDocument.uri, params.textDocument.text);

        handler.sendNotificationSync(arena, "textDocument/didOpen", .{
            .textDocument = .{
                .uri = zig_uri,
                .languageId = .{ .custom_value = "zig" },
                .version = params.textDocument.version,
                .text = params.textDocument.text,
            },
        });
        return;
    }
    handler.sendNotificationSync(arena, "textDocument/didOpen", params);
}

pub fn @"textDocument/didChange"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DidChangeTextDocumentParams,
) !void {
    if (isZxUri(params.textDocument.uri)) {
        const current_source = if (handler.zx_files.get(params.textDocument.uri)) |state|
            state.source
        else
            "";

        var full_text: []const u8 = current_source;
        var needs_free = false;
        defer if (needs_free) handler.allocator.free(full_text);

        for (params.contentChanges) |change| {
            switch (change) {
                .text_document_content_change_whole_document => |full| {
                    if (needs_free) handler.allocator.free(full_text);
                    full_text = full.text;
                    needs_free = false;
                },
                .text_document_content_change_partial => |inc| {
                    const new_text = text.applyIncrementalChange(
                        handler.allocator,
                        full_text,
                        inc.range,
                        inc.text,
                        handler.offset_encoding,
                    ) catch {
                        continue;
                    };
                    if (needs_free) handler.allocator.free(full_text);
                    full_text = new_text;
                    needs_free = true;
                },
            }
        }

        handler.storeAndDiagnose(params.textDocument.uri, full_text);
        handler.openZxImportsInBacking(arena, params.textDocument.uri, full_text);

        const zig_uri = handler.getZlsUri(params.textDocument.uri);
        handler.sendNotificationSync(arena, "textDocument/didChange", .{
            .textDocument = .{
                .uri = zig_uri,
                .version = params.textDocument.version,
            },
            .contentChanges = &.{.{ .text_document_content_change_whole_document = .{ .text = full_text } }},
        });
        return;
    }
    handler.sendNotificationSync(arena, "textDocument/didChange", params);
}

pub fn @"textDocument/didSave"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DidSaveTextDocumentParams,
) !void {
    if (isZxUri(params.textDocument.uri)) {
        handler.sendNotificationSync(arena, "textDocument/didSave", .{
            .textDocument = .{ .uri = handler.getZlsUri(params.textDocument.uri) },
            .text = params.text,
        });
        return;
    }
    handler.sendNotificationSync(arena, "textDocument/didSave", params);
}

pub fn @"textDocument/didClose"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DidCloseTextDocumentParams,
) !void {
    if (isZxUri(params.textDocument.uri)) {
        handler.transport.writeNotification(
            handler.io,
            arena,
            "textDocument/publishDiagnostics",
            lsp.types.flat.PublishDiagnosticsParams,
            .{ .uri = params.textDocument.uri, .diagnostics = &.{} },
            .{ .emit_null_optional_fields = false },
        ) catch {};

        if (handler.zx_files.fetchRemove(params.textDocument.uri)) |old| {
            const zig_uri = old.value.zig_uri;
            handler.sendNotificationSync(arena, "textDocument/didClose", .{
                .textDocument = .{ .uri = zig_uri },
            });
            handler.allocator.free(old.key);
            var state = old.value;
            state.deinit(handler.allocator);
            return;
        }
    }
    handler.sendNotificationSync(arena, "textDocument/didClose", params);
}

// -- Request handlers --

pub fn @"textDocument/hover"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.HoverParams,
) ?lsp.types.flat.Hover {
    if (isZxUri(params.textDocument.uri)) {
        if (handler.htmlHover(arena, params)) |hover| return hover;
    }

    const mapped = handler.remapUri(lsp.types.flat.HoverParams, params);
    return handler.sendRequestSync(arena, "textDocument/hover", mapped) catch null;
}

fn htmlHover(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.HoverParams,
) ?lsp.types.flat.Hover {
    const state = handler.zx_files.get(params.textDocument.uri) orelse return null;
    const offset = text.positionToOffset(state.source, params.position, handler.offset_encoding);

    const result = html_hover.hover(arena, state.source, @intCast(offset)) catch return null;
    const hover = result orelse return null;

    return .{
        .contents = .{
            .markup_content = .{
                .kind = .markdown,
                .value = hover.markdown,
            },
        },
        .range = .{
            .start = text.offsetToPosition(state.source, hover.start_byte, handler.offset_encoding),
            .end = text.offsetToPosition(state.source, hover.end_byte, handler.offset_encoding),
        },
    };
}

pub fn @"textDocument/completion"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.CompletionParams,
) error{OutOfMemory}!lsp.ResultType("textDocument/completion") {
    if (isZxUri(params.textDocument.uri)) {
        if (handler.htmlComplete(arena, params)) |result| return result;
    }

    const mapped = handler.remapUri(lsp.types.flat.CompletionParams, params);
    return handler.sendRequestSync(arena, "textDocument/completion", mapped) catch null;
}

fn htmlComplete(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.CompletionParams,
) ?lsp.types.completion.Result {
    const state = handler.zx_files.get(params.textDocument.uri) orelse return null;
    const offset = text.positionToOffset(state.source, params.position, handler.offset_encoding);
    return html_complete.complete(arena, state.source, @intCast(offset)) catch null;
}

pub fn @"textDocument/signatureHelp"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.SignatureHelpParams,
) error{OutOfMemory}!?lsp.types.flat.SignatureHelp {
    const mapped = handler.remapUri(lsp.types.flat.SignatureHelpParams, params);
    return handler.sendRequestSync(arena, "textDocument/signatureHelp", mapped) catch null;
}

pub fn @"textDocument/definition"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DefinitionParams,
) error{OutOfMemory}!lsp.ResultType("textDocument/definition") {
    const mapped = handler.remapUri(lsp.types.flat.DefinitionParams, params);
    const result = handler.sendRequestSync(arena, "textDocument/definition", mapped) catch null;
    return handler.remapResponseUris(result);
}

pub fn @"textDocument/typeDefinition"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.TypeDefinitionParams,
) error{OutOfMemory}!lsp.ResultType("textDocument/typeDefinition") {
    const mapped = handler.remapUri(lsp.types.flat.TypeDefinitionParams, params);
    const result = handler.sendRequestSync(arena, "textDocument/typeDefinition", mapped) catch null;
    return handler.remapResponseUris(result);
}

pub fn @"textDocument/implementation"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.ImplementationParams,
) error{OutOfMemory}!lsp.ResultType("textDocument/implementation") {
    const mapped = handler.remapUri(lsp.types.flat.ImplementationParams, params);
    const result = handler.sendRequestSync(arena, "textDocument/implementation", mapped) catch null;
    return handler.remapResponseUris(result);
}

pub fn @"textDocument/declaration"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DeclarationParams,
) error{OutOfMemory}!lsp.ResultType("textDocument/declaration") {
    const mapped = handler.remapUri(lsp.types.flat.DeclarationParams, params);
    const result = handler.sendRequestSync(arena, "textDocument/declaration", mapped) catch null;
    return handler.remapResponseUris(result);
}

pub fn @"textDocument/prepareRename"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.PrepareRenameParams,
) ?lsp.types.flat.PrepareRenameResult {
    const mapped = handler.remapUri(lsp.types.flat.PrepareRenameParams, params);
    return handler.sendRequestSync(arena, "textDocument/prepareRename", mapped) catch null;
}

pub fn @"textDocument/rename"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.RenameParams,
) error{OutOfMemory}!?lsp.types.flat.WorkspaceEdit {
    const mapped = handler.remapUri(lsp.types.flat.RenameParams, params);
    const result = handler.sendRequestSync(arena, "textDocument/rename", mapped) catch null;
    return handler.remapResponseUris(result);
}

pub fn @"textDocument/references"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.ReferenceParams,
) error{OutOfMemory}!?[]const lsp.types.flat.Location {
    const mapped = handler.remapUri(lsp.types.flat.ReferenceParams, params);
    const result = handler.sendRequestSync(arena, "textDocument/references", mapped) catch null;
    return handler.remapResponseUris(result);
}

pub fn @"textDocument/documentHighlight"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DocumentHighlightParams,
) error{OutOfMemory}!?[]const lsp.types.flat.DocumentHighlight {
    const mapped = handler.remapUri(lsp.types.flat.DocumentHighlightParams, params);
    return handler.sendRequestSync(arena, "textDocument/documentHighlight", mapped) catch null;
}

pub fn @"textDocument/willSaveWaitUntil"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.WillSaveTextDocumentParams,
) error{OutOfMemory}!?[]const lsp.types.flat.TextEdit {
    return handler.sendRequestSync(arena, "textDocument/willSaveWaitUntil", params) catch null;
}

pub fn @"textDocument/semanticTokens/full"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.SemanticTokensParams,
) error{OutOfMemory}!?lsp.types.flat.SemanticTokens {
    if (isZxUri(params.textDocument.uri)) {
        var new_params = params;
        new_params.textDocument = .{ .uri = handler.getZlsUri(params.textDocument.uri) };
        return handler.sendRequestSync(arena, "textDocument/semanticTokens/full", new_params) catch null;
    }
    return handler.sendRequestSync(arena, "textDocument/semanticTokens/full", params) catch null;
}

pub fn @"textDocument/semanticTokens/range"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.SemanticTokensRangeParams,
) error{OutOfMemory}!?lsp.types.flat.SemanticTokens {
    return handler.sendRequestSync(arena, "textDocument/semanticTokens/range", params) catch null;
}

pub fn @"textDocument/inlayHint"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.InlayHintParams,
) error{OutOfMemory}!?[]const lsp.types.flat.InlayHint {
    if (isZxUri(params.textDocument.uri)) {
        var new_params = params;
        new_params.textDocument = .{ .uri = handler.getZlsUri(params.textDocument.uri) };
        const hints = handler.sendRequestSync(arena, "textDocument/inlayHint", new_params) catch null;
        if (hints) |backing_hints| {
            if (handler.zx_files.get(params.textDocument.uri)) |state| {
                return try filterInlayHintsForZxBlocks(arena, backing_hints, &state, handler.offset_encoding);
            }
        }
        return hints;
    }
    return handler.sendRequestSync(arena, "textDocument/inlayHint", params) catch null;
}

pub fn @"textDocument/documentSymbol"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DocumentSymbolParams,
) error{OutOfMemory}!lsp.ResultType("textDocument/documentSymbol") {
    if (isZxUri(params.textDocument.uri)) {
        var new_params = params;
        new_params.textDocument = .{ .uri = handler.getZlsUri(params.textDocument.uri) };
        return handler.sendRequestSync(arena, "textDocument/documentSymbol", new_params) catch null;
    }
    return handler.sendRequestSync(arena, "textDocument/documentSymbol", params) catch null;
}

pub fn @"textDocument/formatting"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DocumentFormattingParams,
) error{OutOfMemory}!?[]const lsp.types.flat.TextEdit {
    if (isZxUri(params.textDocument.uri)) {
        if (handler.zx_files.get(params.textDocument.uri)) |state| {
            const source_z = try handler.allocator.dupeSentinel(u8, state.source, 0);
            defer handler.allocator.free(source_z);

            var format_result = lang.Ast.fmt(handler.allocator, source_z) catch |err| {
                std.log.err("lang.Ast.fmt failed for {s}: {s}", .{ params.textDocument.uri, @errorName(err) });
                return null;
            };
            defer format_result.deinit(handler.allocator);

            const formatted = format_result.source orelse return null;
            if (std.mem.eql(u8, formatted, state.source)) {
                return null;
            }

            const end = text.offsetToPosition(state.source, state.source.len, handler.offset_encoding);
            const edits = try arena.alloc(lsp.types.flat.TextEdit, 1);
            edits[0] = .{
                .range = .{
                    .start = .{ .line = 0, .character = 0 },
                    .end = end,
                },
                .newText = try arena.dupe(u8, formatted),
            };
            return edits;
        }
    }
    return handler.sendRequestSync(arena, "textDocument/formatting", params) catch null;
}

pub fn @"textDocument/codeAction"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.CodeActionParams,
) error{OutOfMemory}!lsp.ResultType("textDocument/codeAction") {
    if (isZxUri(params.textDocument.uri)) {
        var new_params = params;
        new_params.textDocument = .{ .uri = handler.getZlsUri(params.textDocument.uri) };
        return handler.sendRequestSync(arena, "textDocument/codeAction", new_params) catch null;
    }
    return handler.sendRequestSync(arena, "textDocument/codeAction", params) catch null;
}

pub fn @"textDocument/foldingRange"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.FoldingRangeParams,
) error{OutOfMemory}!?[]const lsp.types.flat.FoldingRange {
    if (isZxUri(params.textDocument.uri)) {
        var new_params = params;
        new_params.textDocument = .{ .uri = handler.getZlsUri(params.textDocument.uri) };
        return handler.sendRequestSync(arena, "textDocument/foldingRange", new_params) catch null;
    }
    return handler.sendRequestSync(arena, "textDocument/foldingRange", params) catch null;
}

pub fn @"textDocument/selectionRange"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.SelectionRangeParams,
) error{OutOfMemory}!?[]const lsp.types.flat.SelectionRange {
    return handler.sendRequestSync(arena, "textDocument/selectionRange", params) catch null;
}

pub fn @"workspace/didChangeWatchedFiles"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DidChangeWatchedFilesParams,
) !void {
    handler.sendNotificationSync(arena, "workspace/didChangeWatchedFiles", params);
}

pub fn @"workspace/didChangeWorkspaceFolders"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DidChangeWorkspaceFoldersParams,
) !void {
    handler.sendNotificationSync(arena, "workspace/didChangeWorkspaceFolders", params);
}

pub fn @"workspace/didChangeConfiguration"(
    handler: *Handler,
    arena: std.mem.Allocator,
    params: lsp.types.flat.DidChangeConfigurationParams,
) !void {
    handler.sendNotificationSync(arena, "workspace/didChangeConfiguration", params);
}

pub fn onResponse(
    handler: *Handler,
    arena: std.mem.Allocator,
    response: lsp.JsonRPCMessage.Response,
) void {
    handler.vtable.onResponse(handler.ptr, arena, response);
}
