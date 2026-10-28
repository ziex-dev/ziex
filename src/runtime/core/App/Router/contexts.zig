const std = @import("std");
const zx = @import("../../../../root.zig");
const reactivity = @import("../../../client/reactivity.zig");

const ActionContext = @import("../../../server/Action.zig");
const ClientActionContext = @import("../../../client/Action.zig");
const ClientEvent = @import("../../../client/Event.zig");
const CoreEvent = @import("../../Event.zig");
const Request = @import("../../http/Request.zig");
const Response = @import("../../http/Response.zig");
const ServerEvent = @import("../../../server/Event.zig");
const routing = @import("routing.zig");

const StateContext = CoreEvent.StateContext;
const Allocator = zx.Allocator;

// TODO: Re-work proxy arhitecture to allow intercepting request before and after
pub const ProxyContext = struct {
    request: Request,
    response: Response,
    allocator: Allocator,
    arena: Allocator,
    io: std.Io,

    _internal: Internal = .{},

    pub const Internal = struct {
        aborted: bool = false,
        state_ptr: ?*const anyopaque = null,
    };

    pub fn init(request: Request, response: Response, allocator: Allocator, arena: Allocator, io: std.Io) ProxyContext {
        return .{ .request = request, .response = response, .allocator = allocator, .arena = arena, .io = io };
    }

    pub fn state(self: *ProxyContext, value: anytype) void {
        const T = @TypeOf(value);
        const ptr = self.arena.create(T) catch return;
        ptr.* = value;
        self._internal.state_ptr = @ptrCast(ptr);
    }

    pub fn abort(self: *ProxyContext) void {
        self._internal.aborted = true;
    }

    pub fn next(self: *ProxyContext) void {
        _ = self;
    }

    pub fn isAborted(self: *const ProxyContext) bool {
        return self._internal.aborted;
    }
};

//  ----- ComponentCtx ----- //
const BindSignMsg =
    \\
    \\Handler must be one of:
    \\ - fn(*zx.client.Event.Stateful) void
    \\ - fn(*zx.client.Event) void
    \\ - fn(*zx.client.Action.Stateful) void
    \\ - fn(*zx.client.Action) void
    \\ - fn(zx.client.Action) void
    \\ - fn(*zx.server.Event.Stateful) void
    \\ - fn(*zx.server.Event) void
    \\ - fn(*zx.server.Action.Stateful) void
    \\ - fn(*zx.server.Action) void
    \\ - fn(ActionContext, *StateContext) void
    \\ - fn(struct, *StateContext) void
    \\
    \\Got:
    \\ -
;

