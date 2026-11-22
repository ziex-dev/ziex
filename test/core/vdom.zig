const std = @import("std");
const zx = @import("zx");

const testing = std.testing;
const VDOMTree = zx.util.vdom.VDOMTree;
const VNode = zx.util.vdom.VNode;
const Patch = zx.util.vdom.Patch;

test "same" {
    const allocator = testing.allocator;

    const comp1 = zx.Component{ .element = .{ .tag = .div } };
    const comp2 = zx.Component{ .element = .{ .tag = .div } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), patches.items.len);
}

test "replace tag" {
    const allocator = testing.allocator;

    const child1 = zx.Component{ .element = .{ .tag = .div } };
    const comp1 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child1} } };

    const child2 = zx.Component{ .element = .{ .tag = .span } };
    const comp2 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child2} } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.REPLACE, patches.items[0].type);

    if (patches.items.len > 0) {
        patches.items[0].data.REPLACE.new_vnode.deinit(allocator);
    }
}

test "root replace" {
    const allocator = testing.allocator;

    const comp1 = zx.Component{ .element = .{ .tag = .div } };
    const comp2 = zx.Component{ .element = .{ .tag = .span } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    // Parent is null for root, so no REPLACE patch is appended.
    try testing.expectEqual(@as(usize, 0), patches.items.len);
}

test "text update" {
    const allocator = testing.allocator;

    const child1 = zx.Component{ .text = "Hello" };
    const comp1 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child1} } };

    const child2 = zx.Component{ .text = "World" };
    const comp2 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child2} } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.TEXT, patches.items[0].type);
    try testing.expectEqualStrings("World", patches.items[0].data.TEXT.new_text);
}

test "attributes update" {
    const allocator = testing.allocator;

    const attr1 = zx.Element.Attribute{ .name = "id", .value = "app" };
    const comp1 = zx.Component{ .element = .{ .tag = .div, .attributes = &[_]zx.Element.Attribute{attr1} } };

    const attr2_1 = zx.Element.Attribute{ .name = "id", .value = "app2" };
    const attr2_2 = zx.Element.Attribute{ .name = "class", .value = "container" };
    const comp2 = zx.Component{ .element = .{ .tag = .div, .attributes = &[_]zx.Element.Attribute{ attr2_1, attr2_2 } } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.UPDATE, patches.items[0].type);

    var update_data = patches.items[0].data.UPDATE;
    defer {
        update_data.attributes.deinit();
        update_data.removed_attributes.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 2), update_data.attributes.count());
    try testing.expectEqualStrings("app2", update_data.attributes.get("id").?);
    try testing.expectEqualStrings("container", update_data.attributes.get("class").?);
}

test "remove attr" {
    const allocator = testing.allocator;

    const attr1 = zx.Element.Attribute{ .name = "class", .value = "btn" };
    const comp1 = zx.Component{ .element = .{ .tag = .div, .attributes = &[_]zx.Element.Attribute{attr1} } };

    const comp2 = zx.Component{ .element = .{ .tag = .div, .attributes = null } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.UPDATE, patches.items[0].type);

    var update_data = patches.items[0].data.UPDATE;
    defer {
        update_data.attributes.deinit();
        update_data.removed_attributes.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 0), update_data.attributes.count());
    try testing.expectEqual(@as(usize, 1), update_data.removed_attributes.items.len);
    try testing.expectEqualStrings("class", update_data.removed_attributes.items[0]);
}

test "placement" {
    const allocator = testing.allocator;

    const comp1 = zx.Component{ .element = .{ .tag = .div, .children = null } };

    const child2 = zx.Component{ .element = .{ .tag = .span } };
    const comp2 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child2} } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.PLACEMENT, patches.items[0].type);

    if (patches.items.len > 0) {
        patches.items[0].data.PLACEMENT.vnode.deinit(allocator);
    }
}

test "deletion" {
    const allocator = testing.allocator;

    const child1 = zx.Component{ .element = .{ .tag = .span } };
    const comp1 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child1} } };

    const comp2 = zx.Component{ .element = .{ .tag = .div, .children = null } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.DELETION, patches.items[0].type);
}

