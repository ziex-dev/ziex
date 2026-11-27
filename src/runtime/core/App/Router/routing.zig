const std = @import("std");
const Request = @import("../../http/Request.zig");
const Response = @import("../../http/Response.zig");
const websocket = @import("../../websocket.zig");
const Socket = websocket.Socket;
const Client = @import("../../http/Client.zig");

pub const PageData = struct {
    const Store = struct {
        arena: std.mem.Allocator,
        map: std.StringHashMapUnmanaged([]const u8) = .empty,
    };

    _store: ?*Store = null,

    pub fn init(arena: std.mem.Allocator) PageData {
        const store = arena.create(Store) catch return .{};
        store.* = .{ .arena = arena };
        return .{ ._store = store };
    }

    pub fn set(self: PageData, key: []const u8, value: []const u8) void {
        const store = self._store orelse return;
        const gop = store.map.getOrPut(store.arena, key) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = store.arena.dupe(u8, key) catch {
                _ = store.map.remove(key);
                return;
            };
        }
        gop.value_ptr.* = store.arena.dupe(u8, value) catch return;
    }

    pub fn get(self: PageData, key: []const u8) ?[]const u8 {
        const store = self._store orelse return null;
        return store.map.get(key);
    }
};

pub const BaseContext = struct {
    const Self = @This();

    /// The incoming request, use this to access request body, headers, query, etc.
    request: Request,
    /// The outgoing response, use this to populate response body, status, headers, etc.
    response: Response,
    /// Global allocator passed from the app, only cleared when the app is deinitialized.
    allocator: std.mem.Allocator,
    /// Arena allocator cleared automatically after the request is processed.
    arena: std.mem.Allocator,
    /// Io passed from App.init()
    io: std.Io,
    /// Request-scoped page metadata shared with layouts (title, description, etc.).
    data: PageData = .{},

    pub fn init(request: Request, response: Response, alloc: std.mem.Allocator, io: std.Io) Self {
        return .{
            .request = request,
            .response = response,
            .allocator = alloc,
            .arena = request.arena,
            .io = io,
            .data = PageData.init(request.arena),
        };
    }

    pub fn fmt(self: Self, comptime format: []const u8, args: anytype) ![]u8 {
        return self.arena.print(format, args);
    }

    pub const fetch = Fetch(Self).fetch;
    pub const fetchThen = Fetch(Self).fetchThen;
};

pub const PageContext = BaseContext;
pub const LayoutContext = BaseContext;
pub const NotFoundContext = BaseContext;

pub const ErrorContext = struct {
    /// The incoming request, use this to access request body, headers, query, etc.
    request: Request,
    /// The outgoing response, use this to populate response body, status, headers, etc.
    response: Response,
    /// Global allocator
    allocator: std.mem.Allocator,
    /// Arena allocator for request-scoped allocations
    arena: std.mem.Allocator,
    /// Io passed from App.init()
    io: std.Io,
    /// The error that occurred
    err: anyerror,
    /// Request-scoped page metadata shared with layouts (title, description, etc.).
    data: PageData = .{},

    pub fn init(request: Request, response: Response, alloc: std.mem.Allocator, io: std.Io, err: anyerror) ErrorContext {
        return .{
            .request = request,
            .response = response,
            .allocator = alloc,
            .arena = request.arena,
            .io = io,
            .err = err,
            .data = PageData.init(request.arena),
        };
    }

    pub const fetch = Fetch(ErrorContext).fetch;
    pub const fetchThen = Fetch(ErrorContext).fetchThen;
};

pub const RouteContext = struct {
    const Self = @This();

    request: Request,
    response: Response,
    socket: Socket,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,

    pub fn init(request: Request, response: Response, alloc: std.mem.Allocator, io: std.Io) Self {
        return .{
            .request = request,
            .response = response,
            .socket = .{},
            .allocator = alloc,
            .arena = request.arena,
            .io = io,
        };
    }

    pub fn initWithSocket(request: Request, response: Response, socket: Socket, alloc: std.mem.Allocator, io: std.Io) Self {
        return .{
            .request = request,
            .response = response,
            .socket = socket,
            .allocator = alloc,
            .arena = request.arena,
            .io = io,
        };
    }

    pub fn fmt(self: Self, comptime format: []const u8, args: anytype) ![]u8 {
        return self.arena.print(format, args);
    }

    pub const fetch = Fetch(Self).fetch;
    pub const fetchThen = Fetch(Self).fetchThen;
};

/// Context for WebSocket message handlers
pub const SocketContext = SocketCtx(void);

/// Context for WebSocket handlers with custom data passed during upgrade
pub fn SocketCtx(comptime DataType: type) type {
    return struct {
        /// The WebSocket connection for sending messages
        socket: Socket,
        /// The client message
        message: websocket.Message,
        /// Custom data passed from upgrade handler
        data: DataType,
        /// Global allocator
        allocator: std.mem.Allocator,
        /// Arena allocator for request-scoped allocations
        arena: std.mem.Allocator,
        /// Io passed from App.init()
        io: std.Io,

        const Self = @This();

        pub fn fmt(self: Self, comptime format: []const u8, args: anytype) ![]u8 {
            return self.arena.print(format, args);
        }
    };
}

/// Context for SocketOpen handlers
pub const SocketOpenContext = SocketOpenCtx(void);

pub fn SocketOpenCtx(comptime DataType: type) type {
    return struct {
        /// The WebSocket connection for sending messages
        socket: Socket,
        /// Custom data passed from upgrade handler
        data: DataType,
        /// Global allocator
        allocator: std.mem.Allocator,
        /// Arena allocator for request-scoped allocations
        arena: std.mem.Allocator,
        /// Io passed from App.init()
        io: std.Io,

        const Self = @This();

        pub fn fmt(self: Self, comptime format: []const u8, args: anytype) ![]u8 {
            return self.arena.print(format, args);
        }
    };
}

/// Context for SocketClose handlers
pub const SocketCloseContext = SocketCloseCtx(void);

/// Context for SocketClose handlers with custom data passed during upgrade.
pub fn SocketCloseCtx(comptime DataType: type) type {
    return struct {
        /// The WebSocket connection
        socket: Socket,
        /// Custom data passed from upgrade handler
        data: DataType,
        /// Global allocator
        allocator: std.mem.Allocator,
        /// Arena allocator for request-scoped allocations
        arena: std.mem.Allocator,
        /// Io passed from App.init()
        io: std.Io,

        const Self = @This();

        pub fn fmt(self: Self, comptime format: []const u8, args: anytype) ![]u8 {
            return self.arena.print(format, args);
        }
    };
}

/// `fetch` / `fetchThen` for any context with an `io` field and an `arena` (or `allocator`)
/// that outlives the call.
pub fn Fetch(comptime Ctx: type) type {
    return struct {
        fn client(self: *const Ctx) Client {
            const allocator = if (@hasField(Ctx, "arena")) self.arena else self.allocator;
            return .{ .io = self.io, .allocator = allocator };
        }

        /// In the browser this suspends the calling handler (JSPI) until the response arrives.
        pub fn fetch(self: *const Ctx, options: Client.FetchOptions) Client.Error!Client.Result {
            var c = client(self);
            defer c.deinit();
            return c.fetch(options);
        }

        pub fn fetchThen(self: *const Ctx, options: Client.FetchOptions, context: anytype, comptime callback: fn (@TypeOf(context), Client.Error!Client.Result) void) void {
            var c = client(self);
            defer c.deinit();
            c.fetchThen(options, context, callback);
        }
    };
}
