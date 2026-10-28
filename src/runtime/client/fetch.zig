const std = @import("std");
const builtin = @import("builtin");
const window = @import("window.zig");
const ext = @import("window/extern.zig");
const Fetch = @import("../core/Fetch.zig");

const Response = Fetch.Response;
const Headers = Fetch.Headers;
const RequestInit = Fetch.RequestInit;
const ResponseCallback = Fetch.ResponseCallback;
const ResponseCallbackCtx = Fetch.ResponseCallbackCtx;

pub const is_wasm = window.is_wasm;
const is_wasm_arch = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;
var next_fetch_id: u64 = 1;

/// Perform an async HTTP fetch request with callback.
pub fn fetchAsync(
    allocator: std.mem.Allocator,
    url: []const u8,
    init: RequestInit,
    callback: ResponseCallback,
) void {
    const fetch_id = next_fetch_id;
    next_fetch_id +%= 1;

    // Store callback in registry
    const slot_index = findOrAllocSlot(fetch_id);
    if (slot_index == null) {
        callback(null, error.TooManyPendingRequests);
        return;
    }

    pending_slots[slot_index.?] = PendingFetch{
        .active = true,
        .fetch_id = fetch_id,
        .callback = callback,
        .allocator = allocator,
    };

    // Serialize request
    const method_str = init.methodName();
    var headers_buf: [8192]u8 = undefined;
    const headers_json = serializeHeadersJson(init.headers, &headers_buf);
    const body = init.body orelse "";

    ext._fetchAsync(
        url.ptr,
        url.len,
        method_str.ptr,
        method_str.len,
        headers_json.ptr,
        headers_json.len,
        body.ptr,
        body.len,
        init.timeout_ms,
        fetch_id,
    );
}

/// Like fetchAsync but the callback receives an opaque context pointer.
pub fn fetchAsyncCtx(
    allocator: std.mem.Allocator,
    url: []const u8,
    init: RequestInit,
    ctx: *anyopaque,
    callback: ResponseCallbackCtx,
) void {
    const fetch_id = next_fetch_id;
    next_fetch_id +%= 1;

    const slot_index = findOrAllocSlot(fetch_id);
    if (slot_index == null) {
        callback(ctx, null, error.TooManyPendingRequests);
        return;
    }

    pending_slots[slot_index.?] = PendingFetch{
        .active = true,
        .fetch_id = fetch_id,
        .callback_ctx_fn = callback,
        .callback_ctx = ctx,
        .allocator = allocator,
    };

    const method_str = init.methodName();
    var headers_buf: [8192]u8 = undefined;
    const headers_json = serializeHeadersJson(init.headers, &headers_buf);
    const body = init.body orelse "";

    ext._fetchAsync(
        url.ptr,
        url.len,
        method_str.ptr,
        method_str.len,
        headers_json.ptr,
        headers_json.len,
        body.ptr,
        body.len,
        init.timeout_ms,
        fetch_id,
    );
}

const MAX_PENDING = 64;

const PendingFetch = struct {
    active: bool = false,
    fetch_id: u64 = 0,
    callback: ?ResponseCallback = null,
    callback_ctx_fn: ?ResponseCallbackCtx = null,
    callback_ctx: ?*anyopaque = null,
    allocator: std.mem.Allocator = undefined,
};

var pending_slots: [MAX_PENDING]PendingFetch = @splat(PendingFetch{});

fn findOrAllocSlot(fetch_id: u64) ?usize {
    const preferred: usize = @intCast(fetch_id % MAX_PENDING);
    if (!pending_slots[preferred].active) {
        return preferred;
    }
    for (&pending_slots, 0..) |*slot, i| {
        if (!slot.active) return i;
    }
    return null;
}

fn findSlotByFetchId(fetch_id: u64) ?usize {
    const preferred: usize = @intCast(fetch_id % MAX_PENDING);
    if (pending_slots[preferred].active and pending_slots[preferred].fetch_id == fetch_id) {
        return preferred;
    }
    for (&pending_slots, 0..) |*slot, i| {
        if (slot.active and slot.fetch_id == fetch_id) return i;
    }
    return null;
}