test "conditional fragment preserves sibling vnodes" {
    const allocator = testing.allocator;

    const empty_frag = zx.Component{ .element = .{ .tag = .fragment, .children = null } };
    const welcome_p = zx.Component{ .element = .{ .tag = .p, .children = &[_]zx.Component{.{ .text = "Welcome" }} } };
    const msg_p = zx.Component{ .element = .{ .tag = .p, .children = &[_]zx.Component{.{ .text = "msg" }} } };
    const input_name = zx.Component{ .element = .{ .tag = .input, .attributes = &[_]zx.Element.Attribute{.{ .name = "name", .value = "name" }} } };
    const input_id = zx.Component{ .element = .{ .tag = .input, .attributes = &[_]zx.Element.Attribute{.{ .name = "name", .value = "id" }} } };

    const comp1 = zx.Component{ .element = .{ .tag = .form, .children = &[_]zx.Component{ empty_frag, msg_p, input_name, input_id } } };

    const cond_frag = zx.Component{ .element = .{ .tag = .fragment, .children = &[_]zx.Component{welcome_p} } };
    const comp2 = zx.Component{ .element = .{ .tag = .form, .children = &[_]zx.Component{ cond_frag, msg_p, input_name, input_id } } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    const input_name_id = tree.vtree.children.items[2].id;
    const input_id_id = tree.vtree.children.items[3].id;

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer {
        for (patches.items) |patch| {
            if (patch.type == .REPLACE) {
                patch.data.REPLACE.new_vnode.deinit(allocator);
            }
            if (patch.type == .PLACEMENT) {
                patch.data.PLACEMENT.vnode.deinit(allocator);
            }
        }
        patches.deinit(allocator);
    }

    // Sibling inputs must not be replaced when a conditional fragment gains content.
    for (patches.items) |patch| {
        if (patch.type == .REPLACE) {
            try testing.expect(patch.data.REPLACE.old_vnode_id != input_name_id);
            try testing.expect(patch.data.REPLACE.old_vnode_id != input_id_id);
        }
    }

    try testing.expectEqual(input_name_id, tree.vtree.children.items[2].id);
    try testing.expectEqual(input_id_id, tree.vtree.children.items[3].id);
}

test "for-loop fragment deletes all keyed children" {
    const allocator = testing.allocator;

    const item1 = zx.Component{ .element = .{ .tag = .li, .attributes = &[_]zx.Element.Attribute{.{ .name = "key", .value = "1" }}, .children = &[_]zx.Component{.{ .text = "a" }} } };
    const item2 = zx.Component{ .element = .{ .tag = .li, .attributes = &[_]zx.Element.Attribute{.{ .name = "key", .value = "2" }}, .children = &[_]zx.Component{.{ .text = "b" }} } };
    const item3 = zx.Component{ .element = .{ .tag = .li, .attributes = &[_]zx.Element.Attribute{.{ .name = "key", .value = "3" }}, .children = &[_]zx.Component{.{ .text = "c" }} } };

    const list_frag = zx.Component{ .element = .{ .tag = .fragment, .children = &[_]zx.Component{ item1, item2, item3 } } };
    const empty_frag = zx.Component{ .element = .{ .tag = .fragment, .children = null } };

    const comp1 = zx.Component{ .element = .{ .tag = .ul, .children = &[_]zx.Component{list_frag} } };
    const comp2 = zx.Component{ .element = .{ .tag = .ul, .children = &[_]zx.Component{empty_frag} } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    var deletions: usize = 0;
    for (patches.items) |patch| {
        if (patch.type == .DELETION) deletions += 1;
    }
    try testing.expectEqual(@as(usize, 3), deletions);
}

test "conditional fragment placement into empty slot" {
    const allocator = testing.allocator;

    const empty_frag = zx.Component{ .element = .{ .tag = .fragment, .children = null } };
    const welcome_p = zx.Component{ .element = .{ .tag = .p, .children = &[_]zx.Component{.{ .text = "Welcome" }} } };
    const msg_p = zx.Component{ .element = .{ .tag = .p, .children = &[_]zx.Component{.{ .text = "msg" }} } };

    const comp1 = zx.Component{ .element = .{ .tag = .form, .children = &[_]zx.Component{ empty_frag, msg_p } } };

    const cond_frag = zx.Component{ .element = .{ .tag = .fragment, .children = &[_]zx.Component{welcome_p} } };
    const comp2 = zx.Component{ .element = .{ .tag = .form, .children = &[_]zx.Component{ cond_frag, msg_p } } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    const fragment_id = tree.vtree.children.items[0].id;

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer {
        for (patches.items) |patch| {
            if (patch.type == .PLACEMENT) patch.data.PLACEMENT.vnode.deinit(allocator);
        }
        patches.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.PLACEMENT, patches.items[0].type);
    try testing.expectEqual(fragment_id, patches.items[0].data.PLACEMENT.parent_id);
    try testing.expectEqual(@as(usize, 0), patches.items[0].data.PLACEMENT.index);
}

test "if-without-else fragment to element uses placement not replace" {
    const allocator = testing.allocator;

    const empty_frag = zx.Component{ .element = .{ .tag = .fragment, .children = null } };
    const welcome_p = zx.Component{ .element = .{ .tag = .p, .children = &[_]zx.Component{
        .{ .text = "Welcome back, " },
        .{ .text = "Alice" },
        .{ .text = "!" },
    } } };
    const msg_p = zx.Component{ .element = .{ .tag = .p, .children = &[_]zx.Component{.{ .text = "Please log in." }} } };
    const input_name = zx.Component{ .element = .{ .tag = .input, .attributes = &[_]zx.Element.Attribute{.{ .name = "name", .value = "name" }} } };

    const comp1 = zx.Component{ .element = .{ .tag = .form, .children = &[_]zx.Component{ empty_frag, msg_p, input_name } } };
    const comp2 = zx.Component{ .element = .{ .tag = .form, .children = &[_]zx.Component{ welcome_p, msg_p, input_name } } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    const fragment_id = tree.vtree.children.items[0].id;
    const msg_p_id = tree.vtree.children.items[1].id;

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer {
        for (patches.items) |patch| {
            switch (patch.type) {
                .PLACEMENT => patch.data.PLACEMENT.vnode.deinit(allocator),
                .REPLACE => patch.data.REPLACE.new_vnode.deinit(allocator),
                else => {},
            }
        }
        patches.deinit(allocator);
    }

    for (patches.items) |patch| {
        try testing.expect(patch.type != .REPLACE);
    }

    var saw_deletion = false;
    var saw_placement = false;
    for (patches.items) |patch| {
        if (patch.type == .DELETION and patch.data.DELETION.vnode_id == fragment_id) saw_deletion = true;
        if (patch.type == .PLACEMENT and patch.data.PLACEMENT.index == 0) saw_placement = true;
    }
    try testing.expect(saw_deletion);
    try testing.expect(saw_placement);
    try testing.expectEqual(msg_p_id, tree.vtree.children.items[1].id);
}

test "keyed list prepend places new item without index-shifting reuse" {
    const allocator = testing.allocator;

    const a = zx.Component{ .element = .{ .tag = .li, .attributes = &[_]zx.Element.Attribute{.{ .name = "key", .value = "a" }}, .children = &[_]zx.Component{.{ .text = "A" }} } };
    const b = zx.Component{ .element = .{ .tag = .li, .attributes = &[_]zx.Element.Attribute{.{ .name = "key", .value = "b" }}, .children = &[_]zx.Component{.{ .text = "B" }} } };
    const d = zx.Component{ .element = .{ .tag = .li, .attributes = &[_]zx.Element.Attribute{.{ .name = "key", .value = "d" }}, .children = &[_]zx.Component{.{ .text = "D" }} } };

    const list1 = zx.Component{ .element = .{ .tag = .ul, .children = &[_]zx.Component{ a, b } } };
    const list2 = zx.Component{ .element = .{ .tag = .ul, .children = &[_]zx.Component{ d, a, b } } };

    var tree = VDOMTree.init(allocator, list1);
    defer tree.deinit(allocator);

    const a_id = tree.vtree.children.items[0].id;
    const b_id = tree.vtree.children.items[1].id;

    var patches = try tree.diffWithComponent(allocator, list2);
    defer {
        for (patches.items) |patch| {
            if (patch.type == .PLACEMENT) patch.data.PLACEMENT.vnode.deinit(allocator);
        }
        patches.deinit(allocator);
    }

    var placements: usize = 0;
    var placed_key: ?[]const u8 = null;
    for (patches.items) |patch| {
        try testing.expect(patch.type != .REPLACE);
        try testing.expect(patch.type != .DELETION);
        if (patch.type == .PLACEMENT) {
            placements += 1;
            placed_key = patch.data.PLACEMENT.vnode.key;
            try testing.expectEqual(@as(usize, 0), patch.data.PLACEMENT.index);
        }
    }
    try testing.expectEqual(@as(usize, 1), placements);
    try testing.expectEqualStrings("d", placed_key.?);
    // Existing keyed nodes keep their DOM identity; patches only place `d`.
    try testing.expectEqual(a_id, tree.vtree.children.items[0].id);
    try testing.expectEqual(b_id, tree.vtree.children.items[1].id);
}

test "keyed component_fn children preserve keys through resolve" {
    const allocator = testing.allocator;

    const Row = struct {
        fn call(_: ?*const anyopaque, _: std.mem.Allocator, _: ?[]const u8, _: ?*zx.Component.ComponentFn.Section) anyerror!zx.Component {
            return .{ .element = .{ .tag = .tr, .children = &[_]zx.Component{.{ .text = "row" }} } };
        }
        fn destroy(_: ?*const anyopaque, _: std.mem.Allocator) void {}
        const vtable: zx.Component.ComponentFn.VTable = .{ .call = call, .destroy = destroy };
    };

    const row_a = zx.Component{ .component_fn = .{
        .vtable = &Row.vtable,
        .data = null,
        .allocator = allocator,
        .name = "Row",
        .key = "a",
        .id = .undef,
    } };
    const row_b = zx.Component{ .component_fn = .{
        .vtable = &Row.vtable,
        .data = null,
        .allocator = allocator,
        .name = "Row",
        .key = "b",
        .id = .undef,
    } };
    const row_d = zx.Component{ .component_fn = .{
        .vtable = &Row.vtable,
        .data = null,
        .allocator = allocator,
        .name = "Row",
        .key = "d",
        .id = .undef,
    } };

    const tbody1 = zx.Component{ .element = .{ .tag = .tbody, .children = &[_]zx.Component{ row_a, row_b } } };
    const tbody2 = zx.Component{ .element = .{ .tag = .tbody, .children = &[_]zx.Component{ row_d, row_a, row_b } } };

    var tree = VDOMTree.init(allocator, tbody1);
    defer tree.deinit(allocator);

    try testing.expectEqualStrings("a", tree.vtree.children.items[0].key.?);
    try testing.expectEqualStrings("b", tree.vtree.children.items[1].key.?);
    const a_id = tree.vtree.children.items[0].id;
    const b_id = tree.vtree.children.items[1].id;

    var patches = try tree.diffWithComponent(allocator, tbody2);
    defer {
        for (patches.items) |patch| {
            if (patch.type == .PLACEMENT) patch.data.PLACEMENT.vnode.deinit(allocator);
        }
        patches.deinit(allocator);
    }

    var placements: usize = 0;
    for (patches.items) |patch| {
        try testing.expect(patch.type != .REPLACE);
        try testing.expect(patch.type != .DELETION);
        if (patch.type == .PLACEMENT) {
            placements += 1;
            try testing.expectEqualStrings("d", patch.data.PLACEMENT.vnode.key.?);
            try testing.expectEqual(@as(usize, 0), patch.data.PLACEMENT.index);
        }
    }
    try testing.expectEqual(@as(usize, 1), placements);
    // Reused component rows keep the same vnode ids (handlers stay on the right rows).
    try testing.expectEqual(a_id, tree.vtree.children.items[0].id);
    try testing.expectEqual(b_id, tree.vtree.children.items[1].id);
}

test "if before for list resolves insert reference to first list item" {
    const allocator = testing.allocator;

    const title = zx.Component{ .element = .{ .tag = .h2, .children = &[_]zx.Component{.{ .text = "Title" }} } };
    const empty_frag = zx.Component{ .element = .{ .tag = .fragment, .children = null } };
    const new_p = zx.Component{ .element = .{ .tag = .p, .children = &[_]zx.Component{.{ .text = "New" }} } };
    const list = zx.Component{ .element = .{ .tag = .fragment, .children = &[_]zx.Component{
        .{ .element = .{ .tag = .p, .children = &[_]zx.Component{.{ .text = "B" }} } },
        .{ .element = .{ .tag = .p, .children = &[_]zx.Component{.{ .text = "A" }} } },
    } } };

    const before = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{ title, empty_frag, list } } };
    const after = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{ title, new_p, list } } };

    var tree = VDOMTree.init(allocator, before);
    defer tree.deinit(allocator);

    const fragment_id = tree.vtree.children.items[1].id;
    const first_item_id = tree.vtree.children.items[2].children.items[0].id;

    var patches = try tree.diffWithComponent(allocator, after);
    defer {
        for (patches.items) |patch| {
            if (patch.type == .PLACEMENT) patch.data.PLACEMENT.vnode.deinit(allocator);
        }
        patches.deinit(allocator);
    }

    var placement_index: ?usize = null;
    var saw_deletion = false;
    for (patches.items) |patch| {
        if (patch.type == .DELETION and patch.data.DELETION.vnode_id == fragment_id) saw_deletion = true;
        if (patch.type == .PLACEMENT) placement_index = patch.data.PLACEMENT.index;
    }
    try testing.expect(saw_deletion);
    try testing.expectEqual(@as(?usize, 1), placement_index);

    // The client applies DELETION first, leaving [title, list]. The node placed at
    // index 1 must go before the list's first item, not be appended at the end.
    const remaining = [_]*VNode{ tree.vtree.children.items[0], tree.vtree.children.items[2] };
    try testing.expectEqual(@as(?u64, first_item_id), zx.util.vdom.firstDomNodeIdFrom(remaining[placement_index.?..]));
}

