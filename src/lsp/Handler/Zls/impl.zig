const std = @import("std");
const builtin = @import("builtin");
const zls = @import("zls");
const lsp = @import("lsp");
const Handler = @import("../../Handler.zig");
const Zls = @import("../Zls.zig");
const zx_module = @import("../../../cli/shared/zx_module.zig");

const request_methods = [_][]const u8{
    "initialize",
    "shutdown",
    "textDocument/willSaveWaitUntil",
    "textDocument/semanticTokens/full",
    "textDocument/semanticTokens/range",
    "textDocument/inlayHint",
    "textDocument/completion",
    "textDocument/signatureHelp",
    "textDocument/definition",
    "textDocument/typeDefinition",
    "textDocument/implementation",
    "textDocument/declaration",
    "textDocument/hover",
    "textDocument/documentSymbol",
    "textDocument/formatting",
    "textDocument/rename",
    "textDocument/prepareRename",
    "textDocument/references",
    "textDocument/documentHighlight",
    "textDocument/codeAction",
    "textDocument/foldingRange",
    "textDocument/selectionRange",
};

const notification_methods = [_][]const u8{
    "initialized",
    "exit",
    "textDocument/didOpen",
    "textDocument/didChange",
    "textDocument/didSave",
    "textDocument/didClose",
    "workspace/didChangeWatchedFiles",
    "workspace/didChangeWorkspaceFolders",
    "workspace/didChangeConfiguration",
};

const Impl = struct {
    allocator: std.mem.Allocator,
    server: *zls.Server,
    config_manager: *zls.configuration.Manager,
    environ_map: *const std.process.Environ.Map,
    global_cache_path: ?[]const u8,
    zx_module_path: ?[]const u8,
    active_build_file: ?[]const u8 = null,
};

const vtable: Handler.VTable = .{
    .destroy = destroy,
    .request = request,
    .notification = notification,
    .onResponse = onResponse,
};

pub fn create(options: Zls.CreateOptions) Zls.CreateError!Zls.Backing {
    const allocator = options.allocator;

    const global_cache_path: ?[]const u8 = blk: {
        const home = options.environ_map.get("HOME") orelse break :blk null;
        const cache_suffix = if (builtin.os.tag == .macos) "Library/Caches/zls" else ".cache/zls";
        break :blk std.fs.path.join(allocator, &.{ home, cache_suffix }) catch null;
    };
    errdefer if (global_cache_path) |p| allocator.free(p);

    const config_manager = try allocator.create(zls.configuration.Manager);
    errdefer allocator.destroy(config_manager);

    config_manager.* = zls.configuration.Manager.init(options.io, allocator, options.environ_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unexpected => return error.Unexpected,
    };
    errdefer config_manager.deinit();

    const zx_module_path: ?[]const u8 = blk: {
        if (options.zx_module) |p| if (p.len > 0) break :blk p;
        if (options.environ_map.get("ZIEX_MODULE_PATH")) |p| if (p.len > 0) break :blk p;
        break :blk null;
    };
    try setFrontendConfig(config_manager, global_cache_path, if (zx_module_path) |path| &.{
        .{ .name = "zx", .path = path },
    } else &.{});

    const server = try zls.Server.create(.{
        .io = options.io,
        .allocator = allocator,
        .transport = @ptrCast(options.transport),
        .config_manager = config_manager,
    });
    errdefer zls.Server.destroy(server);

    const owned_zx_module_path: ?[]const u8 = if (zx_module_path) |p| try allocator.dupe(u8, p) else null;
    errdefer if (owned_zx_module_path) |p| allocator.free(p);

    const impl = try allocator.create(Impl);
    errdefer allocator.destroy(impl);
    impl.* = .{
        .allocator = allocator,
        .server = server,
        .config_manager = config_manager,
        .environ_map = options.environ_map,
        .global_cache_path = global_cache_path,
        .zx_module_path = owned_zx_module_path,
    };

    return .{
        .ptr = impl,
        .vtable = &vtable,
    };
}

fn destroy(ptr: *anyopaque) void {
    const impl: *Impl = @ptrCast(@alignCast(ptr));
    const allocator = impl.allocator;
    zls.Server.destroy(impl.server);
    impl.config_manager.deinit();
    allocator.destroy(impl.config_manager);
    if (impl.global_cache_path) |p| allocator.free(p);
    if (impl.zx_module_path) |p| allocator.free(p);
    if (impl.active_build_file) |p| allocator.free(p);
    allocator.destroy(impl);
}

fn isZxDocument(uri: []const u8) bool {
    return std.mem.endsWith(u8, uri, ".zx") or std.mem.endsWith(u8, uri, ".mdzx");
}

fn syncModulesForParams(impl: *Impl, arena: std.mem.Allocator, comptime P: type, p: *const P) void {
    if (comptime @typeInfo(P) != .@"struct" or !@hasField(P, "textDocument")) return;
    const uri: []const u8 = p.textDocument.uri;
    if (!isZxDocument(uri)) return;
    syncModulesFor(impl, arena, uri) catch |err| {
        std.log.err("zls module sync for {s} failed: {}", .{ uri, err });
    };
}

