const std = @import("std");
const Fetch = @import("../core/Fetch.zig");

const Response = Fetch.Response;
const Headers = Fetch.Headers;
const RequestInit = Fetch.RequestInit;

/// Perform an HTTP fetch request using std.http.Client.
pub fn fetch(allocator: std.mem.Allocator, url: []const u8, init: RequestInit) Fetch.Error!Response {
    if (init.method_name) |method_name| return fetchCustomMethod(allocator, url, method_name, init);

    // Create HTTP client
    var client: std.http.Client = .{ .allocator = allocator, .io = std.Io.Threaded.global_single_threaded.io() };
    defer client.deinit();

    // Build extra headers as a slice
    var extra_headers_buf: [64]std.http.Header = undefined;
    var extra_headers_len: usize = 0;

    if (init.headers) |headers| {
        for (headers) |h| {
            if (extra_headers_len >= extra_headers_buf.len) break;
            extra_headers_buf[extra_headers_len] = .{ .name = h.name, .value = h.value };
            extra_headers_len += 1;
        }
    }

    const extra_headers = extra_headers_buf[0..extra_headers_len];

    // Create a buffer to collect the response body
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    // Perform the fetch
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = init.method,
        .payload = init.body,
        .extra_headers = extra_headers,
        .redirect_behavior = if (init.follow_redirects) @fromBackingInt(@intCast(3)) else .unhandled,
        .response_writer = &aw.writer,
    }) catch return error.NetworkError;

    // Get status
    const status: u16 = @backingInt(result.status);
    const status_text = result.status.phrase() orelse "Unknown";

    // Get the body - duplicate it since aw will be deferred
    const body = allocator.dupe(u8, aw.written()) catch return error.OutOfMemory;

    return Response{
        .status = status,
        .status_text = status_text,
        .headers = Headers.init(allocator),
        ._body = body,
        ._body_used = false,
        ._allocator = allocator,
        ._owns_memory = true,
    };
}

fn fetchCustomMethod(allocator: std.mem.Allocator, url: []const u8, method_name: []const u8, init: RequestInit) Fetch.Error!Response {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    var client: std.http.Client = .{ .allocator = allocator, .io = std.Io.Threaded.global_single_threaded.io() };
    defer client.deinit();

    // `.POST` only shapes how the response is read (it always has a body).
    var req = client.request(.POST, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    }) catch return error.NetworkError;
    defer req.deinit();

    const body = init.body orelse "";
    const connection = req.connection orelse return error.NetworkError;
    const w = connection.writer();
    writeHead(w, uri, method_name, init.headers, body.len) catch return error.NetworkError;
    w.writeAll(body) catch return error.NetworkError;
    connection.flush() catch return error.NetworkError;

    var response = req.receiveHead(&.{}) catch return error.NetworkError;
    const status: u16 = @backingInt(response.head.status);
    const status_text = response.head.status.phrase() orelse "Unknown";

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    _ = reader.streamRemaining(&aw.writer) catch return error.NetworkError;

    return Response{
        .status = status,
        .status_text = status_text,
        .headers = Headers.init(allocator),
        ._body = allocator.dupe(u8, aw.written()) catch return error.OutOfMemory,
        ._body_used = false,
        ._allocator = allocator,
        ._owns_memory = true,
    };
}

fn writeHead(
    w: *std.Io.Writer,
    uri: std.Uri,
    method_name: []const u8,
    headers: ?[]const RequestInit.Header,
    content_length: usize,
) std.Io.Writer.Error!void {
    try w.writeAll(method_name);
    try w.writeByte(' ');
    if (uri.path.isEmpty()) try w.writeByte('/');
    try uri.writeToStream(w, .{ .path = true, .query = true });
    try w.writeAll(" HTTP/1.1\r\nhost: ");
    try uri.writeToStream(w, .{ .authority = true });
    try w.print("\r\nconnection: close\r\ncontent-length: {d}\r\n", .{content_length});
    if (headers) |hs| for (hs) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    try w.writeAll("\r\n");
}
