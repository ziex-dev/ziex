const std = @import("std");
const app_opts = @import("app_opts");

const zx = @import("../../root.zig");
const html_util = @import("../../util/html.zig");
const vdom = @import("../core/vdom.zig");
const dom_cmd = @import("dom_cmd.zig");
const ext = @import("window/extern.zig");
const window = @import("window.zig");

const reactivity = @import("reactivity.zig");

const is_wasm = window.is_wasm;
const Document = zx.client.Document;

/// Base path for the application, read from build options at comptime.
pub const RenderOptions = struct {
    base_path: ?[]const u8 = base_path,
    dom_parent_id: ?u64 = null,
    marker: ?Document.CommentMarker = null,
};

pub const VDOMTree = vdom;
pub const VNode = vdom.VNode;
pub const VElement = vdom.VElement;
pub const PatchType = vdom.PatchType;
pub const PatchData = vdom.PatchData;
pub const Patch = vdom.Patch;
pub const DiffError = vdom.DiffError;
pub const areComponentsSameType = vdom.areComponentsSameType;
pub const base_path: ?[]const u8 = app_opts.app_base_path;

/// Apply a list of patches to the live DOM.
pub fn applyPatches(
    allocator: zx.Allocator,
    client: anytype, // *Client
    patches: std.ArrayList(Patch),
    options: RenderOptions,
) !void {
    for (patches.items) |*patch| {
        switch (patch.type) {
            .UPDATE => {
                const data = patch.data.UPDATE;
                var attr_iter = data.attributes.iterator();
                while (attr_iter.next()) |entry| {
                    const name = entry.key_ptr.*;
                    const val = entry.value_ptr.*;
                    setAttrOrProp(data.vnode_id, name, val);
                }
                for (data.removed_attributes.items) |name| {
                    dom_cmd.removeAttr(data.vnode_id, name);
                    // For DOM properties, also reset the property to ensure
                    // the live state is updated (e.g. unchecking a checkbox).
                    if (isDomProperty(name)) {
                        dom_cmd.setProp(data.vnode_id, name, "false");
                    }
                }
            },
            .TEXT => {
                const data = patch.data.TEXT;
                dom_cmd.setNodeValue(data.vnode_id, data.new_text);
            },
            .RAW_HTML => {
                const data = patch.data.RAW_HTML;
                dom_cmd.setInnerHtml(data.vnode_id, data.html);
            },
            .PLACEMENT => {
                const data = &patch.data.PLACEMENT;
                const dom_parent_id = resolveDomParentId(client, data.parent_id);

                const resolved = try vdom.resolveComponent(allocator, data.vnode.component, data.vnode.owner_component_id, 0);
                const placed_is_fragment = resolved == .element and resolved.element.tag == .fragment;

                const create_options = RenderOptions{
                    .base_path = options.base_path,
                    .dom_parent_id = if (placed_is_fragment) dom_parent_id else null,
                    .marker = null,
                };
                _ = try createPlatformNodes(allocator, data.vnode, client, create_options);

                if (!placed_is_fragment) {
                    const ref_id = data.reference_id orelse blk: {
                        if (vnodeIsFragment(client, data.parent_id)) {
                            break :blk findFragmentInsertReference(client, data.parent_id, data.index);
                        }
                        break :blk findChildInsertReference(client, data.parent_id, data.index);
                    };
                    if (ref_id) |reference_id| {
                        dom_cmd.insertBefore(dom_parent_id, data.vnode.id, reference_id);
                    } else {
                        dom_cmd.appendChild(dom_parent_id, data.vnode.id);
                    }
                }

                if (client.getVElementById(data.parent_id)) |parent_vnode| {
                    const index = @min(data.index, parent_vnode.children.items.len);
                    try parent_vnode.children.insert(allocator, index, data.vnode);
                }
            },
            .DELETION => {
                const data = patch.data.DELETION;
                const is_fragment = vnodeIsFragment(client, data.vnode_id);

                if (!is_fragment) {
                    const dom_parent_id = resolveDomParentId(client, data.parent_id);
                    dom_cmd.removeChild(dom_parent_id, data.vnode_id);
                }

                if (client.getVElementById(data.vnode_id)) |vnode| {
                    client.unregisterVElement(vnode, is_fragment);
                }

                if (client.getVElementById(data.parent_id)) |parent_vnode| {
                    for (parent_vnode.children.items, 0..) |child, i| {
                        if (child.id == data.vnode_id) {
                            var removed = parent_vnode.children.orderedRemove(i);
                            removed.deinit(allocator);
                            break;
                        }
                    }
                }
            },
            .REPLACE => {
                const data = &patch.data.REPLACE;
                const dom_parent_id = resolveDomParentId(client, data.parent_id);
                const old_is_fragment = vnodeIsFragment(client, data.old_vnode_id);

                _ = try createPlatformNodes(allocator, data.new_vnode, client, options);

                if (old_is_fragment) {
                    const ref_id = findFragmentInsertReference(client, data.old_vnode_id, 0);
                    if (ref_id) |reference_id| {
                        dom_cmd.insertBefore(dom_parent_id, data.new_vnode.id, reference_id);
                    } else {
                        dom_cmd.appendChild(dom_parent_id, data.new_vnode.id);
                    }
                } else if (vnodeIsFragment(client, data.new_vnode.id)) {
                    dom_cmd.removeChild(dom_parent_id, data.old_vnode_id);
                } else {
                    dom_cmd.replaceChild(dom_parent_id, data.new_vnode.id, data.old_vnode_id);
                }

                if (client.getVElementById(data.old_vnode_id)) |old_vnode| {
                    client.unregisterVElement(old_vnode, old_is_fragment);
                }

                if (client.getVElementById(data.parent_id)) |parent_vnode| {
                    for (parent_vnode.children.items, 0..) |child, i| {
                        if (child.id == data.old_vnode_id) {
                            const old = parent_vnode.children.items[i];
                            parent_vnode.children.items[i] = data.new_vnode;
                            old.deinit(allocator);
                            break;
                        }
                    }
                }
            },
            .MOVE => {
                const data = patch.data.MOVE;
                const dom_parent_id = resolveDomParentId(client, data.parent_id);

                const ref_id = data.reference_id orelse findFragmentInsertReference(client, data.parent_id, data.new_index);
                if (ref_id) |reference_id| {
                    dom_cmd.insertBefore(dom_parent_id, data.vnode_id, reference_id);
                } else {
                    dom_cmd.appendChild(dom_parent_id, data.vnode_id);
                }

                if (client.getVElementById(data.parent_id)) |parent_vnode| {
                    var old_idx: ?usize = null;
                    for (parent_vnode.children.items, 0..) |child, i| {
                        if (child.id == data.vnode_id) {
                            old_idx = i;
                            break;
                        }
                    }
                    if (old_idx) |idx| {
                        const removed = parent_vnode.children.orderedRemove(idx);
                        const new_idx = @min(data.new_index, parent_vnode.children.items.len);
                        try parent_vnode.children.insert(allocator, new_idx, removed);
                    }
                }
            },
        }
    }
}

