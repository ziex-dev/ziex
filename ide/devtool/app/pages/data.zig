const zx = @import("zx");
const std = @import("std");

pub const ComponentMeta = struct {
    prop_items: []const StateItem = &[_]StateItem{},
    signal_items: []const StateItem = &[_]StateItem{},
    action_items: []const StateItem = &[_]StateItem{},
};

pub const Component = struct {
    id: []const u8 = "",
    name: []const u8,
    has_children: bool,
    children: []const Component,
    selected: bool = false,
    badges: []const []const u8 = &[_][]const u8{},
    meta: ?ComponentMeta = null,
    is_native: bool = false,
    selector: []const u8 = "",
    occurrence: usize = 0,
    source: []const u8 = "",
    line: u32 = 0,
};

pub const StateItem = zx.util.devtool.ComponentSerializable.StateItem;

const storage_key = "zx-devtool-show-native-elements";
const tree_collapsed_key = "zx-devtool-tree-collapsed";
const include_props_key = "zx-devtool-include-props";
const include_attributes_key = "zx-devtool-include-attributes";
pub const host_storage_key = "zx-devtool-host-v2";
pub const path_storage_key = "zx-devtool-path-v1";
const theme_storage_key = "zx-devtool-theme-dark";

var _show_native_elements_loaded = false;
pub var show_native_elements: bool = true;
pub var include_props: bool = true;
pub var include_attributes: bool = true;
pub var tree_collapsed: bool = false;
pub var host: []const u8 = "localhost:3000";
pub var current_path: []const u8 = "/";
var host_owned: ?[]const u8 = null;

const js = zx.client.js;

fn lsSet(key: []const u8, value: []const u8) void {
    if (zx.platform.role != .client) return;
    const ls = js.global.get(js.Object, "localStorage") catch return;
    defer ls.deinit();
    ls.call(void, "setItem", .{ js.string(key), js.string(value) }) catch {};
}

fn lsGet(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    if (zx.platform.role != .client) return null;
    const ls = js.global.get(js.Object, "localStorage") catch return null;
    defer ls.deinit();
    return ls.callAlloc(js.String, allocator, "getItem", .{js.string(key)}) catch null;
}

fn lsGetBool(key: []const u8, default_val: bool) bool {
    const v = lsGet(zx.allocator, key) orelse return default_val;
    defer zx.allocator.free(v);
    return std.mem.eql(u8, v, "1");
}

pub fn adopt(owned: *?[]const u8, slot: *[]const u8, new: ?[]const u8, fallback: []const u8) void {
    if (owned.*) |old| zx.allocator.free(old);
    if (new) |n| {
        owned.* = n;
        slot.* = n;
    } else {
        owned.* = null;
        slot.* = fallback;
    }
}

pub fn setHost(new: []const u8) void {
    adopt(&host_owned, &host, new, host);
    saveSettings();
}

var path_owned: ?[]const u8 = null;

pub fn setPath(new: []const u8) void {
    adopt(&path_owned, &current_path, new, "/");
    lsSet(path_storage_key, current_path);
}

pub fn loadSettings() bool {
    if (_show_native_elements_loaded) return true;
    show_native_elements = lsGetBool(storage_key, true);
    include_props = lsGetBool(include_props_key, true);
    include_attributes = lsGetBool(include_attributes_key, true);
    tree_collapsed = lsGetBool(tree_collapsed_key, false);
    if (lsGet(zx.allocator, host_storage_key)) |loaded| {
        host = loaded;
        host_owned = loaded;
    }
    if (lsGet(zx.allocator, path_storage_key)) |loaded| {
        current_path = loaded;
        path_owned = loaded;
    }
    _show_native_elements_loaded = true;
    return _show_native_elements_loaded;
}

