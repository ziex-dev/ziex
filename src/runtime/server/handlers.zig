//! Static registry of server actions and events, built at comptime from `app.modules`.
//!
//! Every `pub fn` returning `void` with a server handler signature in a listed
//! module is an endpoint, callable from any route. Its id hashes
//! "module path:decl name", so the server and the browser agree without
//! runtime state. Handlers declared in a `.zig` file are registered by
//! re-exporting them from a `.zx` file: `pub const save = handlers.save;`.
const std = @import("std");
const zx = @import("../../root.zig");
const app = @import("app");

const Action = zx.server.Action;
const Event = zx.server.Event;
const StateContext = zx.StateContext;
const ClientAction = zx.client.Action;
const ClientEvent = zx.client.Event;
const File = @import("../core/http/File.zig");

pub const ActionFn = *const fn (*Action) void;
pub const EventFn = *const fn (*Event) void;

pub const Kind = enum { action, event };

// `.{ .{ "path.zig", module, has_client_components }, ... }`, generated into `app.zig`.
const modules = if (@hasDecl(app, "modules")) app.modules else .{};

const components = if (@hasDecl(app, "components")) app.components else .{};

// The browser build only compiles modules rendering or defining `@client`
// components, so it resolves ids from those alone; any id of a handler
// dispatches on the server.
fn scanned(comptime m: anytype) bool {
    return zx.platform.role != .client or m[2] or definesClient(m[1]);
}

// Whether `M` declares a `@client` component rendered from another module.
fn definesClient(comptime M: type) bool {
    for (components) |c| {
        if (!@hasDecl(M, c.name)) continue;
        for (modules) |r| {
            if (!r[2] or !std.mem.eql(u8, r[0], c.path) or !@hasDecl(r[1], c.name)) continue;
            if (Key(@field(M, c.name)) == Key(@field(r[1], c.name))) return true;
        }
    }
    return false;
}

/// Whether `F` is a server action or event handler, by signature.
pub fn kind(comptime F: type) ?Kind {
    return comptime kindOf(F);
}

fn kindOf(comptime F: type) ?Kind {
    const info = switch (@typeInfo(F)) {
        .@"fn" => |f| f,
        else => return null,
    };
    if (info.is_generic or info.return_type != void) return null;
    const params = info.param_types;
    if (params.len == 0 or params.len > 2) return null;
    const arg = params[0] orelse return null;

    if (params.len == 2) {
        if (params[1] != *StateContext) return null;
        return if (arg == Action or isFormData(arg)) .action else null;
    }
    if (arg == *Action or arg == Action or arg == *Action.Stateful) return .action;
    if (arg == *Event or arg == Event or arg == *Event.Stateful) return .event;
    // `fn(struct { ... }) void` receives typed form data.
    return if (isFormData(arg)) .action else null;
}

// A struct `ctx.data()` can decode: one or more string, bool, int, float or file fields.
fn isFormData(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => return false,
    };
    if (info.is_tuple or info.field_types.len == 0) return false;
    for (info.field_types) |F| {
        const V = switch (@typeInfo(F)) {
            .optional => |o| o.child,
            else => F,
        };
        switch (@typeInfo(V)) {
            .bool, .int, .float => {},
            else => if (V != []const u8 and V != File) return false,
        }
    }
    return true;
}

/// The registered id of `handler`; a compile error when it is not registered.
pub fn id(comptime handler: anytype) u32 {
    return comptime find(fnOf(handler));
}

fn find(comptime h: anytype) u32 {
    @setEvalBranchQuota(100_000);
    for (modules) |m| {
        if (!scanned(m)) continue;
        for (@typeInfo(m[1]).@"struct".decl_names) |name| {
            const T = @TypeOf(@field(m[1], name));
            if (kind(T) == null or T != @TypeOf(h)) continue;
            if (Key(@field(m[1], name)) == Key(h)) return hash(m[0], name);
        }
    }
    @compileError("server handler `" ++ @typeName(@TypeOf(h)) ++ "` is not registered: declare it as a `pub fn` " ++
        "in a .zx file, or re-export it there with `pub const name = module.name;` " ++
        "(in a `@client` component's own .zx file when bound from one)");
}

