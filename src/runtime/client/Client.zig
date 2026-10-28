pub const Client = @This();

const std = @import("std");
const builtin = @import("builtin");

const zx = @import("../../root.zig");
const zx_info = @import("zx_info");
const app = @import("app");
const app_opts = @import("app_opts");
const App = @import("../core/App.zig");

const window = @import("window.zig");
const vtree_mod = @import("render.zig");
const dom_cmd = @import("dom_cmd.zig");
const core_vdom = @import("../core/vdom.zig");
const reactivity = @import("reactivity.zig");

const is_wasm = window.is_wasm;
const is_dev = App.mode == .dev;

const VDOMTree = vtree_mod.VDOMTree;
const Document = window.Document;
const Console = window.Console;
const areComponentsSameType = vtree_mod.areComponentsSameType;
const js = window.js;

pub const EventType = @import("event_type.zig").EventType;

pub const ComponentMeta = struct {
    pub const Type = enum { client };

    type: Type = .client,
    id: []const u8,
    name: []const u8,
    path: []const u8,
    route: ?[]const u8,
    import: *const fn (allocator: std.mem.Allocator, cmp_name: []const u8, data_zon: ?[]const u8) zx.Component,

    pub fn init(comptime func: anytype) *const fn (std.mem.Allocator, []const u8, ?[]const u8) zx.Component {
        // TODO: Reuse from root.zig
        const FuncInfo = @typeInfo(@TypeOf(func));

        if (FuncInfo != .@"fn") {
            @compileError("Client.ComponentMeta.init requires a function");
        }

        const param_count = FuncInfo.@"fn".param_types.len;
        if (param_count < 1 or param_count > 2) {
            @compileError("Component function must have 1 or 2 parameters");
        }

        const FirstParamType = FuncInfo.@"fn".param_types[0].?;
        const first_is_allocator = FirstParamType == std.mem.Allocator;
        const first_is_ctx_ptr = @typeInfo(FirstParamType) == .pointer and
            @hasField(@typeInfo(FirstParamType).pointer.child, "allocator") and
            @hasField(@typeInfo(FirstParamType).pointer.child, "children");

        return &struct {
            fn normalizeResult(result: anytype) zx.Component {
                const T = @TypeOf(result);
                if (T == zx.Component) {
                    return result;
                }
                if (@typeInfo(T) == .optional) {
                    return result orelse .none;
                }
                if (@typeInfo(T) == .error_union) {
                    const payload = result catch |err| {
                        std.log.err("Component error: {}", .{err});
                        return .none;
                    };
                    if (@typeInfo(@TypeOf(payload)) == .optional) {
                        return payload orelse .none;
                    }
                    return payload;
                }
                return result;
            }

            fn wrapper(allocator: std.mem.Allocator, cmp_name: []const u8, props_json: ?[]const u8) zx.Component {
                _ = cmp_name;
                if (first_is_allocator and param_count == 1) {
                    return normalizeResult(func(allocator));
                }

                if (first_is_allocator and param_count == 2) {
                    const PropsType = FuncInfo.@"fn".param_types[1].?;
                    const props = if (props_json) |pj| zx.util.zxon.parse(PropsType, allocator, pj, .{}) catch std.mem.zeroes(PropsType) else std.mem.zeroes(PropsType);
                    return normalizeResult(func(allocator, props));
                }

                if (first_is_ctx_ptr) {
                    const CtxType = @typeInfo(FirstParamType).pointer.child;
                    const ctx = allocator.create(CtxType) catch @panic("OOM");
                    ctx.allocator = allocator;
                    ctx.children = null;

                    // Reset hook slots for stable order across renders.
                    if (@hasField(CtxType, "_internal")) {
                        ctx._internal = .{
                            .component_id = current_render_id,
                            .state_idx = 0,
                        };
                    }

                    if (@hasField(CtxType, "props")) {
                        const PropsFieldType = @FieldType(CtxType, "props");
                        if (PropsFieldType != void) {
                            ctx.props = if (props_json) |pj| zx.util.zxon.parse(PropsFieldType, allocator, pj, .{}) catch std.mem.zeroes(PropsFieldType) else std.mem.zeroes(PropsFieldType);
                        }
                    }

                    return normalizeResult(func(ctx));
                }

                @compileError("Unsupported component signature");
            }
        }.wrapper;
    }
};

const HandlerKey = struct {
    velement_id: u64,
    event_type: EventType,
};

const InitOptions = struct {};

allocator: std.mem.Allocator,
components: []const ComponentMeta,
vtrees: std.StringHashMap(VDOMTree),
id_to_velement: std.AutoHashMap(u64, *vtree_mod.VElement),
handler_registry: std.AutoHashMap(HandlerKey, zx.EventHandler),
handler_bits: std.AutoHashMap(u64, u32),
/// Reused across renders to retain DomCmd capacity.
dom_cmds: dom_cmd.DomCmdBuffer,

/// Active component during `render` (for ComponentCtx / ifpl subscriptions).
var current_render_id: []const u8 = "";

/// Set in `renderAll` for WASM event/callback exports.
pub var global_client: ?*Client = null;

