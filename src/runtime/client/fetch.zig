//! Browser side of `Client.fetchThen`: requests go to JS `fetch()` and complete
//! through `__zx_cb(fetch_success | fetch_error)`.
const std = @import("std");
const builtin = @import("builtin");
const ext = @import("window/extern.zig");
const Client = @import("../core/http/Client.zig");

const is_wasm = builtin.cpu.arch.isWasm();

const max_pending = 64;

const Pending = struct {
    fetch_id: u64,
    context: *anyopaque,
    callback: Client.Callback,
    allocator: std.mem.Allocator,
};

var pending: [max_pending]?Pending = @splat(null);
var next_fetch_id: u64 = 1;

pub fn fetchThen(allocator: std.mem.Allocator, options: Client.FetchOptions, timeout_ms: u32, context: *anyopaque, callback: Client.Callback) void {
    const fetch_id = register(allocator, context, callback) orelse return;

    var headers_json: std.Io.Writer.Allocating = .init(allocator);
    defer headers_json.deinit();
    Client.writeHeadersJson(&headers_json.writer, options.headers) catch {
        complete(fetch_id, error.OutOfMemory);
        return;
    };
    const headers = headers_json.written();
    const method = options.methodName();
    const payload = options.payload orelse "";

    ext._fetchAsync(
        options.url.ptr,
        options.url.len,
        method.ptr,
        method.len,
        headers.ptr,
        headers.len,
        payload.ptr,
        payload.len,
        timeout_ms,
        @backingInt(options.redirect),
        fetch_id,
    );
}

/// Registers a callback for a request another extern sends (e.g. form actions).
/// Returns the id to hand to JS, or null after reporting `TooManyPendingRequests`.
pub fn register(allocator: std.mem.Allocator, context: *anyopaque, callback: Client.Callback) ?u64 {
    for (&pending) |*slot| {
        if (slot.* != null) continue;
        const fetch_id = next_fetch_id;
        next_fetch_id +%= 1;
        slot.* = .{ .fetch_id = fetch_id, .context = context, .callback = callback, .allocator = allocator };
        return fetch_id;
    }
    callback(context, error.TooManyPendingRequests);
    return null;
}

/// Called from `__zx_cb`. `meta` packs the status (low 16 bits) and head length.
/// `bytes` was allocated by JS with the wasm allocator.
pub fn onFetchComplete(fetch_id: u64, meta: u64, bytes: []const u8, is_error: bool) void {
    defer if (is_wasm and bytes.len > 0) std.heap.wasm_allocator.free(bytes);
    const entry = take(fetch_id) orelse return;

    if (is_error) return call(entry, error.NetworkError);

    const status: u16 = @truncate(meta);
    const head_len: usize = @intCast(meta >> 16);
    const owned = entry.allocator.dupe(u8, bytes) catch return call(entry, error.OutOfMemory);
    const result = Client.Result.parse(entry.allocator, @fromBackingInt(@intCast(status)), owned, head_len);
    call(entry, result);
    if (result) |res| res.deinit(entry.allocator) else |_| {}
}

fn complete(fetch_id: u64, err: Client.Error) void {
    const entry = take(fetch_id) orelse return;
    call(entry, err);
}

fn call(entry: Pending, result: Client.Error!Client.Result) void {
    entry.callback(entry.context, result);
}

fn take(fetch_id: u64) ?Pending {
    for (&pending) |*slot| {
        const entry = slot.* orelse continue;
        if (entry.fetch_id != fetch_id) continue;
        slot.* = null;
        return entry;
    }
    return null;
}