pub fn ComponentCtx(comptime PropsType: type) type {
    return struct {
        const Self = @This();
        props: PropsType,
        allocator: Allocator,
        io: std.Io,
        children: ?zx.Component = null,

        _internal: Internal = .{},

        pub const Internal = struct {
            component_id: []const u8 = "",
            state_idx: u32 = 0,
            action_idx: u32 = 0,
        };

        pub const fetch = routing.Fetch(Self).fetch;
        pub const fetchThen = routing.Fetch(Self).fetchThen;

        pub fn state(self: *Self, comptime T: type, initial: T) reactivity.StateInstance(T) {
            const slot = (1 << 20) + self._internal.state_idx;
            self._internal.state_idx += 1;
            return reactivity.State(T).getOrCreate(self.allocator, self._internal.component_id, slot, initial) catch @panic("State(T).getOrCreate");
        }

        /// Bind a server/client form action with a pending mirror and settle options.
        ///
        /// ```zig
        /// const create = ctx.action(handleCreate, .{ .reset = .on_success });
        /// <form action={create}>
        ///   <input disabled={create.pending} name="title" />
        /// </form>
        /// ```
        pub fn action(self: *Self, comptime handler: anytype, opts: anytype) zx.ActionHandle {
            const options = zx.ActionHandle.normalizeOptions(opts);
            const alloc = if (zx.platform.role == .client) zx.allocator else self.allocator;

            const action_idx = self._internal.action_idx;
            self._internal.action_idx += 1;
            const pending_state = reactivity.actionPendingState(alloc, self._internal.component_id, action_idx);

            var eh = self.bind(handler);
            if (comptime zx.platform.role == .client) {
                eh.pending_state = @ptrCast(pending_state);
                eh.on_settle = options.on_settle;
                eh.reset_policy = options.reset;
            }

            return .{
                .handler = eh,
                .pending = pending_state.get(),
            };
        }

        pub fn sbind(self: *Self, comptime handler: anytype, states: anytype) zx.EventHandler {
            const HandlerFnType = switch (@typeInfo(@TypeOf(handler))) {
                .@"fn" => @TypeOf(handler),
                .pointer => |p| p.child,
                else => @compileError("sbind: expected a function"),
            };
            const params = @typeInfo(HandlerFnType).@"fn".param_types;

            comptime if (!(params.len == 1 and params[0].? == *ServerEvent.Stateful))
                @compileError("sbind: handler must be fn(*zx.server.Event.Stateful) void");

            const alloc = if (zx.platform.role == .client) zx.allocator else self.allocator;
            const bound_states = zx.EventHandler.buildStates(alloc, states);
            return zx.EventHandler.serverSS(handler, alloc, bound_states);
        }

        pub fn bind(self: *Self, comptime handler: anytype) zx.EventHandler {
            const alloc = if (zx.platform.role == .client) zx.allocator else self.allocator;

            const HandlerType = @TypeOf(handler);
            const FnType = switch (@typeInfo(HandlerType)) {
                .@"fn" => HandlerType,
                .pointer => |p| p.child,
                else => @compileError(BindSignMsg ++ @typeName(HandlerType)),
            };
            const params = @typeInfo(FnType).@"fn".param_types;

            return switch (zx.platform.role) {
                .server => switch (FnType) {
                    // Server events
                    fn (*ServerEvent.Stateful) void => zx.EventHandler.serverS(handler, alloc, self._internal.component_id, self._internal.state_idx),
                    fn (*ServerEvent) void => zx.EventHandler.server(handler, alloc),

                    // Server actions
                    fn (*ActionContext.Stateful) void => zx.EventHandler.actionStateful(handler, alloc, self._internal.component_id, self._internal.state_idx),
                    fn (ActionContext, *StateContext) void => actionBind(handler, alloc, self),
                    fn (*ActionContext) void => actionBind(handler, alloc, self),

                    // Client stubs
                    fn (*ClientEvent) void => zx.EventHandler.clientStub(),
                    fn (*ClientEvent.Stateful) void => zx.EventHandler.clientStub(),
                    fn (*ClientActionContext.Stateful) void => zx.EventHandler.clientStub(),
                    fn (*ClientActionContext) void => zx.EventHandler.clientStub(),
                    fn (ClientActionContext) void => zx.EventHandler.clientStub(),
                    else => bindServerFallback(handler, alloc, self, HandlerType, params),
                },
                .client => switch (FnType) {
                    // Client events
                    fn (*ClientEvent) void => zx.EventHandler.client(handler),
                    fn (*ClientEvent.Stateful) void => zx.EventHandler.clientS(handler, alloc, self._internal.component_id),

                    // Client actions
                    fn (*ClientActionContext.Stateful) void => zx.EventHandler.actionClientStateful(handler, alloc, self._internal.component_id),
                    fn (*ClientActionContext) void => zx.EventHandler.actionClient(handler),
                    fn (ClientActionContext) void => zx.EventHandler.actionClient(handler),

                    // Server action/event dispatchers
                    fn (*ServerEvent.Stateful) void => zx.EventHandler.serverEventStub(alloc, collectBoundStates(alloc, self)),
                    fn (*ServerEvent) void => zx.EventHandler.serverEventStub(alloc, &.{}),
                    fn (*ActionContext.Stateful) void => zx.EventHandler.serverActionStub(alloc, collectBoundStates(alloc, self)),
                    fn (ActionContext, *StateContext) void => zx.EventHandler.serverActionStub(alloc, collectBoundStates(alloc, self)),
                    fn (*ActionContext) void => zx.EventHandler.serverActionStub(alloc, &.{}),
                    else => bindClientFallback(handler, alloc, self, HandlerType, params),
                },
            };
        }
    };
}