fn syncModulesFor(impl: *Impl, arena: std.mem.Allocator, document_uri: []const u8) !void {
    if (comptime !zls.DocumentStore.supports_build_system) return;

    const server = impl.server;
    const store = &server.document_store;
    const io = server.io;

    const uri = zls.Uri.parse(arena, document_uri) catch return;
    const doc_path = uri.toFsPath(arena) catch return;

    // Resolve `zx` from build.zig.zon so it works before (or without) the build runner.
    if (impl.zx_module_path == null) {
        if (std.fs.path.dirname(doc_path)) |doc_dir| {
            if (zx_module.resolve(io, impl.allocator, impl.environ_map, doc_dir)) |path| {
                impl.zx_module_path = path;
                try applyModules(impl, &.{.{ .name = "zx", .path = path }});
            }
        }
    }

    // Makes ZLS load every ancestor `build.zig` and start their build runners.
    if (store.getHandle(uri)) |handle| {
        _ = try handle.getAssociatedBuildFile(store);
    }

    var dir: ?[]const u8 = std.fs.path.dirname(doc_path);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const build_path = try std.fs.path.join(arena, &.{ d, "build.zig" });
        const build_uri = try zls.Uri.fromPath(arena, build_path);
        const build_file = store.getBuildFile(build_uri) orelse continue;

        if (impl.active_build_file) |active| {
            if (std.mem.eql(u8, active, build_path)) return;
        }

        // Build runner still in progress; retry on the next request.
        const build_config = build_file.tryLockConfig(io) orelse return;
        const modules = blk: {
            defer build_file.unlockConfig(io);
            break :blk try collectModules(arena, build_config, impl.zx_module_path);
        };

        try applyModules(impl, modules);
        if (impl.active_build_file) |old| impl.allocator.free(old);
        impl.active_build_file = try impl.allocator.dupe(u8, build_path);
        return;
    }
}

/// Merge the named imports of every module in `build_config`. Modules that
/// import `zx` (app pages and components) take precedence on name clashes.
fn collectModules(
    arena: std.mem.Allocator,
    build_config: anytype,
    zx_module_path: ?[]const u8,
) ![]const zls.Config.Module {
    var merged: std.array_hash_map.String([]const u8) = .empty;

    if (zx_module_path) |path| try merged.put(arena, "zx", path);

    const module_values = build_config.modules.map.values();
    for ([_]bool{ true, false }) |zx_importers| {
        for (module_values) |module| {
            const imports = &module.import_table.map;
            if ((imports.get("zx") != null) != zx_importers) continue;
            for (imports.keys(), imports.values()) |name, path| {
                if (std.mem.eql(u8, name, "std") or
                    std.mem.eql(u8, name, "builtin") or
                    std.mem.eql(u8, name, "root")) continue;
                const gop = try merged.getOrPut(arena, name);
                if (!gop.found_existing) gop.value_ptr.* = path;
            }
        }
    }

    const result = try arena.alloc(zls.Config.Module, merged.count());
    for (merged.keys(), merged.values(), result) |name, path, *out| {
        out.* = .{ .name = name, .path = path };
    }
    return result;
}

fn applyModules(impl: *Impl, modules: []const zls.Config.Module) !void {
    try setFrontendConfig(impl.config_manager, impl.global_cache_path, modules);
    try impl.server.resolveConfiguration();
}

fn setFrontendConfig(
    config_manager: *zls.configuration.Manager,
    global_cache_path: ?[]const u8,
    modules: []const zls.Config.Module,
) error{OutOfMemory}!void {
    // `.frontend` has the lowest priority: editor settings (`initializationOptions`
    // or the `zls` section of `workspace/configuration`) override these defaults.
    try config_manager.setConfiguration(.frontend, &.{
        .import_extensions = &.{"zx"},
        .modules = modules,
        .global_cache_path = global_cache_path,
        // Inlay defaults tuned for zx: hints inside markup are filtered out by the
        // handler, and the remaining Zig is mostly page/handler glue where
        // builtin (`@import`, `@errorName`) and `.{ .field = ... }` hints are noise.
        .inlay_hints_show_builtin = false,
        .inlay_hints_show_struct_literal_field_type = false,
        .inlay_hints_hide_redundant_param_names = true,
        .inlay_hints_hide_redundant_param_names_last_token = true,
    });
}

fn request(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    method: []const u8,
    params: *const anyopaque,
    result: *anyopaque,
) anyerror!void {
    const impl: *Impl = @ptrCast(@alignCast(ptr));
    inline for (request_methods) |m| {
        if (std.mem.eql(u8, method, m)) {
            const P = zls.lsp.ParamsType(m);
            const R = zls.lsp.ResultType(m);
            const p: *const P = @ptrCast(@alignCast(params));
            const r: *R = @ptrCast(@alignCast(result));
            syncModulesForParams(impl, arena, P, p);
            r.* = impl.server.sendRequestSync(arena, m, p.*) catch |err| {
                std.log.err("zls {s} failed: {}", .{ m, err });
                return;
            };
            return;
        }
    }
}

fn notification(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    method: []const u8,
    params: *const anyopaque,
) anyerror!void {
    const impl: *Impl = @ptrCast(@alignCast(ptr));
    inline for (notification_methods) |m| {
        if (std.mem.eql(u8, method, m)) {
            const P = zls.lsp.ParamsType(m);
            const p: *const P = @ptrCast(@alignCast(params));
            impl.server.sendNotificationSync(arena, m, p.*) catch |err| {
                std.log.err("zls {s} failed: {}", .{ m, err });
            };
            syncModulesForParams(impl, arena, P, p);
            return;
        }
    }
}

fn onResponse(
    ptr: *anyopaque,
    arena: std.mem.Allocator,
    response: lsp.JsonRPCMessage.Response,
) void {
    const impl: *Impl = @ptrCast(@alignCast(ptr));
    const json_message = std.json.Stringify.valueAlloc(
        arena,
        lsp.JsonRPCMessage{ .response = response },
        .{ .emit_null_optional_fields = false },
    ) catch |err| {
        std.log.err("zls onResponse stringify failed: {}", .{err});
        return;
    };
    const reply = impl.server.sendJsonMessageSync(json_message) catch |err| {
        std.log.err("zls sendJsonMessageSync failed: {}", .{err});
        return;
    };
    if (reply) |r| impl.server.allocator.free(r);
}
