const Manifest = @This();

const std = @import("std");
const Build = @import("../Build.zig");

const Allocator = std.mem.Allocator;

pub const AddElementOptions = Build.AddElementOptions;
pub const RouteEntry = struct {
    path: []const u8,
    page_import: ?[]const u8 = null,
    layout_import: ?[]const u8 = null,
    notfound_import: ?[]const u8 = null,
    error_import: ?[]const u8 = null,
    route_import: ?[]const u8 = null,
    proxy_import: ?[]const u8 = null,
};
pub const App = struct {
    exe_path: ?[]const u8 = null,
    transpile_dir: ?[]const u8 = null,
    injections: []const AddElementOptions = &.{},
    routes: []const RouteEntry = &.{},
};

path: []const u8,
allocator: std.mem.Allocator,
exe_path: ?[]const u8 = null,
transpile_dir: ?[]const u8 = null,
injections: []const AddElementOptions = &.{},
routes: []const RouteEntry = &.{},

pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Manifest {
    const owned_path = try allocator.dupe(u8, path);

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{ .path = owned_path, .allocator = allocator },
        else => return err,
    };
    defer allocator.free(source);

    if (source.len == 0) return .{ .path = owned_path, .allocator = allocator };

    const source_z = try std.mem.concatWithSentinel(allocator, u8, &.{source}, 0);
    defer allocator.free(source_z);

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const parsed = try std.zon.parse.fromSlice(App, .{
        .gpa = scratch.allocator(),
        .arena = allocator,
        .source = source_z,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });

    return .{
        .path = owned_path,
        .allocator = allocator,
        .exe_path = parsed.exe_path,
        .transpile_dir = parsed.transpile_dir,
        .injections = parsed.injections,
        .routes = parsed.routes,
    };
}

pub fn deinit(self: *Manifest) void {
    self.allocator.free(self.path);
}

pub fn commit(self: *const Manifest, io: std.Io) !void {
    try self.commitTo(io, self.path);
}

pub fn commitTo(self: *const Manifest, io: std.Io, path: []const u8) !void {
    var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer aw.deinit();
    try std.zon.stringify.serializeArbitraryDepth(self.app(), .{ .whitespace = true }, &aw.writer);
    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

pub fn mergeBuildInjections(self: *Manifest, build_injections: []const AddElementOptions) !void {
    var injections = std.array_list.Managed(AddElementOptions).init(self.allocator);
    errdefer injections.deinit();

    for (self.injections) |injection| {
        if (!isManagedBuildInjection(injection)) try injections.append(injection);
    }
    for (build_injections) |injection| {
        try injections.append(try dupeInjection(self.allocator, injection));
    }

    self.injections = try injections.toOwnedSlice();
}

pub fn upsertWasmlinkInjection(self: *Manifest, injection: AddElementOptions) !void {
    var injections = std.array_list.Managed(AddElementOptions).init(self.allocator);
    errdefer injections.deinit();

    for (self.injections) |existing| {
        if (!isWasmlinkInjection(existing)) try injections.append(existing);
    }
    try injections.append(try dupeInjection(self.allocator, injection));

    self.injections = try injections.toOwnedSlice();
}

pub fn upsertJsglueInjection(self: *Manifest, injection: AddElementOptions) !void {
    var injections = std.array_list.Managed(AddElementOptions).init(self.allocator);
    errdefer injections.deinit();

    for (self.injections) |existing| {
        if (!isJsglueInjection(existing)) try injections.append(existing);
    }
    try injections.append(try dupeInjection(self.allocator, injection));

    self.injections = try injections.toOwnedSlice();
}

pub fn setRoutes(self: *Manifest, routes: []const RouteEntry) !void {
    const owned = try self.allocator.alloc(RouteEntry, routes.len);
    errdefer self.allocator.free(owned);

    for (routes, owned) |route, *out| {
        out.* = try dupeRoute(self.allocator, route);
    }

    self.routes = owned;
}

fn app(self: *const Manifest) App {
    return .{
        .exe_path = self.exe_path,
        .transpile_dir = self.transpile_dir,
        .injections = self.injections,
        .routes = self.routes,
    };
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}

fn dupeRoute(allocator: std.mem.Allocator, route: RouteEntry) !RouteEntry {
    return .{
        .path = try allocator.dupe(u8, route.path),
        .page_import = try dupeOptional(allocator, route.page_import),
        .layout_import = try dupeOptional(allocator, route.layout_import),
        .notfound_import = try dupeOptional(allocator, route.notfound_import),
        .error_import = try dupeOptional(allocator, route.error_import),
        .route_import = try dupeOptional(allocator, route.route_import),
        .proxy_import = try dupeOptional(allocator, route.proxy_import),
    };
}

fn dupeInjection(allocator: std.mem.Allocator, injection: AddElementOptions) !AddElementOptions {
    return .{
        .parent = injection.parent,
        .position = injection.position,
        .priority = injection.priority,
        .id = try dupeOptional(allocator, injection.id),
        .pathname = try dupePathname(allocator, injection.pathname),
        .element = try dupeElementDef(allocator, injection.element),
    };
}

fn dupePathname(allocator: std.mem.Allocator, pathname: AddElementOptions.Pathname) !AddElementOptions.Pathname {
    const includes = try allocator.alloc([]const u8, pathname.includes.len);
    errdefer allocator.free(includes);
    for (pathname.includes, includes) |s, *out| {
        out.* = try allocator.dupe(u8, s);
    }

    const excludes = try allocator.alloc([]const u8, pathname.excludes.len);
    errdefer {
        for (includes) |s| allocator.free(s);
        allocator.free(includes);
        allocator.free(excludes);
    }
    for (pathname.excludes, excludes) |s, *out| {
        out.* = try allocator.dupe(u8, s);
    }

    return .{ .includes = includes, .excludes = excludes };
}

fn dupeElementDef(allocator: std.mem.Allocator, element_def: AddElementOptions.ElementDef) Allocator.Error!AddElementOptions.ElementDef {
    const children = if (element_def.children) |kids| blk: {
        const owned = try allocator.alloc(AddElementOptions.ElementDef.Child, kids.len);
        for (kids, owned) |child, *out| {
            out.* = try dupeChild(allocator, child);
        }
        break :blk owned;
    } else null;

    const attributes = try allocator.alloc(AddElementOptions.ElementDef.Attribute, element_def.attributes.len);
    for (element_def.attributes, attributes) |attr, *out| {
        out.* = .{
            .name = try allocator.dupe(u8, attr.name),
            .value = try dupeOptional(allocator, attr.value),
        };
    }

    return .{
        .tag = element_def.tag,
        .children = children,
        .attributes = attributes,
    };
}

fn dupeChild(allocator: std.mem.Allocator, child: AddElementOptions.ElementDef.Child) Allocator.Error!AddElementOptions.ElementDef.Child {
    return switch (child) {
        .text => |t| .{ .text = try allocator.dupe(u8, t) },
        .element => |e| .{ .element = try dupeElementDef(allocator, e) },
    };
}

fn isWasmlinkInjection(injection: AddElementOptions) bool {
    return std.mem.eql(u8, injection.id orelse "", AddElementOptions.Id.wasmlink);
}

fn isJsglueInjection(injection: AddElementOptions) bool {
    return std.mem.eql(u8, injection.id orelse "", AddElementOptions.Id.jsglue);
}

fn isManagedBuildInjection(injection: AddElementOptions) bool {
    return isWasmlinkInjection(injection) or isJsglueInjection(injection);
}