var kv_wasm: if (app_opts.feat_kv_client) zx.Kv.Wasm else void = if (app_opts.feat_kv_client) .{} else {};
var clnt = init(zx.allocator, .{});

pub fn init(allocator: std.mem.Allocator, _: InitOptions) Client {
    return .{
        .allocator = allocator,
        .components = &app.components,
        .vtrees = std.StringHashMap(VDOMTree).init(allocator),
        .id_to_velement = std.AutoHashMap(u64, *vtree_mod.VElement).init(allocator),
        .handler_registry = std.AutoHashMap(HandlerKey, zx.EventHandler).init(allocator),
        .handler_bits = std.AutoHashMap(u64, u32).init(allocator),
        .dom_cmds = dom_cmd.DomCmdBuffer.init(allocator),
    };
}

pub fn deinit(self: *Client) void {
    var iter = self.vtrees.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.deinit(self.allocator);
    }
    self.vtrees.deinit();
    self.id_to_velement.deinit();
    self.handler_registry.deinit();
    self.handler_bits.deinit();
    self.dom_cmds.deinit();
}

pub fn run() !void {
    @export(&mainClient, .{ .name = "mainClient" });
}

fn mainClient() callconv(.c) void {
    if (zx.platform.role != .client) return;

    if (comptime app_opts.feat_kv_client) {
        zx.kv = kv_wasm.kv();
    }
    if (is_dev) clnt.info();
    clnt.renderAll();
}

pub fn info(self: *Client) void {
    const console = Console.init();
    defer console.deinit();

    const title_css = "background-color: #00a8cc; color: white; font-weight: bold; padding: 3px 5px;";
    const version_css = "background-color: #141414; color: white; font-weight: normal; padding: 3px 5px;";

    const format_str = std.fmt.allocPrint(self.allocator, "%cZX%c{s}", .{zx_info.version}) catch unreachable;
    defer self.allocator.free(format_str);

    console.log(.{ js.string(format_str), js.string(title_css), js.string(version_css) });
}

pub fn renderAll(self: *Client) void {
    global_client = self;

    const console = Console.init();
    defer console.deinit();

    for (self.components) |component| {
        // An island rendered in a loop repeats its call-site id; hydrate every copy.
        var occurrence: usize = 0;
        while (true) : (occurrence += 1) {
            self.renderInstance(component, occurrence) catch |err| switch (err) {
                error.ContainerNotFound => break,
                else => {},
            };
        }
    }
}

pub fn render(self: *Client, cmp: ComponentMeta) !void {
    return self.renderInstance(cmp, 0);
}

/// Key for the `occurrence`-th island with `cmp_id`: the bare id for the first, so
/// single-instance islands keep their keys, then `id#1`, `id#2`, ... It scopes
/// state, pending flags and the vtree to one instance.
fn instanceKey(self: *Client, cmp_id: []const u8, occurrence: usize) ![]const u8 {
    if (occurrence == 0) return cmp_id;
    var buf: [128]u8 = undefined;
    const key = try std.fmt.bufPrint(&buf, "{s}#{d}", .{ cmp_id, occurrence });
    if (self.vtrees.getKey(key)) |existing| return existing;
    return try self.allocator.dupe(u8, key);
}

/// Splits an instance key from `instanceKey` back into id and occurrence.
pub fn parseInstanceKey(key: []const u8) struct { id: []const u8, occurrence: usize } {
    const hash = std.mem.lastIndexOfScalar(u8, key, '#') orelse return .{ .id = key, .occurrence = 0 };
    const occurrence = std.fmt.parseInt(usize, key[hash + 1 ..], 10) catch return .{ .id = key, .occurrence = 0 };
    return .{ .id = key[0..hash], .occurrence = occurrence };
}

pub fn renderInstance(self: *Client, cmp: ComponentMeta, occurrence: usize) !void {
    const allocator = self.allocator;
    const document = Document.init(allocator);

    // Boundary: <!--$id--> or <!--$id|props-->
    const marker = document.findCommentMarker(cmp.id, occurrence) catch return error.ContainerNotFound;
    const key = try self.instanceKey(cmp.id, occurrence);

    current_render_id = key;
    reactivity.active_component_id = key;
    core_vdom.current_component_owner = key;
    const Component = cmp.import(allocator, cmp.name, marker.props_zon);
    reactivity.active_component_id = null;

    // Batch all DOM mutations for this render into one `__zx._flush`.
    const prev_cmds = dom_cmd.activate(&self.dom_cmds);
    defer {
        self.dom_cmds.flush();
        dom_cmd.deactivate(prev_cmds);
    }

    const existing_vtree = self.vtrees.getPtr(key);

    // Hydration: first render replaces SSR content.
    if (existing_vtree == null) {
        const new_vtree = VDOMTree.init(allocator, Component);
        try self.vtrees.put(key, new_vtree);
        const vtree_ptr = self.vtrees.getPtr(key).?;

        const root_id = try vtree_mod.createPlatformNodes(allocator, vtree_ptr.vtree, self, .{ .marker = marker });
        if (root_id) |id| {
            marker.replaceContentById(id);
        }
        return;
    }

    // Re-render
    if (existing_vtree) |old_vtree| {
        const root_type_changed = !areComponentsSameType(old_vtree.vtree.component, Component);

        if (root_type_changed) {
            const new_vtree = VDOMTree.init(allocator, Component);
            defer old_vtree.deinit(allocator);

            try self.vtrees.put(key, new_vtree);
            const vtree_ptr = self.vtrees.getPtr(key).?;

            const root_id = try vtree_mod.createPlatformNodes(allocator, vtree_ptr.vtree, self, .{ .marker = marker });
            if (root_id) |id| {
                marker.replaceContentById(id);
            }
            return;
        }

        var patches = try old_vtree.diffWithComponent(allocator, Component);
        defer {
            for (patches.items) |*patch| {
                switch (patch.type) {
                    .UPDATE => {
                        patch.data.UPDATE.attributes.deinit();
                        patch.data.UPDATE.removed_attributes.deinit(allocator);
                    },
                    else => {},
                }
            }
            patches.deinit(allocator);
        }

        try vtree_mod.applyPatches(allocator, self, patches, .{});
    }
}

