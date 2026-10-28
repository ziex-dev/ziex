const std = @import("std");
const Fetch = @import("../Fetch.zig");
const zxon = @import("../../../util/zxon.zig");

const Response = Fetch.Response;
const Headers = Fetch.Headers;
const RequestInit = Fetch.RequestInit;

const max_response_bytes = 16 * 1024 * 1024;

pub fn fetch(allocator: std.mem.Allocator, url: []const u8, init: RequestInit) Fetch.Error!Response {
    const method = init.methodName();
    const body = init.body orelse "";

    var headers_json: std.Io.Writer.Allocating = .init(allocator);
    defer headers_json.deinit();
    writeHeadersJson(&headers_json.writer, init.headers) catch return error.OutOfMemory;
    const headers = headers_json.written();

    var status: u16 = 0;
    var buf = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(buf);

    const len: usize = while (true) {
        const n = ext.fetch(
            url.ptr,
            url.len,
            method.ptr,
            method.len,
            headers.ptr,
            headers.len,
            body.ptr,
            body.len,
            init.timeout_ms,
            &status,
            buf.ptr,
            buf.len,
        );
        switch (n) {
            // Didn't fit: grow and retry.
            -2 => {
                if (buf.len * 2 > max_response_bytes) return error.InvalidResponse;
                buf = try allocator.realloc(buf, buf.len * 2);
            },
            else => if (n < 0) return error.NetworkError else break @intCast(n),
        }
    };

    return Response{
        .status = status,
        .status_text = (@as(std.http.Status, @enumFromInt(status))).phrase() orelse "Unknown",
        .headers = Headers.init(allocator),
        ._body = try allocator.dupe(u8, buf[0..len]),
        ._body_used = false,
        ._allocator = allocator,
        ._owns_memory = true,
    };
}

fn writeHeadersJson(writer: *std.Io.Writer, headers: ?[]const RequestInit.Header) std.Io.Writer.Error!void {
    try writer.writeByte('{');
    for (headers orelse &.{}, 0..) |h, i| {
        if (i > 0) try writer.writeByte(',');
        zxon.serialize(h.name, writer, .{}) catch return error.WriteFailed;
        try writer.writeByte(':');
        zxon.serialize(h.value, writer, .{}) catch return error.WriteFailed;
    }
    try writer.writeByte('}');
}

const ext = struct {
    extern "__zx_net" fn fetch(
        url_ptr: [*]const u8,
        url_len: usize,
        method_ptr: [*]const u8,
        method_len: usize,
        headers_ptr: [*]const u8,
        headers_len: usize,
        body_ptr: [*]const u8,
        body_len: usize,
        timeout_ms: u32,
        status_out: *u16,
        buf_ptr: [*]u8,
        buf_max: usize,
    ) i32;
};