/// Allocate a pending fetch slot and register a ctx callback without firing _fetchAsync.
/// Returns the fetch_id to pass to a custom extern (e.g. _submitFormActionAsync).
/// The callback will be invoked when `__zx_cb(fetch_*)` arrives for that id.
pub fn allocFetchId(
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    callback: ResponseCallbackCtx,
) ?u64 {
    const fetch_id = next_fetch_id;
    next_fetch_id +%= 1;

    const slot_index = findOrAllocSlot(fetch_id) orelse {
        callback(ctx, null, error.TooManyPendingRequests);
        return null;
    };

    pending_slots[slot_index] = PendingFetch{
        .active = true,
        .fetch_id = fetch_id,
        .callback_ctx_fn = callback,
        .callback_ctx = ctx,
        .allocator = allocator,
    };
    return fetch_id;
}

/// Called via `__zx_cb` when async fetch completes.
pub fn onFetchComplete(
    fetch_id: u64,
    status_code: u16,
    body_ptr: [*]const u8,
    body_len: usize,
    is_error: u8,
) void {
    const slot_idx = findSlotByFetchId(fetch_id) orelse return;
    var slot = &pending_slots[slot_idx];

    // Must have at least one callback registered.
    if (slot.callback == null and slot.callback_ctx_fn == null) return;

    const allocator = slot.allocator;
    const plain_cb = slot.callback;
    const ctx_cb = slot.callback_ctx_fn;
    const ctx_ptr = slot.callback_ctx;

    slot.active = false;
    slot.callback = null;
    slot.callback_ctx_fn = null;
    slot.callback_ctx = null;

    // Helper to dispatch errors to whichever callback is registered.
    const dispatchErr = struct {
        fn call(pcb: ?ResponseCallback, ccb: ?ResponseCallbackCtx, cp: ?*anyopaque, err: Fetch.Error) void {
            if (ccb) |cb| cb(cp.?, null, err) else if (pcb) |cb| cb(null, err);
        }
    }.call;

    if (is_error != 0) {
        dispatchErr(plain_cb, ctx_cb, ctx_ptr, error.NetworkError);
        return;
    }

    // Copy body data
    const body_data = if (body_len > 0)
        allocator.dupe(u8, body_ptr[0..body_len]) catch {
            if (comptime is_wasm_arch) {
                std.heap.wasm_allocator.free(body_ptr[0..body_len]);
            }
            dispatchErr(plain_cb, ctx_cb, ctx_ptr, error.OutOfMemory);
            return;
        }
    else
        @as([]const u8, "");

    if (body_len > 0) {
        if (comptime is_wasm_arch) {
            std.heap.wasm_allocator.free(body_ptr[0..body_len]);
        }
    }

    // Allocate Response on heap
    const response = allocator.create(Response) catch {
        if (body_data.len > 0) allocator.free(body_data);
        dispatchErr(plain_cb, ctx_cb, ctx_ptr, error.OutOfMemory);
        return;
    };

    response.* = Response{
        .status = status_code,
        .status_text = statusText(status_code),
        .headers = Headers.init(allocator),
        ._body = body_data,
        ._body_used = false,
        ._allocator = allocator,
        ._owns_memory = true,
    };

    if (ctx_cb) |cb| {
        cb(ctx_ptr.?, response, null);
    } else if (plain_cb) |cb| {
        cb(response, null);
    }
}

fn serializeHeadersJson(headers: ?[]const RequestInit.Header, buf: []u8) []const u8 {
    var len: usize = 0;
    buf[len] = '{';
    len += 1;

    if (headers) |hdrs| {
        for (hdrs, 0..) |h, i| {
            if (i > 0) {
                buf[len] = ',';
                len += 1;
            }
            buf[len] = '"';
            len += 1;
            const name_end = @min(len + h.name.len, buf.len - 10);
            @memcpy(buf[len..name_end], h.name[0..@min(h.name.len, name_end - len)]);
            len = name_end;
            buf[len] = '"';
            len += 1;
            buf[len] = ':';
            len += 1;
            buf[len] = '"';
            len += 1;
            const val_end = @min(len + h.value.len, buf.len - 2);
            @memcpy(buf[len..val_end], h.value[0..@min(h.value.len, val_end - len)]);
            len = val_end;
            buf[len] = '"';
            len += 1;
        }
    }

    buf[len] = '}';
    len += 1;
    return buf[0..len];
}

fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        500 => "Internal Server Error",
        else => "Unknown",
    };
}
