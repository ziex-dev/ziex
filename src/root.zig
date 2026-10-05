/// Ziex - A full-stack web framework for Zig
/// This module provides the core component system, rendering engine, and utilities
const zx = @This();

const std = @import("std");
const builtin = @import("builtin");

const element = @import("element.zig");
const plfm = @import("platform.zig");

const routing = @import("runtime/core/App/Router/routing.zig");
const event = @import("runtime/core/Event.zig");
const opts = @import("runtime/core/App/Router/options.zig");
const ctxs = @import("runtime/core/App/Router/contexts.zig");
const reactivity = @import("runtime/client/reactivity.zig");
const app_mod = @import("runtime/core/App.zig");

// -- Build System --- //
pub const Build = @import("Build.zig");

// -- Core -- //
pub const ElementTag = element.Tag;
pub const Component = @import("Component.zig").Component;
pub const Element = @import("Component.zig").Element;

// Internal - Used by the .zx to .zig transpiler
pub const x = @import("x.zig");
pub const info = @import("zx_info");

// --- Aliases --- //
pub const Allocator = std.mem.Allocator;
pub const log = std.log;
pub const Init = switch (builtin.os.tag) {
    .freestanding => std.process.Init.Minimal,
    else => std.process.Init,
};

pub const App = app_mod;
pub const AppConfig = app_mod.Config;

// --- Namespaces --- //
pub const client = @import("runtime/client.zig");
pub const server = @import("runtime/server.zig");
pub const util = @import("util.zig");
pub const mdzx = @import("runtime/mdzx.zig");

// --- Reactivity --- //
pub const EventHandler = @import("runtime/core/Event/Handler.zig");
pub const ActionHandle = @import("runtime/core/Event/ActionHandle.zig");
pub const State = reactivity.State;

// --- Options --- //
pub const PageOptions = opts.PageOptions;
pub const LayoutOptions = opts.LayoutOptions;
pub const NotFoundOptions = opts.NotFoundOptions;
pub const ErrorOptions = opts.ErrorOptions;
pub const RouteOptions = opts.RouteOptions;
pub const ProxyOptions = opts.ProxyOptions;
pub const SocketOptions = routing.SocketOptions;

// --- Contexts --- //
pub const ProxyContext = ctxs.ProxyContext;
pub const StaticContext = opts.StaticContext;
pub const StaticParams = opts.StaticParams;
pub const StaticParam = opts.StaticParam;
pub const StaticFn = opts.StaticFn;
pub const PageData = routing.PageData;
pub const PageContext = routing.PageContext;
pub const LayoutContext = routing.LayoutContext;
pub const NotFoundContext = routing.NotFoundContext;
pub const ErrorContext = routing.ErrorContext;
pub const RouteContext = routing.RouteContext;
pub const SocketContext = routing.SocketContext;
pub const SocketCtx = routing.SocketCtx;
pub const SocketOpenContext = routing.SocketOpenContext;
pub const SocketOpenCtx = routing.SocketOpenCtx;
pub const SocketCloseContext = routing.SocketCloseContext;
pub const SocketCloseCtx = routing.SocketCloseCtx;
pub const SocketMessageType = routing.SocketMessageType;
pub const ComponentCtx = ctxs.ComponentCtx;
pub const ComponentContext = ComponentCtx(void);
pub const StateContext = event.StateContext;
pub const StateHandle = event.StateHandle;

pub const BuiltinAttribute = @import("attributes.zig").builtin;
pub const Platform = plfm.Platform;

// --- Routing --- //
pub const Router = app_mod.Router;

// --- Storage --- //
pub const Db = @import("runtime/core/Db.zig");
pub const Kv = @import("runtime/core/Kv.zig");
pub const Cache = @import("runtime/core/Cache.zig");

pub var db: Db = .failing;
pub var kv: Kv = .failing;
pub var cache: Cache = .failing;

// --- Net --- //
pub const Http = @import("runtime/core/Http.zig");
pub const Headers = @import("runtime/core/Http/Headers.zig");
pub const Fetch = @import("runtime/core/Fetch.zig");
pub const WebSocket = @import("runtime/core/WebSocket.zig");
pub const Io = Fetch.Io;
pub const Socket = routing.Socket;
pub const fetch = Fetch.fetch;

// --- Values --- //
pub const allocator = app_mod.allocator;
pub const io = app_mod.io;
pub const platform: Platform = plfm.platform;
pub const std_options = opts.std_options;

// --- Styling --- //
pub const style = @import("style/root.zig");
pub const Style = style.Style;


// Temp Design 