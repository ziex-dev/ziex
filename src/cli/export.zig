const std = @import("std");
const builtin = @import("builtin");

const util = @import("shared/util.zig");
const context = @import("shared/context.zig");
const Server = @import("../runtime/server/Server.zig");
const options_mod = @import("../runtime/core/App/Router/options.zig");
const DevServer = @import("dev/DevServer.zig");
const tui = @import("../tui/main.zig");
const ManifestApp = @import("../build/Manifest.zig").App;
const cli_args = @import("root.zig");

const CommandContext = context.CommandContext;
const log = std.log.scoped(.cli);
pub const command = cli_args.@"export";

pub fn run(ctx: CommandContext, args: anytype) !void {
    const app = ctx.app;
    const io = app.io;
    const outdir = args.outdir;

    var temp_dir = try util.TempDir.init(io, ctx.allocator);
    defer temp_dir.deinit(io, ctx.allocator);
    const install_prefix = temp_dir.path;

    var build_argv = std.ArrayList([]const u8).empty;
    defer build_argv.deinit(ctx.allocator);
    try build_argv.appendSlice(ctx.allocator, &.{ args.@"zig-path", "build", "-Dcli-command=export" });

    var i_build_args = std.mem.splitSequence(u8, args.@"build-args", " ");
    while (i_build_args.next()) |arg| {
        const trimmed_arg = std.mem.trim(u8, arg, " ");
        if (std.mem.eql(u8, trimmed_arg, "")) continue;
        try build_argv.append(ctx.allocator, trimmed_arg);
    }
    try build_argv.appendSlice(ctx.allocator, &.{ "-p", install_prefix });

    var build_proc = try util.spawnZig(io, .{
        .argv = build_argv.items,
        .environ_map = app.environ_map,
    });
    switch (try build_proc.wait(io)) {
        .exited => |code| if (code != 0) {
            try ctx.writer.print("Failed to build the ZX executable for export (exit {d})!\n", .{code});
            return;
        },
        else => {
            try ctx.writer.print("Failed to build the ZX executable for export!\n", .{});
            return;
        },
    }

    // Read install manifest for executable path and page routes.
    const manifest_path = try std.fs.path.join(ctx.allocator, &.{ install_prefix, "manifest", "app.zon" });
    defer ctx.allocator.free(manifest_path);

    const manifest_source = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, ctx.allocator, .unlimited) catch |err| {
        std.log.err("Failed to read manifest at {s}: {}\n", .{ manifest_path, err });
        return;
    };
    defer ctx.allocator.free(manifest_source);

    const manifest_source_z = try ctx.allocator.dupeSentinel(u8, manifest_source, 0);
    defer ctx.allocator.free(manifest_source_z);

    var manifest_arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer manifest_arena.deinit();
    var manifest_diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(ManifestApp, .{
        .gpa = ctx.allocator,
        .arena = manifest_arena.allocator(),
        .source = manifest_source_z,
        .diagnostics = &manifest_diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("Failed to parse manifest at {s}: {}\n", .{ manifest_path, err });
        return;
    };

    const binpath_flag = args.binpath;
    const exe_path = util.resolveExePath(io, ctx.allocator, install_prefix, binpath_flag) catch {
        std.log.err("Run \x1b[34mzig build\x1b[0m to build the app first!\n", .{});
        return;
    };
    defer ctx.allocator.free(exe_path);

    const port = DevServer.findFreePort(io) catch 3000;
    const port_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{port});
    defer ctx.allocator.free(port_str);
    const host = "0.0.0.0";

    const environ_map = app.environ_map;
    try environ_map.put("ZIEX_INNER_PORT", port_str);

    try environ_map.put("ZIEX_ROOT_DIR", install_prefix);

    log.debug("Spawning export server exe={s} port={d} rootdir={s}", .{ exe_path, port, install_prefix });

    var app_child = try std.process.spawn(io, .{
        .argv = &.{exe_path},
        .environ_map = environ_map,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    defer killExportApp(&app_child, io);

    var printer = tui.Printer.init(ctx.allocator, .{ .file_path_mode = .flat, .file_tree_max_depth = 1 });
    defer printer.deinit();

    printer.header("{s} Exporting static site!", .{tui.Printer.emoji("○")});
    printer.info("{s}", .{outdir});
    // delete the outdir if it exists
    // std.Io.Dir.cwd().deleteTree(outdir) catch |err| switch (err) {
    //     else => {},
    // };

    const staticdir = try std.fs.path.join(ctx.allocator, &.{ install_prefix, "static" });
    defer ctx.allocator.free(staticdir);

    log.debug("Exporting app! binpath={s} rootdir={s}", .{ exe_path, install_prefix });
    log.debug("Port: {d}, Outdir: {s}, Staticdir: {s}", .{ port, outdir, staticdir });

    log.debug("Processing routes! {d}", .{manifest.routes.len});

    var connection_retries: u32 = 0;

    process_block: while (true) {
        for (manifest.routes) |entry| {
            const route = Server.SerilizableAppMeta.Route{
                .path = entry.path,
                .has_notfound = entry.notfound_import != null,
                .is_dynamic = std.mem.indexOf(u8, entry.path, ":") != null or std.mem.indexOf(u8, entry.path, "*") != null,
            };

            log.debug("Export route {s} dynamic={} notfound={}", .{ route.path, route.is_dynamic, route.has_notfound });

            if (route.is_dynamic) {
                log.debug("Fetching static params for {s}", .{route.path});
                const static_params = fetchStaticParams(io, ctx.allocator, host, port, route.path) catch |err| {
                    if (err == error.ConnectionRefused) {
                        try waitForServerRetry(io, &connection_retries, route.path, "static-params", &app_child);
                        continue :process_block;
                    }
                    log.warn("Failed to fetch static params for {s}: {any}", .{ route.path, err });
                    continue;
                };
                defer static_params.deinit();
                connection_retries = 0;

                log.debug("Static params for {s}: {d} paths", .{ route.path, static_params.items.len });

                const route_display = try formatRouteDisplayPath(ctx.allocator, route.path);
                defer ctx.allocator.free(route_display);
                if (static_params.items.len > 0) {
                    printer.filepathKind(route_display, .param_route);
                    for (static_params.items) |expanded_path| {
                        const expanded_route = Server.SerilizableAppMeta.Route{
                            .path = expanded_path,
                            .has_notfound = route.has_notfound,
                            .is_dynamic = false,
                        };
                        processRoute(io, ctx.allocator, host, port, expanded_route, outdir, &printer, .page, .param_child) catch |err| {
                            if (err == error.ConnectionRefused) {
                                try waitForServerRetry(io, &connection_retries, expanded_route.path, "page", &app_child);
                                continue :process_block;
                            }
                            return err;
                        };
                    }
                } else {
                    log.debug("No static params for dynamic route: {s}", .{route.path});
                    printer.filepathKind(route_display, .dynamic);
                }
            } else {
                processRoute(io, ctx.allocator, host, port, route, outdir, &printer, .page, .static) catch |err| {
                    if (err == error.ConnectionRefused) {
                        try waitForServerRetry(io, &connection_retries, route.path, "page", &app_child);
                        continue :process_block;
                    }
                    return err;
                };
            }
            connection_retries = 0;

            // Also export 404.html for routes that have notfound handler
            if (route.has_notfound) {
                processRoute(io, ctx.allocator, host, port, route, outdir, &printer, .notfound, .static) catch |err| {
                    if (err == error.ConnectionRefused) {
                        try waitForServerRetry(io, &connection_retries, route.path, "notfound", &app_child);
                        continue :process_block;
                    }
                    return err;
                };
            }
        }
        break;
    }

    log.debug("Copying public directory! {s}", .{outdir});

    util.copydirs(io, ctx.allocator, staticdir, &.{"."}, outdir, false, &printer) catch |err| {
        std.log.err("Failed to copy public directory: {any}", .{err});
        return err;
    };
}

const MAX_CONNECTION_RETRIES: u32 = 3_000;

fn waitForServerRetry(
    io: std.Io,
    retries: *u32,
    route_path: []const u8,
    kind: []const u8,
    app_child: *std.process.Child,
) !void {
    if (tryReapChild(app_child)) |term| {
        logChildTermination(term);
        return error.ExportServerExited;
    }

    retries.* += 1;
    const n = retries.*;
    if (n <= 5 or n % 100 == 0) {
        log.debug("Connection refused for {s} ({s}), retry {d}", .{ route_path, kind, n });
    }

    if (n >= MAX_CONNECTION_RETRIES) {
        log.err(
            "Export server never became reachable for {s} ({s}) after {d} retries",
            .{ route_path, kind, n },
        );
        return error.ExportServerUnavailable;
    }
    std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
}

fn tryReapChild(child: *std.process.Child) ?std.process.Child.Term {
    const id = child.id orelse return null;

    if (comptime builtin.os.tag == .windows) {
        var exit_code: std.os.windows.DWORD = undefined;
        if (win32.GetExitCodeProcess(id, &exit_code) == .FALSE) return null;
        if (exit_code == win32.STILL_ACTIVE) return null;
        return .{ .exited = @truncate(exit_code) };
    }

    var status: if (builtin.link_libc) c_int else i32 = undefined;
    while (true) {
        const rc = std.posix.system.waitpid(id, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null; // still running
                child.id = null;
                return termFromWaitStatus(@bitCast(status));
            },
            .INTR => continue,
            .CHILD => {
                child.id = null;
                return .{ .unknown = 0 };
            },
            else => return null,
        }
    }
}