test "first dom node skips empty fragments" {
    const allocator = testing.allocator;

    const empty_frag = zx.Component{ .element = .{ .tag = .fragment, .children = null } };
    const button = zx.Component{ .element = .{ .tag = .button, .children = &[_]zx.Component{.{ .text = "Add" }} } };
    const root = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{ empty_frag, empty_frag, button } } };

    var tree = VDOMTree.init(allocator, root);
    defer tree.deinit(allocator);

    const children = tree.vtree.children.items;
    try testing.expectEqual(@as(?u64, children[2].id), zx.util.vdom.firstDomNodeIdFrom(children));
    try testing.expectEqual(@as(?u64, null), zx.util.vdom.firstDomNodeIdFrom(children[0..2]));
    try testing.expectEqual(@as(?u64, null), zx.util.vdom.firstDomNodeIdFrom(children[3..]));
}

test "first dom node descends into nested fragments" {
    const allocator = testing.allocator;

    const nested = zx.Component{ .element = .{ .tag = .fragment, .children = &[_]zx.Component{
        .{ .element = .{ .tag = .fragment, .children = null } },
        .{ .element = .{ .tag = .fragment, .children = &[_]zx.Component{.{ .text = "deep" }} } },
    } } };
    const root = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{nested} } };

    var tree = VDOMTree.init(allocator, root);
    defer tree.deinit(allocator);

    const outer = tree.vtree.children.items[0];
    const text_id = outer.children.items[1].children.items[0].id;
    try testing.expectEqual(@as(?u64, text_id), zx.util.vdom.firstDomNodeId(outer));
}
