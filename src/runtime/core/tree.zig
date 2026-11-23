const std = @import("std");
const zx = @import("../../root.zig");
const Component = zx.Component;
const ElementTag = zx.ElementTag;

/// Recursively search for an element by tag name.
/// Resolves component_fn lazily during search.
pub fn getElementByName(self: *Component, allocator: std.mem.Allocator, io: std.Io, tag: ElementTag) ?*Component {
    switch (self.*) {
        .element => |*elem| {
            if (elem.tag == tag) return self;
            if (elem.children) |children| {
                const mutable_children = allocator.alloc(Component, children.len) catch return null;
                @memcpy(mutable_children, children);
                elem.children = mutable_children;
                for (0..mutable_children.len) |i| {
                    if (getElementByName(&mutable_children[i], allocator, io, tag)) |found| return found;
                }
            }
            return null;
        },
        .component_fn => |*func| {
            if (func.isIsland()) return null;
            const resolved = func.callIn(null, io) catch return null;
            self.* = resolved;
            return getElementByName(self, allocator, io, tag);
        },
        .none, .text => return null,
    }
}

pub fn appendChild(self: *Component, allocator: std.mem.Allocator, child: Component) !void {
    switch (self.*) {
        .element => |*elem| {
            if (elem.children) |existing| {
                const new_children = try allocator.alloc(Component, existing.len + 1);
                @memcpy(new_children[0..existing.len], existing);
                new_children[existing.len] = child;
                elem.children = new_children;
            } else {
                const new_children = try allocator.alloc(Component, 1);
                new_children[0] = child;
                elem.children = new_children;
            }
        },
        else => return error.NotAnElement,
    }
}

pub fn prependChild(self: *Component, allocator: std.mem.Allocator, child: Component) !void {
    switch (self.*) {
        .element => |*elem| {
            if (elem.children) |existing| {
                const new_children = try allocator.alloc(Component, existing.len + 1);
                new_children[0] = child;
                @memcpy(new_children[1..], existing);
                elem.children = new_children;
            } else {
                const new_children = try allocator.alloc(Component, 1);
                new_children[0] = child;
                elem.children = new_children;
            }
        },
        else => return error.NotAnElement,
    }
}