/// Context stored on the heap so formActionCallback can find the form by vnode_id.
/// When `bound_states` is non-empty the submission is stateful: bound state values
/// are serialised, sent as `__$states`, and the response updates those states.
const FormActionCtx = struct {
    vnode_id: u64,
    action_id: u32 = 1,
    bound_states: []const zx.EventHandler.Bound = &.{},
    pending_state: ?*anyopaque = null,
    on_settle: ?*const fn (zx.ActionHandle.Outcome) void = null,
    reset_policy: zx.ActionHandle.Reset = .none,
};

/// Callback context for form action responses (state round-trip and/or settle).
const FormActionCallbackCtx = struct {
    vnode_id: u64,
    bound_states: []const zx.EventHandler.Bound,
    pending_state: ?*anyopaque = null,
    on_settle: ?*const fn (zx.ActionHandle.Outcome) void = null,
    reset_policy: zx.ActionHandle.Reset = .none,
};

fn pendingFromOpaque(ptr: *anyopaque) *reactivity.State(bool) {
    return @ptrCast(@alignCast(ptr));
}

/// Called when a form action response arrives; applies state updates and settle UX.
fn onFormActionResponse(ctx_ptr: *anyopaque, result: zx.http.Client.Error!zx.http.Client.Result) void {
    const cb_ctx: *FormActionCallbackCtx = @ptrCast(@alignCast(ctx_ptr));
    defer zx.allocator.destroy(cb_ctx);

    const outcome: zx.ActionHandle.Outcome = blk: {
        const resp = result catch break :blk .err;
        if (resp.status.class() != .success) break :blk .err;

        if (cb_ctx.bound_states.len > 0 and resp.body.len > 0) {
            const states = zx.util.zxon.parse([]const []const u8, zx.allocator, resp.body, .{}) catch break :blk .err;
            for (states, 0..) |state_json, i| {
                if (i >= cb_ctx.bound_states.len) break;
                const bs = cb_ctx.bound_states[i];
                bs.applyJson(bs.state_ptr, state_json);
            }
        }
        break :blk .ok;
    };

    if (cb_ctx.pending_state) |ps| {
        pendingFromOpaque(ps).set(false);
    }

    const should_reset = switch (cb_ctx.reset_policy) {
        .none => false,
        .on_success => outcome == .ok,
        .on_complete => true,
    };
    if (should_reset) {
        ext._formReset(cb_ctx.vnode_id);
    }

    if (cb_ctx.on_settle) |settle| {
        settle(outcome);
    }
}