fn bindServerFallback(comptime handler: anytype, alloc: Allocator, ctx: anytype, comptime HandlerType: type, comptime params: []const ?type) zx.EventHandler {
    if (comptime isClientOnlyHandler(params)) {
        return zx.EventHandler.clientStub();
    }

    if (comptime isServerEventHandler(params)) {
        return zx.EventHandler.server(handler, alloc);
    }

    if (comptime isStructuredServerActionHandler(params)) {
        return actionBind(handler, alloc, ctx);
    }

    @compileError(BindSignMsg ++ @typeName(HandlerType));
}

fn bindClientFallback(comptime _: anytype, alloc: Allocator, ctx: anytype, comptime HandlerType: type, comptime params: []const ?type) zx.EventHandler {
    if (comptime isServerEventHandler(params)) {
        return zx.EventHandler.serverEventStub(alloc, &.{});
    }

    if (comptime isStructuredServerActionHandler(params)) {
        return zx.EventHandler.serverActionStub(alloc, collectBoundStates(alloc, ctx));
    }

    @compileError(BindSignMsg ++ @typeName(HandlerType));
}

fn isServerEventHandler(comptime params: []const ?type) bool {
    return comptime params.len == 1 and params[0] == *ServerEvent;
}

fn isStructuredServerActionHandler(comptime params: []const ?type) bool {
    return comptime params.len == 2 and
        params[0] != null and
        @typeInfo(params[0].?) == .@"struct" and
        params[0] != ActionContext and
        params[1] == *StateContext;
}

fn isClientOnlyHandler(comptime params: []const ?type) bool {
    if (comptime params.len != 1 or params[0] == null) return false;

    const arg0 = params[0].?;
    if (comptime arg0 == *ClientEvent or arg0 == *ClientEvent.Stateful) return true;
    if (comptime arg0 == *ClientActionContext or arg0 == ClientActionContext or arg0 == *ClientActionContext.Stateful) return true;

    return false;
}

fn collectBoundStates(alloc: Allocator, ctx: anytype) []const zx.EventHandler.Bound {
    return reactivity.collectStateBoundEntries(alloc, ctx._internal.component_id, ctx._internal.state_idx);
}

fn actionBind(comptime handler: anytype, alloc: Allocator, ctx: anytype) zx.EventHandler {
    const params = @typeInfo(@TypeOf(handler)).@"fn".param_types;
    const arg0 = params[0].?;

    if (comptime params.len == 1 and arg0 == *ActionContext) {
        const ec = alloc.create(zx.EventHandler.Context) catch @panic("OOM");
        // handler_id is added later in `x.Context.attr` from the attribute @src().
        ec.* = .{ .handler_id = 0, .bound_states = &.{} };
        return .{
            .callback = &zx.EventHandler.actionHandler,
            .context = @ptrCast(ec),
            .action_fn = &handler,
        };
    }

    if (comptime params.len == 2 and params[1] == *StateContext and
        (arg0 == ActionContext or @typeInfo(arg0) == .@"struct"))
    {
        const FormActionWrapper = struct {
            fn wrap(action_ctx_ptr: *ActionContext) void {
                const inputs = action_ctx_ptr._internal.inputs orelse &.{};
                const sc = StateContext.init(action_ctx_ptr.arena, inputs) orelse return;
                action_ctx_ptr._internal.state_ctx = sc;
                if (comptime arg0 == ActionContext) {
                    handler(action_ctx_ptr.*, sc);
                } else {
                    handler(action_ctx_ptr.data(arg0), sc);
                }
            }
        };
        const bound = collectBoundStates(alloc, ctx);
        const ec = alloc.create(zx.EventHandler.Context) catch @panic("OOM");
        // handler_id is stamped later in `x.Context.attr` from the attribute @src().
        ec.* = .{ .handler_id = 0, .bound_states = bound };
        return zx.EventHandler{
            .callback = &zx.EventHandler.actionHandler,
            .context = @ptrCast(ec),
            .action_fn = &FormActionWrapper.wrap,
            .bound_states = bound,
        };
    }

    @compileError(BindSignMsg ++ @typeName(@TypeOf(handler)));
}