pub fn saveSettings() void {
    lsSet(storage_key, if (show_native_elements) "1" else "0");
    lsSet(include_props_key, if (include_props) "1" else "0");
    lsSet(include_attributes_key, if (include_attributes) "1" else "0");
    lsSet(tree_collapsed_key, if (tree_collapsed) "1" else "0");
    lsSet(host_storage_key, host);
}

pub fn loadThemeIsDark() bool {
    return lsGetBool(theme_storage_key, true);
}

pub fn saveThemeIsDark(dark: bool) void {
    lsSet(theme_storage_key, if (dark) "1" else "0");
}

pub const SelectorCounters = std.StringHashMap(usize);

fn buildSelector(allocator: std.mem.Allocator, tag: zx.ElementTag, attributes: anytype) []const u8 {
    const tag_name = @tagName(tag);
    if (attributes) |attrs| {
        for (attrs) |a| {
            if (std.mem.eql(u8, a.name, "id")) {
                if (a.value) |v| if (v.len > 0)
                    return allocator.print("{s}[id=\"{s}\"]", .{ tag_name, v }) catch tag_name;
            }
        }
        for (attrs) |a| {
            if (std.mem.eql(u8, a.name, "class")) {
                if (a.value) |v| if (v.len > 0)
                    return allocator.print("{s}[class=\"{s}\"]", .{ tag_name, v }) catch tag_name;
            }
        }
    }
    return allocator.dupe(u8, tag_name) catch tag_name;
}

fn nextOccurrence(counters: *SelectorCounters, selector: []const u8) usize {
    const gop = counters.getOrPut(selector) catch return 0;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    const occ = gop.value_ptr.*;
    gop.value_ptr.* = occ + 1;
    return occ;
}