const win32 = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn GetExitCodeProcess(
        hProcess: std.os.windows.HANDLE,
        lpExitCode: *std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;
    pub const STILL_ACTIVE: std.os.windows.DWORD = 259;
} else struct {};

fn termFromWaitStatus(status: u32) std.process.Child.Term {
    if (std.posix.W.IFEXITED(status)) return .{ .exited = std.posix.W.EXITSTATUS(status) };
    if (std.posix.W.IFSIGNALED(status)) return .{ .signal = std.posix.W.TERMSIG(status) };
    if (std.posix.W.IFSTOPPED(status)) return .{ .stopped = std.posix.W.STOPSIG(status) };
    return .{ .unknown = status };
}

fn logChildTermination(term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| log.err("Export server exited unexpectedly (exit {d})", .{code}),
        .signal => |sig| log.err("Export server terminated by signal {d} (likely panic/abort)", .{@backingInt(sig)}),
        else => |v| log.err("Export server terminated unexpectedly: {any}", .{v}),
    }
}

const ExportType = enum { page, notfound };

const StaticParamsResult = struct {
    items: []const []const u8,
    allocator: ?std.mem.Allocator = null,

    fn deinit(self: StaticParamsResult) void {
        if (self.allocator) |alloc| {
            for (self.items) |path| {
                alloc.free(path);
            }
            alloc.free(self.items);
        }
    }
};