pub fn registerVElement(self: *Client, velement: *vtree_mod.VElement) void {
    const existing = self.id_to_velement.get(velement.id);
    if (existing == null or existing.? != velement) {
        self.id_to_velement.put(velement.id, velement) catch {};
    }

    switch (velement.component) {
        .element => |element| {
            if (element.attributes) |attributes| {
                for (attributes) |attr| {
                    if (attr.handler) |handler| {
                        if (EventType.fromAttributeName(attr.name)) |event_type| {
                            self.registerHandler(velement.id, event_type, handler);
                        }
                    }
                }
            }
        },
        else => {},
    }

    for (velement.children.items) |child| {
        self.registerVElement(child);
    }
}

pub fn registerHandler(self: *Client, velement_id: u64, event_type: EventType, handler: zx.EventHandler) void {
    const key = HandlerKey{ .velement_id = velement_id, .event_type = event_type };
    self.handler_registry.put(key, handler) catch {};
    const bit = @as(u32, 1) << @as(u5, @intCast(@backingInt(event_type)));
    const cur = self.handler_bits.get(velement_id) orelse 0;
    self.handler_bits.put(velement_id, cur | bit) catch {};
    if (zx.platform.role == .client) {
        window.ext._registerEventHandler(velement_id, @backingInt(event_type));
    }
}

pub fn getHandler(self: *Client, velement_id: u64, event_type: EventType) ?zx.EventHandler {
    const key = HandlerKey{ .velement_id = velement_id, .event_type = event_type };
    return self.handler_registry.get(key);
}

/// `clear_js == false` when JS already dropped the handlers via `_rc`/`_rpc`.
pub fn unregisterVElement(self: *Client, velement: *vtree_mod.VElement, clear_js: bool) void {
    _ = self.id_to_velement.remove(velement.id);

    if (self.handler_bits.fetchRemove(velement.id)) |entry| {
        const bits = entry.value;
        inline for (@typeInfo(EventType).@"enum".field_names, 0..) |name, i| {
            if (bits & (@as(u32, 1) << @intCast(i)) != 0) {
                const key = HandlerKey{
                    .velement_id = velement.id,
                    .event_type = @field(EventType, name),
                };
                _ = self.handler_registry.remove(key);
            }
        }
    }

    if (clear_js and zx.platform.role == .client) {
        window.ext._clearEventHandlers(velement.id);
    }

    for (velement.children.items) |child| {
        self.unregisterVElement(child, clear_js);
    }
}

pub fn getVElementById(self: *Client, id: u64) ?*vtree_mod.VElement {
    return self.id_to_velement.get(id);
}

/// `event_ref` is a NaN-boxed JS event object. Returns true if a handler ran.
pub fn dispatchEvent(self: *Client, velement_id: u64, event_type: EventType, event_ref: u64) bool {
    if (self.getHandler(velement_id, event_type)) |handler| {
        const event_context = zx.client.Event.init(event_ref);
        handler.callback(handler.context, event_context);
        return true;
    }
    return false;
}

pub fn dispatchEventByName(self: *Client, velement_id: u64, event_type_name: []const u8, event_ref: u64) bool {
    const event_type = std.meta.stringToEnum(EventType, event_type_name) orelse return false;
    return self.dispatchEvent(velement_id, event_type, event_ref);
}

export fn __zx_eventbridge(velement_id: u64, event_type_id: u8, event_ref: u64) void {
    if (zx.platform.role != .client) return;
    if (global_client) |client| {
        const event_type: EventType = @fromBackingInt(@intCast(event_type_id));
        _ = client.dispatchEvent(velement_id, event_type, event_ref);
    }
}

/// Browser `std.log` sink via `__zx._log`.
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level: u8 = switch (message_level) {
        .err => 0,
        .warn => 1,
        .info => 2,
        .debug => 3,
    };
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const msg = std.fmt.allocPrint(zx.allocator, prefix ++ format, args) catch return;
    defer zx.allocator.free(msg);
    @import("window/extern.zig")._log(level, msg.ptr, msg.len);
}