/// The action registered under `handler_id`, if any.
pub fn action(handler_id: u32) ?ActionFn {
    inline for (modules) |m| {
        inline for (comptime @typeInfo(m[1]).@"struct".decl_names) |name| {
            if (comptime kind(@TypeOf(@field(m[1], name))) == .action) {
                if (handler_id == comptime hash(m[0], name)) return comptime actionFn(@field(m[1], name));
            }
        }
    }
    return null;
}

/// The event registered under `handler_id`, if any.
pub fn event(handler_id: u32) ?EventFn {
    inline for (modules) |m| {
        inline for (comptime @typeInfo(m[1]).@"struct".decl_names) |name| {
            if (comptime kind(@TypeOf(@field(m[1], name))) == .event) {
                if (handler_id == comptime hash(m[0], name)) return comptime eventFn(@field(m[1], name));
            }
        }
    }
    return null;
}

/// Adapts any action signature to `fn(*Action) void`.
pub fn actionFn(comptime handler: anytype) ActionFn {
    const h = fnOf(handler);
    const params = @typeInfo(@TypeOf(h)).@"fn".param_types;
    const arg = params[0].?;

    if (params.len == 2) return &struct {
        fn w(ctx: *Action) void {
            const sc = StateContext.init(ctx.arena, ctx._internal.inputs orelse &.{}) orelse return;
            ctx._internal.state_ctx = sc;
            if (comptime arg == Action) h(ctx.*, sc) else h(ctx.data(arg), sc);
        }
    }.w;
    if (arg == *Action) return &h;
    if (arg == Action) return &struct {
        fn w(ctx: *Action) void {
            h(ctx.*);
        }
    }.w;
    if (arg == *Action.Stateful) return &struct {
        fn w(ctx: *Action) void {
            const sc = StateContext.init(ctx.arena, ctx._internal.inputs orelse &.{}) orelse return;
            ctx._internal.state_ctx = sc;
            var sf = Action.Stateful{ .inner = ctx };
            h(&sf);
        }
    }.w;
    return &struct {
        fn w(ctx: *Action) void {
            h(ctx.data(arg));
        }
    }.w;
}

/// Adapts any event signature to `fn(*Event) void`.
pub fn eventFn(comptime handler: anytype) EventFn {
    const h = fnOf(handler);
    const arg = @typeInfo(@TypeOf(h)).@"fn".param_types[0].?;

    if (arg == *Event) return &h;
    if (arg == Event) return &struct {
        fn w(ctx: *Event) void {
            h(ctx.*);
        }
    }.w;
    return &struct {
        fn w(ctx: *Event) void {
            const sc = StateContext.init(ctx.arena, ctx._internal.payload.states) orelse return;
            ctx._internal.state_ctx = sc;
            var sf = Event.Stateful{ .inner = ctx };
            h(&sf);
        }
    }.w;
}

fn fnOf(comptime handler: anytype) FnOf(@TypeOf(handler)) {
    return if (@typeInfo(@TypeOf(handler)) == .pointer) handler.* else handler;
}

fn FnOf(comptime T: type) type {
    return if (@typeInfo(T) == .pointer) @typeInfo(T).pointer.child else T;
}

// Identity of a function without analyzing its body (which may be server-only).
fn Key(comptime f: anytype) type {
    return struct {
        const fun = f;
    };
}

// Always evaluated at comptime by its callers.
fn hash(comptime path: []const u8, comptime name: []const u8) u32 {
    @setEvalBranchQuota(100_000);
    return std.hash.Fnv1a_32.hash(path ++ ":" ++ name);
}
