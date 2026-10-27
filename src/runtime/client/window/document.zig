pub const Document = @This();

const std = @import("std");
const builtin = @import("builtin");

const zx = @import("../../../root.zig");
const bom = @import("../window.zig");
const js = zx.client.js;

pub const HTMLElement = struct {
    ref: js.Object,
    allocator: std.mem.Allocator,

    pub const Rect = struct {
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        top: f64,
        right: f64,
        bottom: f64,
        left: f64,
    };

    pub fn init(allocator: std.mem.Allocator, ref: js.Object) HTMLElement {
        return .{
            .ref = ref,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: HTMLElement) void {
        self.ref.deinit();
    }

    pub fn setInnerHTML(self: HTMLElement, html: []const u8) !void {
        try self.ref.set("innerHTML", js.string(html));
    }

    pub fn appendChild(self: HTMLElement, child: HTMLNode) !void {
        switch (child) {
            .element => |element| {
                _ = try self.ref.call(js.Object, "appendChild", .{element.ref});
            },
            .text => |text| {
                _ = try self.ref.call(js.Object, "appendChild", .{text.ref});
            },
        }
    }

    pub fn setAttribute(self: HTMLElement, name: []const u8, value: []const u8) void {
        self.ref.call(void, "setAttribute", .{ js.string(name), js.string(value) }) catch {};
    }

    pub fn removeAttribute(self: HTMLElement, name: []const u8) void {
        self.ref.call(void, "removeAttribute", .{js.string(name)}) catch {};
    }

    /// Set a JavaScript property directly on the DOM node (not an attribute)
    /// Used for internal references like __zx_ref
    pub fn setProperty(self: HTMLElement, name: []const u8, value: anytype) void {
        self.ref.set(name, value) catch {};
    }

    /// Get a JavaScript property from the DOM node
    pub fn getProperty(self: HTMLElement, comptime T: type, name: []const u8) !T {
        return try self.ref.get(T, name);
    }

    pub fn focus(self: HTMLElement) !void {
        try self.ref.call(void, "focus", .{});
    }

    pub fn getBoundingClientRect(self: HTMLElement) !Rect {
        const rect = try self.ref.call(js.Object, "getBoundingClientRect", .{});
        defer rect.deinit();
        return .{
            .x = try rect.get(f64, "x"),
            .y = try rect.get(f64, "y"),
            .width = try rect.get(f64, "width"),
            .height = try rect.get(f64, "height"),
            .top = try rect.get(f64, "top"),
            .right = try rect.get(f64, "right"),
            .bottom = try rect.get(f64, "bottom"),
            .left = try rect.get(f64, "left"),
        };
    }

    pub fn setPointerCapture(self: HTMLElement, pointer_id: i32) !void {
        try self.ref.call(void, "setPointerCapture", .{pointer_id});
    }

    pub fn releasePointerCapture(self: HTMLElement, pointer_id: i32) !void {
        try self.ref.call(void, "releasePointerCapture", .{pointer_id});
    }

    pub fn removeChild(self: HTMLElement, child: HTMLNode) !void {
        switch (child) {
            .element => |element| {
                _ = try self.ref.call(js.Object, "removeChild", .{element.ref});
            },
            .text => |text| {
                _ = try self.ref.call(js.Object, "removeChild", .{text.ref});
            },
        }
    }

    pub fn replaceChild(self: HTMLElement, new_child: HTMLNode, old_child: HTMLNode) !void {
        const new_ref = switch (new_child) {
            .element => |element| element.ref,
            .text => |text| text.ref,
        };
        const old_ref = switch (old_child) {
            .element => |element| element.ref,
            .text => |text| text.ref,
        };
        _ = try self.ref.call(js.Object, "replaceChild", .{ new_ref, old_ref });
    }

    pub fn insertBefore(self: HTMLElement, new_child: HTMLNode, reference_child: ?HTMLNode) !void {
        const new_ref = switch (new_child) {
            .element => |element| element.ref,
            .text => |text| text.ref,
        };
        if (reference_child) |ref_child| {
            const ref_ref = switch (ref_child) {
                .element => |element| element.ref,
                .text => |text| text.ref,
            };
            _ = try self.ref.call(js.Object, "insertBefore", .{ new_ref, ref_ref });
        } else {
            _ = try self.ref.call(js.Object, "insertBefore", .{ new_ref, null });
        }
    }
};

pub const HTMLText = struct {
    ref: js.Object,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ref: js.Object) HTMLText {
        return .{
            .ref = ref,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: HTMLText) void {
        self.ref.deinit();
    }

    pub fn setNodeValue(self: HTMLText, value: []const u8) void {
        self.ref.set("nodeValue", js.string(value)) catch {};
    }

    pub fn setProperty(self: HTMLText, name: []const u8, value: anytype) void {
        self.ref.set(name, value) catch {};
    }
};

pub const HTMLNode = union(enum) {
    element: HTMLElement,
    text: HTMLText,

    pub fn deinit(self: HTMLNode) void {
        switch (self) {
            .element => |element| element.deinit(),
            .text => |text| text.deinit(),
        }
    }
};

ref: js.Object,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Document {
    const ref: js.Object = js.global.get(js.Object, "document") catch @panic("Document not found");
    return .{
        .ref = ref,
        .allocator = allocator,
    };
}

pub fn deinit(self: Document) void {
    self.ref.deinit();
}

pub fn getElementById(self: Document, id: []const u8) error{ ElementNotFound, NotInBrowser }!HTMLElement {
    const ref: js.Object = self.ref.call(js.Object, "getElementById", .{js.string(id)}) catch {
        return error.ElementNotFound;
    };

    return HTMLElement.init(self.allocator, ref);
}

pub fn querySelector(self: Document, selector: []const u8) error{ ElementNotFound, NotInBrowser }!HTMLElement {
    const ref: js.Object = self.ref.call(js.Object, "querySelector", .{js.string(selector)}) catch {
        return error.ElementNotFound;
    };

    return HTMLElement.init(self.allocator, ref);
}

pub fn createElement(self: Document, tag: []const u8) HTMLElement {
    const ref: js.Object = self.ref.call(js.Object, "createElement", .{js.string(tag)}) catch @panic("Failed to create element");

    return HTMLElement.init(self.allocator, ref);
}

/// Create an element by tag enum id. vnode_id is registered in the JS domNodes
/// registry and used as the __zx_ref property value on the element.
pub fn createElementId(self: Document, id: usize, vnode_id: u64) void {
    _ = self;

    @import("../dom_cmd.zig").createElement(id, vnode_id);
}

pub fn createTextNode(self: Document, data: []const u8) HTMLText {
    const ref: js.Object = self.ref.call(js.Object, "createTextNode", .{js.string(data)}) catch @panic("Failed to create text");

    return HTMLText.init(self.allocator, ref);
}

/// Create DOM nodes from raw HTML string using template element.
/// Returns the first child element, or null if the HTML produced no elements.
pub fn createElementFromTemplate(self: Document, html: []const u8) ?HTMLElement {
    const template: js.Object = self.ref.call(js.Object, "createElement", .{js.string("template")}) catch return null;
    template.set("innerHTML", js.string(html)) catch return null;

    const content: js.Object = template.get(js.Object, "content") catch return null;
    const first_child: js.Object = content.get(js.Object, "firstElementChild") catch return null;

    return HTMLElement.init(self.allocator, first_child);
}

/// Create a DocumentFragment for batch DOM operations.
/// Elements can be appended to the fragment without causing reflows,
/// then the entire fragment is inserted in one operation.
pub fn createDocumentFragment(self: Document) HTMLElement {
    const ref: js.Object = self.ref.call(js.Object, "createDocumentFragment", .{}) catch @panic("Failed to create fragment");

    return HTMLElement.init(self.allocator, ref);
}

/// Represents a hydration boundary marked by comment nodes <!--$id--> or <!--$id {"props":"json"}--> and <!--/$id-->
pub const CommentMarker = struct {
    start_comment: js.Object,
    end_comment: js.Object,
    parent: js.Object,
    allocator: std.mem.Allocator,
    /// Props ZON extracted from the start comment (e.g., ".{ .name = ..., .props = ... }")
    props_zon: ?[]const u8,

    /// Insert a vnode (from JS `domNodes`) before the end comment.
    pub fn insertVNode(self: CommentMarker, vnode_id: u64) void {
        @import("../dom_cmd.zig").hydrateInsert(vnode_id, @intFromEnum(self.end_comment.value));
    }

    /// Clear SSR content between markers, then insert the vnode root.
    pub fn replaceContentById(self: CommentMarker, vnode_id: u64) void {
        self.clearContent();
        self.insertVNode(vnode_id);
    }

    /// Insert a new DOM node after the start comment (before existing content)
    pub fn insertContent(self: CommentMarker, node: HTMLNode) !void {
        const node_ref = switch (node) {
            .element => |el| el.ref,
            .text => |txt| txt.ref,
        };
        // insertBefore(newNode, referenceNode) - insert before end comment
        _ = try self.parent.call(js.Object, "insertBefore", .{ node_ref, self.end_comment });
    }

    /// Clear all content between start and end markers
    pub fn clearContent(self: CommentMarker) void {
        // Remove nodes between start and end comments
        while (true) {
            const next_sibling: js.Object = self.start_comment.get(js.Object, "nextSibling") catch break;
            // Check node type - comment nodes have nodeType === 8
            const node_type = next_sibling.get(i32, "nodeType") catch break;
            if (node_type == 8) {
                // It's a comment node - check if it's our end marker
                const text = next_sibling.getAlloc(js.String, self.allocator, "textContent") catch break;
                defer self.allocator.free(text);
                // End marker starts with '/'
                if (text.len > 0 and text[0] == '/') break;
            }
            _ = self.parent.call(js.Object, "removeChild", .{next_sibling}) catch break;
        }
    }

    /// Replace all content between markers with new node
    pub fn replaceContent(self: CommentMarker, node: HTMLNode) !void {
        self.clearContent();
        try self.insertContent(node);
    }
};

/// Find comment markers for the `occurrence`-th (0-based, document order) island with a component ID.
/// Start marker format: <!--$id [val1, val2]--> (positional array) or <!--$id {"prop":"value"}--> (JSON object) or <!--$id-->
/// End marker format: <!--/$id-->
pub fn findCommentMarker(self: Document, id: []const u8, occurrence: usize) error{ MarkerNotFound, NotInBrowser }!CommentMarker {
    const allocator = self.allocator;

    // Build the patterns we're looking for
    // Start marker: $id or $id {...}
    const start_prefix = std.fmt.allocPrint(allocator, "${s}", .{id}) catch return error.MarkerNotFound;
    defer allocator.free(start_prefix);
    // End marker: /$id
    const end_marker = std.fmt.allocPrint(allocator, "/${s}", .{id}) catch return error.MarkerNotFound;
    defer allocator.free(end_marker);

    // Use TreeWalker to find comment nodes
    const body: js.Object = self.ref.get(js.Object, "body") catch return error.MarkerNotFound;
    const node_filter_show_comment: i32 = 128; // NodeFilter.SHOW_COMMENT
    const walker: js.Object = self.ref.call(js.Object, "createTreeWalker", .{ body, node_filter_show_comment }) catch return error.MarkerNotFound;

    var start_comment: ?js.Object = null;
    var end_comment: ?js.Object = null;
    var props_zon: ?[]const u8 = null;
    // Islands sharing an id never nest, so the n-th start pairs with the n-th end.
    var starts_seen: usize = 0;
    var ends_seen: usize = 0;

    // Iterate through all comment nodes
    while (true) {
        const node: js.Object = walker.call(js.Object, "nextNode", .{}) catch break;

        // Get comment text content
        const text = node.getAlloc(js.String, allocator, "textContent") catch continue;

        // Check for start marker: $id or $id {...} or $id [...]
        const is_start = std.mem.startsWith(u8, text, start_prefix) and
            (text.len == start_prefix.len or text[start_prefix.len] == ' ');
        if (is_start and starts_seen < occurrence) {
            starts_seen += 1;
            allocator.free(text);
        } else if (is_start and start_comment == null) {
            start_comment = node;
            // Extract JSON payload after $id (if present)
            // Format: $id {"prop":"value"} or $id [val1, val2] -> extract JSON
            const rest = text[start_prefix.len..];
            if (rest.len > 0 and rest[0] == ' ') {
                // Skip the space and get JSON (object or array format)
                const json_obj_start = std.mem.indexOf(u8, rest, "{");
                const json_arr_start = std.mem.indexOf(u8, rest, "[");
                // Find the first occurrence of either { or [
                const json_start = if (json_obj_start != null and json_arr_start != null)
                    @min(json_obj_start.?, json_arr_start.?)
                else if (json_obj_start) |idx|
                    idx
                else
                    json_arr_start;
                if (json_start) |idx| {
                    props_zon = allocator.dupe(u8, rest[idx..]) catch null;
                }
            }
            allocator.free(text);
        } else if (std.mem.eql(u8, text, end_marker) and ends_seen < occurrence) {
            ends_seen += 1;
            allocator.free(text);
        } else if (std.mem.eql(u8, text, end_marker) and start_comment != null) {
            allocator.free(text);
            end_comment = node;
            break; // Found both, stop searching
        } else {
            allocator.free(text);
        }
    }

    if (start_comment) |start| {
        if (end_comment) |end| {
            const parent: js.Object = start.get(js.Object, "parentNode") catch return error.MarkerNotFound;
            return CommentMarker{
                .start_comment = start,
                .end_comment = end,
                .parent = parent,
                .allocator = allocator,
                .props_zon = props_zon,
            };
        }
    }

    return error.MarkerNotFound;
}