/// onsubmit handler for form elements that carry an action handler.
/// Fire-and-forget when no states are bound and no settle UX is needed;
/// async round-trip otherwise (so pending / reset / on_settle can complete).
///
/// Important: do not re-render (disable controls) until after JS builds
/// `FormData` - disabled fields are omitted from multipart bodies.
fn formActionCallback(ctx: *anyopaque, event: zx.client.Event) void {
    if (!is_wasm) return;
    const form_ctx: *FormActionCtx = @ptrCast(@alignCast(ctx));
    event.preventDefault();

    if (form_ctx.pending_state) |ps| {
        const pending = pendingFromOpaque(ps);
        if (pending.get()) return;
        // Mark in-flight without scheduleRender so inputs stay enabled for FormData.
        pending.value = true;
    }

    const needs_settle = form_ctx.pending_state != null or
        form_ctx.on_settle != null or
        form_ctx.reset_policy != .none;

    if (form_ctx.bound_states.len == 0 and !needs_settle) {
        ext._submitFormAction(form_ctx.vnode_id, form_ctx.action_id);
        return;
    }

    // Serialise bound-state values → JSON array → __$states field (may be `[]`).
    const alloc = zx.allocator;
    var states_list = std.ArrayList([]const u8).empty;
    for (form_ctx.bound_states) |bs| {
        states_list.append(alloc, bs.getJson(alloc, bs.state_ptr)) catch {};
    }
    var aw = std.Io.Writer.Allocating.init(alloc);
    zx.util.zxon.serialize(states_list.items, &aw.writer, .{}) catch {};
    const states_json = aw.written();

    const cb_ctx = alloc.create(FormActionCallbackCtx) catch {
        if (form_ctx.pending_state) |ps| pendingFromOpaque(ps).set(false);
        return;
    };
    cb_ctx.* = .{
        .vnode_id = form_ctx.vnode_id,
        .bound_states = form_ctx.bound_states,
        .pending_state = form_ctx.pending_state,
        .on_settle = form_ctx.on_settle,
        .reset_policy = form_ctx.reset_policy,
    };

    const client_fetch = @import("fetch.zig");
    // On failure the callback has already run and released `cb_ctx`.
    const fetch_id = client_fetch.register(alloc, @ptrCast(cb_ctx), onFormActionResponse) orelse return;
    // FormData is built synchronously inside this extern while inputs are still enabled.
    ext._submitFormActionAsync(form_ctx.vnode_id, form_ctx.action_id, states_json.ptr, states_json.len, fetch_id);

    // Now flip pending UI (disabled / "Adding…").
    if (form_ctx.pending_state) |ps| {
        const pending = pendingFromOpaque(ps);
        reactivity.scheduleRender(pending.component_id);
    }
}