fn processRoute(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    route: Server.SerilizableAppMeta.Route,
    outdir: []const u8,
    printer: *tui.Printer,
    export_type: ExportType,
    print_as: tui.Printer.FilePathKind,
) !void {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    const effective_host = if (std.mem.eql(u8, host, "0.0.0.0")) "127.0.0.1" else host;
    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{ effective_host, port, route.path });
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);
    var extra_headers: [1]std.http.Header = .{.{ .name = "x-zx-export-notfound", .value = "true" }};

    log.debug("Fetching {s} kind={s} url={s}", .{ route.path, @tagName(export_type), url });

    var req = try client.request(.GET, uri, .{
        .keep_alive = false,
        .extra_headers = if (export_type == .notfound) &extra_headers else &.{},
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    const is_dynamic = responseHeaderEquals(response.head, "x-zx-dynamic", "true");

    const export_path = try resolveExportFilePath(allocator, route.path, export_type);
    defer export_path.deinit(allocator);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);

    const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    if (is_dynamic) {
        log.debug("Skipping dynamic route: {s}", .{route.path});
        _ = body_reader.discardRemaining() catch {};
        printer.filepathKind(export_path.path, .dynamic);
        return;
    }

    _ = body_reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    const response_text = aw.written();
    log.debug("Fetched {s} kind={s} status={} body_len={d}", .{ route.path, @tagName(export_type), response.head.status, response_text.len });

    const output_path = try std.fs.path.join(allocator, &.{ outdir, export_path.path });
    defer allocator.free(output_path);

    const output_dir = std.fs.path.dirname(output_path);
    if (output_dir) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = response_text,
    });

    printer.filepathKind(export_path.path, print_as);
}