pub fn fromSerializable(allocator: std.mem.Allocator, s: zx.util.devtool.ComponentSerializable, path: []const u8, counters: *SelectorCounters) anyerror!Component {
    var name: []const u8 = "unknown";
    var is_native: bool = true;
    var badges_list = std.ArrayList([]const u8).empty;
    errdefer badges_list.deinit(allocator);

    if (s.component) |c| {
        name = c;
        is_native = false;
    } else if (s.tag) |t| {
        name = @tagName(t);
    } else if (s.text) |t| {
        name = "text";
        const quoted = try quoteJsonString(allocator, t);
        return Component{
            .id = path,
            .name = name,
            .children = &.{},
            .has_children = false,
            .badges = try allocator.dupe([]const u8, &[_][]const u8{"text"}),
            .meta = ComponentMeta{
                .prop_items = try allocator.dupe(StateItem, &[_]StateItem{.{
                    .key = "children",
                    .value = quoted,
                }}),
            },
            .is_native = true,
        };
    }

    if (s.builtins) |builtins| {
        for (builtins) |b| {
            // Prefer short "client" badge for islands; other builtins as name=value.
            if (std.mem.eql(u8, b.name, "rendering") and std.mem.eql(u8, b.value, "client")) {
                try badges_list.append(allocator, try allocator.dupe(u8, "client"));
            } else {
                try badges_list.append(allocator, try allocator.print("{s}={s}", .{ b.name, b.value }));
            }
        }
    } else if (s.client) {
        try badges_list.append(allocator, try allocator.dupe(u8, "client"));
    }

    var selector: []const u8 = "";
    var occurrence: usize = 0;
    if (s.tag) |t| {
        selector = buildSelector(allocator, t, s.attributes);
        occurrence = nextOccurrence(counters, selector);
    }

    var tree_children = std.ArrayList(Component).empty;
    var text_parts = std.ArrayList(u8).empty;
    defer text_parts.deinit(allocator);

    if (s.children) |sc| {
        var child_idx: usize = 0;
        for (sc) |child_s| {
            if (child_s.text) |t| {
                try text_parts.appendSlice(allocator, t);
                continue;
            }
            // Skip empty `.none` placeholders (optional components that returned null).
            if (child_s.tag == null and child_s.component == null and child_s.text == null and
                (child_s.children == null or child_s.children.?.len == 0))
            {
                continue;
            }
            const child_path = try allocator.print("{s}.{d}", .{ path, child_idx });
            child_idx += 1;
            try tree_children.append(allocator, try fromSerializable(allocator, child_s, child_path, counters));
        }
    }
    const children = try tree_children.toOwnedSlice(allocator);

    if (s.tag == null) {
        for (children) |child| {
            if (child.selector.len > 0) {
                selector = child.selector;
                occurrence = child.occurrence;
                break;
            }
        }
    }

    var props_list = std.ArrayList(StateItem).empty;
    var signals_list = std.ArrayList(StateItem).empty;
    var actions_list = std.ArrayList(StateItem).empty;

    if (s.builtins) |builtins| {
        for (builtins) |b| {
            const prop_value = if (std.mem.eql(u8, b.name, "escaping") or
                std.mem.eql(u8, b.name, "rendering") or
                std.mem.eql(u8, b.name, "async"))
                try allocator.print(".{s}", .{b.value})
            else
                try allocator.dupe(u8, b.value);
            try props_list.append(allocator, .{
                .key = try allocator.print("@{s}", .{b.name}),
                .value = prop_value,
            });
        }
    }

    if (s.attributes) |attrs| {
        for (attrs) |attr| {
            const value = if (attr.value) |v|
                try quoteJsonString(allocator, v)
            else
                "true";
            try props_list.append(allocator, .{
                .key = attr.name,
                .value = value,
            });
        }
    }

    if (s.props) |p| {
        for (p) |item| {
            if (std.mem.eql(u8, item.meta, "(Ref)") or std.mem.eql(u8, item.meta, "(Computed)")) {
                try signals_list.append(allocator, item);
            } else if (std.mem.eql(u8, item.value, "fn()")) {
                try actions_list.append(allocator, item);
            } else {
                try props_list.append(allocator, item);
            }
        }
    }

    if (s.actions) |acts| {
        for (acts) |item| {
            try actions_list.append(allocator, item);
        }
    }

    if (text_parts.items.len > 0) {
        try props_list.append(allocator, .{
            .key = "children",
            .value = try quoteJsonString(allocator, text_parts.items),
        });
    }

    const meta: ?ComponentMeta = if (props_list.items.len > 0 or signals_list.items.len > 0 or actions_list.items.len > 0)
        ComponentMeta{
            .prop_items = try props_list.toOwnedSlice(allocator),
            .signal_items = try signals_list.toOwnedSlice(allocator),
            .action_items = try actions_list.toOwnedSlice(allocator),
        }
    else
        null;

    return Component{
        .id = path,
        .name = name,
        .children = children,
        .has_children = children.len > 0,
        .badges = try badges_list.toOwnedSlice(allocator),
        .meta = meta,
        .is_native = is_native,
        .selector = selector,
        .occurrence = occurrence,
        .source = s.source orelse "",
        .line = s.line,
    };
}

fn quoteJsonString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn fromSerializableSlice(allocator: std.mem.Allocator, sc: []const zx.util.devtool.ComponentSerializable) anyerror![]const Component {
    var counters = SelectorCounters.init(allocator);
    defer counters.deinit();

    var children = try allocator.alloc(Component, sc.len);
    for (sc, 0..) |child_s, i| {
        const path = try allocator.print("{d}", .{i});
        children[i] = try fromSerializable(allocator, child_s, path, &counters);
    }
    return children;
}

pub fn fromSerializableRoot(allocator: std.mem.Allocator, root: zx.util.devtool.ComponentSerializable) anyerror![]const Component {
    var counters = SelectorCounters.init(allocator);
    defer counters.deinit();
    const mapped = try fromSerializable(allocator, root, "0", &counters);
    const slice = try allocator.alloc(Component, 1);
    slice[0] = mapped;
    return slice;
}
