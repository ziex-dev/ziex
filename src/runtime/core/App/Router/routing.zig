const std = @import("std");
const Request = @import("../../Http/Request.zig");
const Response = @import("../../Http/Response.zig");
const Http = @import("../../Http.zig");

pub const PageData = struct {
    const Store = struct {
        arena: std.mem.Allocator,
        map: std.StringHashMapUnmanaged([]const u8) = .{},
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

    /// The incoming request, use this to access request body, headers, queries, etc.
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

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn fmt(self: Self, comptime format: []const u8, args: anytype) ![]u8 {
        return fmtInner(self.arena, format, args);
    }
};

pub const PageContext = BaseContext;
pub const LayoutContext = BaseContext;
pub const NotFoundContext = BaseContext;

pub const ErrorContext = struct {
    /// The incoming request, use this to access request body, headers, queries, etc.
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

    pub fn deinit(self: *ErrorContext) void {
        self.allocator.destroy(self);
    }
};

/// Socket options for configuring WebSocket behavior
pub const SocketOptions = struct {
    /// When true, publish() will also send the message to the sender.
    publish_to_self: bool = false,
};

pub const Socket = struct {
    _internal: Internal = .{},

    pub const Internal = struct {
        http: Http = .{},
        attached: bool = false,
    };

    pub fn upgrade(self: Socket, data: anytype) !void {
        if (!self._internal.attached) return;
        const DataType = @TypeOf(data);
        if (DataType == void) {
            try self._internal.http.wsUpgrade(null);
        } else {
            try self._internal.http.wsUpgrade(std.mem.asBytes(&data));
        }
    }

    pub fn write(self: Socket, data: []const u8) !void {
        if (!self._internal.attached) return;
        try self._internal.http.wsWrite(data);
    }

    pub fn read(self: Socket) ?[]const u8 {
        if (!self._internal.attached) return null;
        return self._internal.http.wsRead();
    }

    pub fn close(self: Socket) void {
        if (!self._internal.attached) return;
        self._internal.http.wsClose();
    }

    pub fn isUpgraded(self: Socket) bool {
        return self._internal.attached;
    }

    /// Subscribe to a topic to receive published messages.
    /// Multiple sockets can subscribe to the same topic.
    ///
    /// Example:
    /// ```zig
    /// ctx.socket.subscribe("chat-room");
    /// ctx.socket.subscribe("notifications");
    /// ```
    pub fn subscribe(self: Socket, topic: []const u8) void {
        if (!self._internal.attached) return;
        self._internal.http.wsSubscribe(topic);
    }

    /// Unsubscribe from a topic to stop receiving messages.
    ///
    /// Example:
    /// ```zig
    /// ctx.socket.unsubscribe("chat-room");
    /// ```
    pub fn unsubscribe(self: Socket, topic: []const u8) void {
        if (!self._internal.attached) return;
        self._internal.http.wsUnsubscribe(topic);
    }

    /// Publish a message to all subscribers of a topic, excluding the sender.
    /// Returns the number of sockets the message was sent to.
    ///
    /// Example:
    /// ```zig
    /// const sent = ctx.socket.publish("chat-room", "Hello everyone!");
    /// ```
    pub fn publish(self: Socket, topic: []const u8, message: []const u8) usize {
        if (!self._internal.attached) return 0;
        return self._internal.http.wsPublish(topic, message);
    }

    /// Check if this socket is subscribed to a topic.
    ///
    /// Example:
    /// ```zig
    /// if (ctx.socket.isSubscribed("chat-room")) {
    ///     // ...
    /// }
    /// ```
    pub fn isSubscribed(self: Socket, topic: []const u8) bool {
        if (!self._internal.attached) return false;
        return self._internal.http.wsIsSubscribed(topic);
    }

    /// Configure whether publish() sends to self.
    ///
    /// Example:
    /// ```zig
    /// ctx.socket.setPublishToSelf(true);
    /// // Now publish() will include the sender
    /// ```
    pub fn setPublishToSelf(self: Socket, value: bool) void {
        if (!self._internal.attached) return;
        self._internal.http.wsSetPublishToSelf(value);
    }

    /// Configure socket options.
    ///
    /// Example:
    /// ```zig
    /// ctx.socket.configure(.{ .publish_to_self = true });
    /// ```
    pub fn configure(self: Socket, options: SocketOptions) void {
        self.setPublishToSelf(options.publish_to_self);
    }
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
        return fmtInner(self.arena, format, args);
    }
};

pub const SocketMessageType = enum {
    text,
    binary,
};

/// Context for WebSocket message handlers
pub const SocketContext = SocketCtx(void);

/// Context for WebSocket handlers with custom data passed during upgrade
pub fn SocketCtx(comptime DataType: type) type {
    return struct {
        /// The WebSocket connection for sending messages
        socket: Socket,
        /// The client message data
        message: []const u8,
        /// The message type
        message_type: SocketMessageType,
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
            return fmtInner(self.arena, format, args);
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
            return fmtInner(self.arena, format, args);
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
            return fmtInner(self.arena, format, args);
        }
    };
}

inline fn fmtInner(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    aw.writer.print(format, args) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}