/// Format a route pattern for display: strip leading `/`, `:param` -> `[param]`, `*` -> `[..]`.
fn formatRouteDisplayPath(allocator: std.mem.Allocator, route_path: []const u8) ![]const u8 {
    const stripped = if (route_path.len > 0 and route_path[0] == '/') route_path[1..] else route_path;

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var first = true;
    var i: usize = 0;
    while (i <= stripped.len) {
        const end = if (i < stripped.len)
            std.mem.indexOfScalarPos(u8, stripped, i, '/') orelse stripped.len
        else
            stripped.len;
        const seg = stripped[i..end];

        if (!first) try out.append('/');
        first = false;

        if (seg.len > 0 and seg[0] == ':') {
            try out.append('[');
            try out.appendSlice(seg[1..]);
            try out.append(']');
        } else if (seg.len == 1 and seg[0] == '*') {
            try out.appendSlice("[..]");
        } else {
            try out.appendSlice(seg);
        }

        if (end == stripped.len) break;
        i = end + 1;
    }

    return out.toOwnedSlice();
}

fn responseHeaderEquals(head: std.http.Client.Response.Head, name: []const u8, value: []const u8) bool {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name) and std.mem.eql(u8, header.value, value)) {
            return true;
        }
    }
    return false;
}

const ExportFilePath = struct {
    path: []const u8,
    owned: bool,

    fn deinit(self: ExportFilePath, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.path);
    }
};

fn resolveExportFilePath(allocator: std.mem.Allocator, route_path: []const u8, export_type: ExportType) !ExportFilePath {
    if (export_type == .notfound) {
        // For 404 pages, output as 404.html in the route's directory
        if (std.mem.eql(u8, route_path, "/")) {
            return .{ .path = "404.html", .owned = false };
        }
        // For non-root paths like /docs, output as docs/404.html
        var path_components = std.ArrayList([]const u8).empty;
        defer path_components.deinit(allocator);

        var path_iter = std.mem.splitScalar(u8, route_path, '/');
        while (path_iter.next()) |component| {
            if (component.len > 0) {
                try path_components.append(allocator, component);
            }
        }
        try path_components.append(allocator, "404.html");
        return .{ .path = try std.fs.path.join(allocator, path_components.items), .owned = true };
    }

    if (std.mem.eql(u8, route_path, "/")) {
        // For root path "/", use "index.html"
        return .{ .path = "index.html", .owned = false };
    }

    // Split the URL path by "/" to get path components
    // Skip the first empty component (from leading "/")
    var path_components = std.ArrayList([]const u8).empty;
    defer path_components.deinit(allocator);

    var path_iter = std.mem.splitScalar(u8, route_path, '/');
    while (path_iter.next()) |component| {
        if (component.len > 0) {
            try path_components.append(allocator, component);
        }
    }

    if (route_path[route_path.len - 1] == '/') {
        // For paths ending in "/", create directory/index.html structure
        try path_components.append(allocator, "index.html");
        return .{ .path = try std.fs.path.join(allocator, path_components.items), .owned = true };
    }

    // Get the last component (filename)
    const last_component = path_components.items[path_components.items.len - 1];
    // Add .html extension if it doesn't have one
    if (std.fs.path.extension(last_component).len == 0) {
        const last_with_ext = try std.fmt.allocPrint(allocator, "{s}.html", .{last_component});
        defer allocator.free(last_with_ext);

        // Replace the last component with the one that has .html extension
        _ = path_components.pop();
        try path_components.append(allocator, last_with_ext);
        return .{ .path = try std.fs.path.join(allocator, path_components.items), .owned = true };
    }

    // Path already has an extension, join all components
    return .{ .path = try std.fs.path.join(allocator, path_components.items), .owned = true };
}