/// Build DOM nodes for a VNode subtree and register every node in the JS registry.
/// Returns the root vnode id, or null for fragment roots (children mounted individually).
pub fn createPlatformNodes(allocator: zx.Allocator, vnode: *VNode, client: anytype, options: RenderOptions) anyerror!?u64 {
    if (!is_wasm) return vnode.id;

    const resolved_component = try vdom.resolveComponent(allocator, vnode.component, vnode.owner_component_id, 0);

    const root_id: ?u64 = switch (resolved_component) {
        .none => blk: {
            dom_cmd.createText("", vnode.id);
            try attachCreatedNodeIfNeeded(vnode.id, options);
            break :blk vnode.id;
        },
        .text => |t| blk: {
            dom_cmd.createText(t, vnode.id);
            try attachCreatedNodeIfNeeded(vnode.id, options);
            break :blk vnode.id;
        },
        .element => |elem| blk: {
            if (elem.tag == .fragment) {
                client.registerVElement(vnode);
                const child_options = RenderOptions{
                    .base_path = options.base_path,
                    .dom_parent_id = options.dom_parent_id,
                    .marker = null,
                };
                for (vnode.children.items) |child| {
                    _ = try createPlatformNodes(allocator, child, client, child_options);
                }
                break :blk null;
            }

            if (elem.tag == .custom) {
                if (elem.custom_tag) |name| {
                    dom_cmd.createElementNamed(@backingInt(elem.tag), name, vnode.id);
                } else {
                    dom_cmd.createElement(@backingInt(zx.ElementTag.div), vnode.id);
                }
            } else {
                dom_cmd.createElement(@backingInt(elem.tag), vnode.id);
            }
            if (elem.attributes) |attrs| {
                var has_action_handler = false;
                var has_method = false;
                var form_bound_states: []const zx.EventHandler.Bound = &.{};
                var form_action_id: u32 = 1;
                var form_pending_state: ?*anyopaque = null;
                var form_on_settle: ?*const fn (zx.ActionHandle.Outcome) void = null;
                var form_reset_policy: zx.ActionHandle.Reset = .none;
                var client_action_handler: ?zx.EventHandler = null;

                for (attrs) |attr| {
                    if (std.mem.eql(u8, attr.name, "key")) continue;
                    if (attr.handler) |handler| {
                        if (handler.action_fn != null) {
                            has_action_handler = true;
                            form_bound_states = handler.bound_states;
                            form_action_id = handler.handler_id;
                            form_pending_state = handler.pending_state;
                            form_on_settle = handler.on_settle;
                            form_reset_policy = handler.reset_policy;
                        } else if (std.mem.eql(u8, attr.name, "action")) {
                            client_action_handler = handler;
                        }
                        continue;
                    }
                    if (std.mem.eql(u8, attr.name, "method")) has_method = true;
                    const val = attr.value orelse "";
                    // JSX `defaultValue`/`defaultChecked` → IDL props (form.reset() needs defaults).
                    const attr_name = if (std.mem.eql(u8, attr.name, "defaultValue"))
                        "defaultValue"
                    else if (std.mem.eql(u8, attr.name, "defaultChecked"))
                        "defaultChecked"
                    else
                        attr.name;

                    // Prefix href/src/action attributes with base_path when applicable
                    var final_val = val;
                    if (options.base_path) |bp| {
                        const normalized = html_util.normalizeBasePathForPrefixing(bp);
                        if (normalized) |nb| {
                            const is_prefixable = std.mem.eql(u8, attr_name, "href") or
                                std.mem.eql(u8, attr_name, "src") or
                                std.mem.eql(u8, attr_name, "action");
                            if (is_prefixable and html_util.shouldPrefixPathWithBasePath(nb, val)) {
                                // Owned by DomCmdBuffer until flush.
                                const prefixed = try std.mem.concat(allocator, u8, &.{ nb, val });
                                final_val = dom_cmd.takeOwnedActive(prefixed);
                            }
                        }
                    }

                    setAttrOrProp(vnode.id, attr_name, final_val);
                }

                // Mimic Next.js: auto-inject method="post" enctype="multipart/form-data"
                // on form elements with a server action handler
                if (elem.tag == .form and has_action_handler and !has_method) {
                    dom_cmd.setAttr(vnode.id, "method", "post");
                    dom_cmd.setAttr(vnode.id, "enctype", "multipart/form-data");
                }

                // Register onsubmit: server actions POST; client actions run handler.callback locally
                if (elem.tag == .form) {
                    const Client = @import("Client.zig");
                    if (has_action_handler) {
                        if (allocator.create(FormActionCtx) catch null) |form_ctx| {
                            form_ctx.* = .{
                                .vnode_id = vnode.id,
                                .action_id = form_action_id,
                                .bound_states = form_bound_states,
                                .pending_state = form_pending_state,
                                .on_settle = form_on_settle,
                                .reset_policy = form_reset_policy,
                            };
                            client.registerHandler(vnode.id, Client.EventType.submit, zx.EventHandler{
                                .callback = &formActionCallback,
                                .context = @ptrCast(form_ctx),
                            });
                        }
                    } else if (client_action_handler) |handler| {
                        client.registerHandler(vnode.id, Client.EventType.submit, handler);
                    }
                }
            }

            // When escaping is disabled (@escaping={.none}), the element's text
            // children are raw HTML and must be inserted via innerHTML
            if (elem.escaping == .none) {
                var aw = std.Io.Writer.Allocating.init(allocator);
                defer aw.deinit();
                for (vnode.children.items) |child| {
                    const resolved_child = try vdom.resolveComponent(allocator, child.component, child.owner_component_id, 0);
                    switch (resolved_child) {
                        .text => |t| try aw.writer.writeAll(t),
                        .none => {},
                        // Non-text children fall back to normal node creation below.
                        else => {},
                    }
                }
                const raw = aw.written();
                // Copy so the slice survives `aw.deinit` until DomCmd flush.
                const kept = try dom_cmd.dupeActive(allocator, raw);
                dom_cmd.setInnerHtml(vnode.id, kept);
                try attachCreatedNodeIfNeeded(vnode.id, options);
                break :blk vnode.id;
            }

            for (vnode.children.items) |child| {
                const resolved_child = try vdom.resolveComponent(allocator, child.component, child.owner_component_id, 0);
                const child_options = RenderOptions{
                    .base_path = options.base_path,
                    .dom_parent_id = null,
                    .marker = null,
                };
                if (resolved_child == .element and resolved_child.element.tag == .fragment) {
                    const frag_options = RenderOptions{
                        .base_path = options.base_path,
                        .dom_parent_id = vnode.id,
                        .marker = null,
                    };
                    _ = try createPlatformNodes(allocator, child, client, frag_options);
                } else {
                    _ = try createPlatformNodes(allocator, child, client, child_options);
                    dom_cmd.appendChild(vnode.id, child.id);
                }
            }

            try attachCreatedNodeIfNeeded(vnode.id, options);
            break :blk vnode.id;
        },
        .component_fn => |comp_fn| blk: {
            // Client islands: plain <div id="..." data-name="..."> placeholder.
            const island = comp_fn.island orelse unreachable;
            dom_cmd.createElement(@backingInt(zx.ElementTag.div), vnode.id);
            dom_cmd.setAttr(vnode.id, "id", island.id);
            dom_cmd.setAttr(vnode.id, "data-name", comp_fn.name);
            break :blk vnode.id;
        },
    };

    if (root_id) |_| client.registerVElement(vnode);
    return root_id;
}

