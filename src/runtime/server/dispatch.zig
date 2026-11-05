const std = @import("std");
const zx = @import("../../root.zig");
const registry = @import("registry.zig");
const render = @import("render.zig");

const EventHandler = zx.EventHandler;
const Constants = EventHandler.Constants;

pub const PageFn = *const fn (zx.PageContext, ?*const anyopaque, ?*const anyopaque) anyerror!zx.Component;

pub const DispatchResult = union(enum) {
    /// Request did not match this handler type - continue normal handling.
    not_triggered,
    /// Handler was invoked successfully. `body` is serialized JSON state, or null if no state.
    ok: struct { body: ?[]u8 = null },
    /// Action was invoked natively (form POST). Continue rendering the page.
    ok_native,
    /// Handler was triggered but no registered handler was found after render.
    not_found,
    /// Page function raised an error during slow-path render.
    page_error: anyerror,
};

fn parseActionId(request: zx.server.Request) !u32 {
    const content_type = request.headers.get("content-type") orelse "";
    const is_multipart = std.mem.indexOf(u8, content_type, "multipart/form-data") != null;

    const action_id = blk: {
        // Multi-part Form
        if (is_multipart) if (request.multiFormData().getValue(Constants.action_form_name)) |raw|
            break :blk try std.fmt.parseInt(u32, raw, 10);

        // Form
        if (request.formData().get(Constants.action_form_name)) |raw|
            break :blk try std.fmt.parseInt(u32, raw, 10);

        // Client Form
        if (request.headers.get(Constants.action_header_name)) |raw|
            break :blk try std.fmt.parseInt(u32, raw, 10);

        return error.NotServerAction;
    };

    return action_id;
}

fn serializeStateOutputs(sc: anytype, allocator: std.mem.Allocator) !?[]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    try zx.util.zxon.serialize(sc._internal.outputs, &aw.writer, .{});
    return aw.written();
}

/// it is used to register the action handler in cases where they are not in the memory,
/// this is always true for statless hosting platform like Cloudflare worker
fn slowPathRender(
    page_fn: PageFn,
    pagectx: zx.PageContext,
    route_path: []const u8,
    arena: std.mem.Allocator,
    app_ptr: ?*const anyopaque,
    state_ptr: ?*const anyopaque,
    base_path: ?[]const u8,
) ?anyerror {
    var page_component = page_fn(pagectx, app_ptr, state_ptr) catch |err| return err;
    var discard = std.Io.Writer.Allocating.init(arena);
    render.current_route_path = route_path;
    page_component.render(&discard.writer, .{ .base_path = base_path }) catch {};
    render.current_route_path = null;
    return null;
}

/// Dispatches a server action request. Performs a fast-path registry lookup and falls back
/// to rendering the page to populate the registry before retrying.
/// Returns `not_triggered` if the request is not a server action.
pub fn dispatchAction(
    request: zx.server.Request,
    response: zx.server.Response,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    route_path: []const u8,
    pagectx: zx.PageContext,
    page_fn: ?PageFn,
    app_ptr: ?*const anyopaque,
    state_ptr: ?*const anyopaque,
    base_path: ?[]const u8,
) !DispatchResult {
    const action_id = parseActionId(request) catch return .not_triggered;
    const is_progressive = request.headers.has(Constants.action_header_name);
    const mfd = request.multiFormData();

    const action_states: ?[]const []const u8 = blk: {
        break :blk zx.util.zxon.parse(
            []const []const u8,
            arena,
            mfd.getValue(Constants.states_form_name) orelse break :blk null,
            .{},
        ) catch null;
    };

    var action_fn = registry.get(route_path, action_id);
    if (action_fn == null) if (page_fn) |pfn| {
        if (slowPathRender(pfn, pagectx, route_path, arena, app_ptr, state_ptr, base_path)) |err| {
            return .{ .page_error = err };
        }
    };
    action_fn = registry.get(route_path, action_id);

    if (action_fn) |af| {
        var action_ctx = zx.server.Action{
            .request = request,
            .response = response,
            .allocator = allocator,
            .arena = arena,
            .io = pagectx.io,
            ._internal = .{ .inputs = action_states },
        };
        af(&action_ctx);
        const body = if (action_ctx._internal.state_ctx) |sc| try serializeStateOutputs(sc, arena) else null;
        return if (is_progressive) .{ .ok = .{ .body = body } } else .ok_native;
    } else return .not_found;
}

/// Dispatches a server event request. Performs a fast-path registry lookup and falls back
/// to rendering the page to populate the registry before retrying.
/// Returns `not_triggered` if the request is not a server event.
pub fn dispatchServerEvent(
    request: zx.server.Request,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    route_path: []const u8,
    pagectx: zx.PageContext,
    page_fn: ?PageFn,
    app_ptr: ?*const anyopaque,
    state_ptr: ?*const anyopaque,
    base_path: ?[]const u8,
) !DispatchResult {
    const raw_handler_id = request.headers.get(Constants.event_header_name) orelse return .not_triggered;
    const handler_id = std.fmt.parseInt(u32, raw_handler_id, 10) catch return .not_found;
    const payload = zx.util.zxon.parse(zx.EventHandler.Payload, arena, request.text() orelse return .not_found, .{}) catch return .not_found;

    var event_fn = registry.getEvent(route_path, handler_id);
    if (event_fn == null) if (page_fn) |pfn| {
        if (slowPathRender(pfn, pagectx, route_path, arena, app_ptr, state_ptr, base_path)) |err| {
            return .{ .page_error = err };
        }
    };
    event_fn = registry.getEvent(route_path, handler_id);

    if (event_fn) |ef| {
        var event_ctx = zx.server.Event{
            .allocator = allocator,
            .arena = arena,
            .io = pagectx.io,
            ._internal = .{ .payload = payload },
        };
        ef(&event_ctx);
        const body = if (event_ctx._internal.state_ctx) |sc| try serializeStateOutputs(sc, arena) else null;
        return .{ .ok = .{ .body = body } };
    } else return .not_found;
}
