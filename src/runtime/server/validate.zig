//! Comptime validation of route module exports: `page`, `layout`, `notfound`,
//! `error`, `route` and `proxy` files. Errors name the route, the module and the
//! declaration, and show the expected signature:
//!
//!   /about: `pages.about.page.Page` must take `zx.PageContext` first; expected `pub fn Page(ctx: zx.PageContext) zx.Component`
const std = @import("std");
const zx = @import("../../root.zig");

const Component = zx.Component;

pub fn page(comptime path: []const u8, comptime M: type) void {
    const sig = "pub fn Page(ctx: zx.PageContext) zx.Component";
    const f = required(path, M, "Page", sig);
    params(path, M, "Page", sig, f, 1, 3);
    first(path, M, "Page", sig, f, zx.PageContext, "zx.PageContext");
    returns(path, M, "Page", sig, f, .component_or_error);
}

pub fn layout(comptime path: []const u8, comptime M: type) void {
    const sig = "pub fn Layout(ctx: zx.LayoutContext, children: zx.Component) zx.Component";
    const f = required(path, M, "Layout", sig);
    params(path, M, "Layout", sig, f, 2, 4);
    first(path, M, "Layout", sig, f, zx.LayoutContext, "zx.LayoutContext");
    if (f.param_types[1] != Component) fail(path, M, "Layout", sig, "must take `zx.Component` children second");
    returns(path, M, "Layout", sig, f, .component);
}

pub fn notfound(comptime path: []const u8, comptime M: type) void {
    const sig = "pub fn NotFound(ctx: zx.NotFoundContext) zx.Component";
    const f = optional(path, M, "NotFound", sig) orelse return;
    params(path, M, "NotFound", sig, f, 1, 1);
    first(path, M, "NotFound", sig, f, zx.NotFoundContext, "zx.NotFoundContext");
    returns(path, M, "NotFound", sig, f, .component);
}

pub fn @"error"(comptime path: []const u8, comptime M: type) void {
    const sig = "pub fn Error(ctx: zx.ErrorContext) zx.Component";
    const f = optional(path, M, "Error", sig) orelse return;
    params(path, M, "Error", sig, f, 1, 1);
    first(path, M, "Error", sig, f, zx.ErrorContext, "zx.ErrorContext");
    returns(path, M, "Error", sig, f, .component);
}

pub fn route(comptime path: []const u8, comptime M: type) void {
    @setEvalBranchQuota(100_000);
    for (@typeInfo(M).@"struct".decl_names) |name| {
        // `Route` catch-all, the standard methods and custom ALL-CAPS methods.
        if (std.mem.eql(u8, name, "Route") or isAllUpper(name)) {
            const f = fnInfo(@TypeOf(@field(M, name))) orelse continue;
            const sig = "pub fn " ++ name ++ "(ctx: zx.RouteContext) !void";
            params(path, M, name, sig, f, 1, 3);
            first(path, M, name, sig, f, zx.RouteContext, "zx.RouteContext");
            returns(path, M, name, sig, f, .void_or_error);
        }
    }

    socket(path, M, "Socket", zx.SocketCtx, "zx.SocketContext", .void_or_error);
    socket(path, M, "SocketOpen", zx.SocketOpenCtx, "zx.SocketOpenContext", .void_or_error);
    socket(path, M, "SocketClose", zx.SocketCloseCtx, "zx.SocketCloseContext", .void);
}

pub fn proxy(comptime path: []const u8, comptime M: type) void {
    for ([_][]const u8{ "Proxy", "PageProxy", "RouteProxy" }) |name| {
        const sig = "pub fn " ++ name ++ "(ctx: *zx.ProxyContext) !void";
        const f = optional(path, M, name, sig) orelse continue;
        params(path, M, name, sig, f, 1, 1);
        first(path, M, name, sig, f, *zx.ProxyContext, "*zx.ProxyContext");
        returns(path, M, name, sig, f, .void_or_error);
    }
}

fn socket(
    comptime path: []const u8,
    comptime M: type,
    comptime name: []const u8,
    comptime Ctx: fn (type) type,
    comptime ctx_name: []const u8,
    comptime ret: Return,
) void {
    const sig = "pub fn " ++ name ++ "(ctx: " ++ ctx_name ++ ") " ++ (if (ret == .void) "void" else "!void");
    const f = optional(path, M, name, sig) orelse return;
    params(path, M, name, sig, f, 1, 1);
    const P = f.param_types[0] orelse fail(path, M, name, sig, "must not take a generic context");
    const ok = @typeInfo(P) == .@"struct" and @hasField(P, "data") and P == Ctx(@FieldType(P, "data"));
    if (!ok) fail(path, M, name, sig, "must take `" ++ ctx_name ++ "` (or `zx." ++ name ++ "Ctx(T)`) first, got `" ++ label(P) ++ "`");
    returns(path, M, name, sig, f, ret);
}