fn isDomProperty(name: []const u8) bool {
    // IDL live state: setAttribute alone is wrong or incomplete for these.
    return std.mem.eql(u8, name, "checked") or
        std.mem.eql(u8, name, "value") or
        std.mem.eql(u8, name, "selected") or
        std.mem.eql(u8, name, "muted") or
        std.mem.eql(u8, name, "defaultValue") or
        std.mem.eql(u8, name, "defaultChecked") or
        std.mem.eql(u8, name, "indeterminate");
}

fn setAttrOrProp(vnode_id: u64, name: []const u8, val: []const u8) void {
    if (isDomProperty(name)) {
        dom_cmd.setProp(vnode_id, name, val);
    } else {
        dom_cmd.setAttr(vnode_id, name, val);
    }
}

fn attachCreatedNodeIfNeeded(vnode_id: u64, options: RenderOptions) !void {
    if (options.dom_parent_id) |parent_id| {
        dom_cmd.appendChild(parent_id, vnode_id);
    }
}

fn resolveDomParentId(client: anytype, parent_vnode_id: u64) u64 {
    if (client.getVElementById(parent_vnode_id)) |parent| {
        if (parent.component == .element and parent.component.element.tag == .fragment) {
            var vtrees_iter = client.vtrees.iterator();
            while (vtrees_iter.next()) |entry| {
                if (findDomParentInSubtree(entry.value_ptr.vtree, parent_vnode_id, null)) |id| return id;
            }
        }
    }
    return parent_vnode_id;
}