/// Fetch static params from server via x-zx-static-data header
/// Returns expanded paths (e.g., "/blog/hello", "/blog/world")
fn fetchStaticParams(io: std.Io, allocator: std.mem.Allocator, host: []const u8, port: u16, route_path: []const u8) !StaticParamsResult {
    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    const effective_host = if (std.mem.eql(u8, host, "0.0.0.0")) "127.0.0.1" else host;
    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{ effective_host, port, route_path });
    defer allocator.free(url);

    var extra_headers: [1]std.http.Header = .{.{ .name = "x-zx-static-data", .value = "true" }};

    log.debug("Fetching static params url={s}", .{url});

    const result = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .keep_alive = false,
        .extra_headers = &extra_headers,
        .response_writer = &aw.writer,
    });

    const response = aw.written();
    log.debug("Static params response for {s}: status={} body_len={d}", .{ route_path, result.status, response.len });

    if (result.status != .ok) return .{ .items = &.{}, .allocator = null };

    if (response.len == 0 or std.mem.eql(u8, response, ".{}")) return .{ .items = &.{}, .allocator = null };

    const response_z = try allocator.dupeSentinel(u8, response, 0);
    defer allocator.free(response_z);

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    var parse_diagnostics: std.zon.parse.Diagnostics = undefined;
    const parsed = std.zon.parse.fromSlice([]const []const options_mod.StaticParam, .{
        .gpa = allocator,
        .arena = parse_arena.allocator(),
        .source = response_z,
        .diagnostics = &parse_diagnostics,
    }) catch |err| {
        log.warn("Failed to parse static params ZON: {any}", .{err});
        return .{ .items = &.{}, .allocator = null };
    };

    // Expand dynamic paths
    var expanded = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (expanded.items) |path| allocator.free(path);
        expanded.deinit();
    }

    for (parsed) |param_set| {
        const expanded_path = expandDynamicPath(allocator, route_path, param_set) catch continue;
        expanded.append(expanded_path) catch {
            allocator.free(expanded_path);
            continue;
        };
    }

    if (expanded.items.len == 0) {
        expanded.deinit();
        return .{ .items = &.{}, .allocator = null };
    }

    const items = try expanded.toOwnedSlice();
    return .{ .items = items, .allocator = allocator };
}

/// Replace `:param` and `*` dynamic segments in a route path with actual values.
fn expandDynamicPath(allocator: std.mem.Allocator, route_path: []const u8, params: []const options_mod.StaticParam) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    var first = true;
    while (i <= route_path.len) {
        const end = if (i < route_path.len)
            std.mem.indexOfScalarPos(u8, route_path, i, '/') orelse route_path.len
        else
            route_path.len;
        const seg = route_path[i..end];

        if (!first) try out.append('/');
        first = false;

        const replacement: ?[]const u8 = if (seg.len > 0 and seg[0] == ':')
            findStaticParamValue(params, seg[1..])
        else if (seg.len == 1 and seg[0] == '*')
            findStaticParamValue(params, "*")
        else
            null;

        if (replacement) |value| {
            try out.appendSlice(value);
        } else {
            try out.appendSlice(seg);
        }

        if (end == route_path.len) break;
        i = end + 1;
    }

    return out.toOwnedSlice();
}

fn killExportApp(child: *std.process.Child, io: std.Io) void {
    const id = child.id orelse return;

    if (comptime builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(1));

        const timeout: std.os.windows.LARGE_INTEGER = -2 * std.time.ns_per_s / 100;
        _ = std.os.windows.ntdll.NtWaitForSingleObject(id, .FALSE, &timeout);

        std.os.windows.CloseHandle(id);
        child.id = null;
        std.os.windows.CloseHandle(child.thread_handle);
        child.thread_handle = undefined;
        return;
    }

    child.kill(io);
}

fn findStaticParamValue(params: []const options_mod.StaticParam, key: []const u8) ?[]const u8 {
    for (params) |param| {
        if (std.mem.eql(u8, param.key, key)) return param.value;
    }
    return null;
}