const Return = enum { component, component_or_error, void, void_or_error };

fn required(comptime path: []const u8, comptime M: type, comptime name: []const u8, comptime sig: []const u8) std.lang.Type.Fn {
    if (!@hasDecl(M, name)) {
        // `pub fn page(...)` instead of `Page` is almost always a casing slip.
        const lower: []const u8 = &([_]u8{std.ascii.toLower(name[0])} ++ name[1..].*);
        fail(path, M, name, sig, if (@hasDecl(M, lower)) "is missing (found `" ++ lower ++ "`; names are case-sensitive)" else "is missing or not `pub`");
    }
    return fnInfo(@TypeOf(@field(M, name))) orelse fail(path, M, name, sig, "must be a function");
}

fn optional(comptime path: []const u8, comptime M: type, comptime name: []const u8, comptime sig: []const u8) ?std.lang.Type.Fn {
    if (!@hasDecl(M, name)) return null;
    return fnInfo(@TypeOf(@field(M, name))) orelse fail(path, M, name, sig, "must be a function");
}

fn params(
    comptime path: []const u8,
    comptime M: type,
    comptime name: []const u8,
    comptime sig: []const u8,
    comptime f: std.lang.Type.Fn,
    comptime min: usize,
    comptime max: usize,
) void {
    const n = f.param_types.len;
    if (n >= min and n <= max) return;
    const range = if (min == max)
        std.fmt.comptimePrint("{d}", .{min})
    else
        std.fmt.comptimePrint("{d}-{d}", .{ min, max });
    const note = if (min == max) "" else " (app and state are optional)";
    fail(path, M, name, sig, std.fmt.comptimePrint("must take {s} parameters{s}, got {d}", .{ range, note, n }));
}

fn first(
    comptime path: []const u8,
    comptime M: type,
    comptime name: []const u8,
    comptime sig: []const u8,
    comptime f: std.lang.Type.Fn,
    comptime T: type,
    comptime t_name: []const u8,
) void {
    const P = f.param_types[0] orelse fail(path, M, name, sig, "must not take a generic context");
    if (P != T) fail(path, M, name, sig, "must take `" ++ t_name ++ "` first, got `" ++ label(P) ++ "`");
}

fn returns(
    comptime path: []const u8,
    comptime M: type,
    comptime name: []const u8,
    comptime sig: []const u8,
    comptime f: std.lang.Type.Fn,
    comptime ret: Return,
) void {
    const R = f.return_type orelse fail(path, M, name, sig, "must not have a generic return type");
    const payload = switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
    const ok = switch (ret) {
        .component => R == Component,
        .component_or_error => payload == Component,
        .void => R == void,
        .void_or_error => payload == void,
    };
    if (!ok) fail(path, M, name, sig, "must return `" ++ switch (ret) {
        .component => "zx.Component",
        .component_or_error => "zx.Component` or `!zx.Component",
        .void => "void",
        .void_or_error => "void` or `!void",
    } ++ "`, got `" ++ label(R) ++ "`");
}

// User-facing names for framework types; `!T` for inferred error sets.
fn label(comptime T: type) []const u8 {
    if (@typeInfo(T) == .error_union) return "!" ++ label(@typeInfo(T).error_union.payload);
    if (@typeInfo(T) == .pointer) return "*" ++ label(@typeInfo(T).pointer.child);
    const known = .{
        .{ zx.PageContext, "zx.PageContext" },
        .{ zx.ErrorContext, "zx.ErrorContext" },
        .{ zx.RouteContext, "zx.RouteContext" },
        .{ zx.ProxyContext, "zx.ProxyContext" },
        .{ zx.ComponentContext, "zx.ComponentContext" },
        .{ Component, "zx.Component" },
    };
    inline for (known) |k| if (T == k[0]) return k[1];
    return @typeName(T);
}

fn fnInfo(comptime T: type) ?std.lang.Type.Fn {
    return switch (@typeInfo(T)) {
        .@"fn" => |f| f,
        else => null,
    };
}

fn isAllUpper(comptime name: []const u8) bool {
    for (name) |c| if (!std.ascii.isUpper(c) and c != '_') return false;
    return name.len > 0;
}

fn fail(
    comptime path: []const u8,
    comptime M: type,
    comptime name: []const u8,
    comptime sig: []const u8,
    comptime problem: []const u8,
) noreturn {
    @compileError(path ++ ": `" ++ @typeName(M) ++ "." ++ name ++ "` " ++ problem ++ "; expected `" ++ sig ++ "`");
}