fn vnodeIsFragment(client: anytype, vnode_id: u64) bool {
    if (client.getVElementById(vnode_id)) |vnode| {
        return vnode.component == .element and vnode.component.element.tag == .fragment;
    }
    return false;
}

fn findDomParentInSubtree(node: *VNode, target_id: u64, dom_ancestor: ?u64) ?u64 {
    const dom_here: ?u64 = if (node.component == .element and node.component.element.tag != .fragment)
        node.id
    else
        dom_ancestor;

    if (node.id == target_id) return dom_here;

    for (node.children.items) |child| {
        const next_ancestor: ?u64 = if (node.component == .element and node.component.element.tag != .fragment)
            node.id
        else
            dom_ancestor;
        if (findDomParentInSubtree(child, target_id, next_ancestor)) |found| return found;
    }
    return null;
}

/// When inserting into a fragment vnode, DOM nodes must be placed before the
/// fragment's next sibling (e.g. conditional `{if ...}` before the following `<p>`).
fn findFragmentInsertReference(client: anytype, fragment_id: u64, insert_index: usize) ?u64 {
    var vtrees_iter = client.vtrees.iterator();
    while (vtrees_iter.next()) |entry| {
        if (findFragmentInsertReferenceInSubtree(entry.value_ptr.vtree, fragment_id, insert_index)) |id| return id;
    }
    return null;
}

fn findFragmentInsertReferenceInSubtree(parent: *VNode, fragment_id: u64, insert_index: usize) ?u64 {
    for (parent.children.items, 0..) |child, i| {
        if (child.id == fragment_id) {
            const start = @min(insert_index, child.children.items.len);
            if (vdom.firstDomNodeIdFrom(child.children.items[start..])) |id| return id;
            return vdom.firstDomNodeIdFrom(parent.children.items[i + 1 ..]);
        }
        if (findFragmentInsertReferenceInSubtree(child, fragment_id, insert_index)) |id| return id;
    }
    return null;
}

/// Find the DOM node to insert before when placing a child at `insert_index` in `parent_id`.
fn findChildInsertReference(client: anytype, parent_id: u64, insert_index: usize) ?u64 {
    const parent = client.getVElementById(parent_id) orelse return null;
    const start = @min(insert_index, parent.children.items.len);
    return vdom.firstDomNodeIdFrom(parent.children.items[start..]);
}
