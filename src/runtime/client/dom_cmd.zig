const std = @import("std");
const ext = @import("window/extern.zig");
const window = @import("window.zig");

pub const is_wasm = window.is_wasm;

/// Wire opcodes -> `pkg/ziex/src/wasm/dom_cmd.ts`.
pub const DomOp = enum(u8) {
    create_element = 1,
    create_text = 2,
    hydrate_insert = 3,
    set_attr = 4,
    set_prop = 5,
    remove_attr = 6,
    set_node_value = 7,
    set_inner_html = 8,
    append_child = 9,
    insert_before = 10,
    remove_child = 11,
    replace_child = 12,
};

pub const HEADER_SIZE: usize = 8;
pub const RECORD_SIZE: usize = 24;

threadlocal var active_buf: ?*DomCmdBuffer = null;

/// Activate `buf` as the current encoder; returns the previous buffer (if any).
pub fn activate(buf: *DomCmdBuffer) ?*DomCmdBuffer {
    const prev = active_buf;
    active_buf = buf;
    return prev;
}

pub fn deactivate(prev: ?*DomCmdBuffer) void {
    active_buf = prev;
}

/// Current buffer, or null if none is active.
pub fn current() ?*DomCmdBuffer {
    return active_buf;
}

/// Transfer `s` into the active buffer's owned list. If no active buffer,
/// returns `s` unchanged (caller remains responsible).
pub fn takeOwnedActive(s: []u8) []const u8 {
    if (active_buf) |buf| return buf.takeOwned(s);
    return s;
}

/// Copy `s` into the active buffer's owned storage (lives until flush/clear).
pub fn dupeActive(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (active_buf) |buf| return try buf.dupe(s);
    return try allocator.dupe(u8, s);
}

pub const DomCmdBuffer = struct {
    allocator: std.mem.Allocator,
    /// In-place flush payload: 8-byte header + records.
    bytes: std.ArrayList(u8) = .empty,
    /// Heap strings that must outlive encode until flush.
    owned: std.ArrayList([]u8) = .empty,
    count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) DomCmdBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DomCmdBuffer) void {
        self.freeOwned();
        self.bytes.deinit(self.allocator);
        self.owned.deinit(self.allocator);
        self.* = undefined;
    }

    fn freeOwned(self: *DomCmdBuffer) void {
        for (self.owned.items) |s| self.allocator.free(s);
        self.owned.clearRetainingCapacity();
    }

    pub fn clear(self: *DomCmdBuffer) void {
        self.freeOwned();
        self.bytes.clearRetainingCapacity();
        self.count = 0;
    }

    /// Take ownership of an allocator-owned slice; kept until flush/clear.
    pub fn takeOwned(self: *DomCmdBuffer, s: []u8) []const u8 {
        self.owned.append(self.allocator, s) catch {
            self.allocator.free(s);
            return "";
        };
        return s;
    }

    /// Duplicate into buffer-owned memory valid until the next `clear`/`flush`/`deinit`.
    pub fn dupe(self: *DomCmdBuffer, s: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, s);
        try self.owned.append(self.allocator, copy);
        return copy;
    }

    /// Flush in-place (no extra alloc/copy of the record stream).
    pub fn flush(self: *DomCmdBuffer) void {
        if (!is_wasm) {
            self.clear();
            return;
        }
        if (self.count == 0) {
            self.clear();
            return;
        }

        std.mem.writeInt(u32, self.bytes.items[0..4], self.count, .little);
        std.mem.writeInt(u32, self.bytes.items[4..8], 0, .little);
        ext._flush(self.bytes.items.ptr, self.bytes.items.len);
        self.clear();
    }

    fn ensureHeader(self: *DomCmdBuffer) !void {
        if (self.bytes.items.len >= HEADER_SIZE) return;
        try self.bytes.appendNTimes(self.allocator, 0, HEADER_SIZE);
    }

    fn appendRecord(self: *DomCmdBuffer, op: DomOp, p0: u32, p1: u32, p2: u32, p3: u32, p4: u32) !void {
        try self.ensureHeader();
        const start = self.bytes.items.len;
        try self.bytes.resize(self.allocator, start + RECORD_SIZE);
        const rec = self.bytes.items[start..][0..RECORD_SIZE];
        rec[0] = @backingInt(op);
        rec[1] = 0;
        std.mem.writeInt(u16, rec[2..4], 0, .little);
        std.mem.writeInt(u32, rec[4..8], p0, .little);
        std.mem.writeInt(u32, rec[8..12], p1, .little);
        std.mem.writeInt(u32, rec[12..16], p2, .little);
        std.mem.writeInt(u32, rec[16..20], p3, .little);
        std.mem.writeInt(u32, rec[20..24], p4, .little);
        self.count += 1;
    }

    inline fn id32(id: u64) u32 {
        return @truncate(id);
    }

    inline fn ptr32(s: []const u8) u32 {
        if (s.len == 0) return 0;
        return @intCast(@intFromPtr(s.ptr));
    }

    pub fn createElement(self: *DomCmdBuffer, tag_id: usize, vnode_id: u64) !void {
        try self.appendRecord(.create_element, @intCast(tag_id), id32(vnode_id), 0, 0, 0);
    }

    /// Create with an explicit tag name string (web components / `Tag.custom`).
    pub fn createElementNamed(self: *DomCmdBuffer, tag_id: usize, name: []const u8, vnode_id: u64) !void {
        try self.appendRecord(.create_element, @intCast(tag_id), id32(vnode_id), ptr32(name), @intCast(name.len), 0);
    }

    pub fn createText(self: *DomCmdBuffer, text: []const u8, vnode_id: u64) !void {
        try self.appendRecord(.create_text, ptr32(text), @intCast(text.len), id32(vnode_id), 0, 0);
    }

    pub fn hydrateInsert(self: *DomCmdBuffer, vnode_id: u64, end_comment_ref: u64) !void {
        const lo: u32 = @truncate(end_comment_ref);
        const hi: u32 = @truncate(end_comment_ref >> 32);
        try self.appendRecord(.hydrate_insert, id32(vnode_id), lo, hi, 0, 0);
    }

    pub fn setAttr(self: *DomCmdBuffer, vnode_id: u64, name: []const u8, val: []const u8) !void {
        try self.appendRecord(.set_attr, id32(vnode_id), ptr32(name), @intCast(name.len), ptr32(val), @intCast(val.len));
    }

    pub fn setProp(self: *DomCmdBuffer, vnode_id: u64, name: []const u8, val: []const u8) !void {
        try self.appendRecord(.set_prop, id32(vnode_id), ptr32(name), @intCast(name.len), ptr32(val), @intCast(val.len));
    }

    pub fn removeAttr(self: *DomCmdBuffer, vnode_id: u64, name: []const u8) !void {
        try self.appendRecord(.remove_attr, id32(vnode_id), ptr32(name), @intCast(name.len), 0, 0);
    }

    pub fn setNodeValue(self: *DomCmdBuffer, vnode_id: u64, text: []const u8) !void {
        try self.appendRecord(.set_node_value, id32(vnode_id), ptr32(text), @intCast(text.len), 0, 0);
    }

    pub fn setInnerHtml(self: *DomCmdBuffer, vnode_id: u64, html: []const u8) !void {
        try self.appendRecord(.set_inner_html, id32(vnode_id), ptr32(html), @intCast(html.len), 0, 0);
    }

    pub fn appendChild(self: *DomCmdBuffer, parent_id: u64, child_id: u64) !void {
        try self.appendRecord(.append_child, id32(parent_id), id32(child_id), 0, 0, 0);
    }

    pub fn insertBefore(self: *DomCmdBuffer, parent_id: u64, child_id: u64, ref_id: u64) !void {
        try self.appendRecord(.insert_before, id32(parent_id), id32(child_id), id32(ref_id), 0, 0);
    }

    pub fn removeChild(self: *DomCmdBuffer, parent_id: u64, child_id: u64) !void {
        try self.appendRecord(.remove_child, id32(parent_id), id32(child_id), 0, 0, 0);
    }

    pub fn replaceChild(self: *DomCmdBuffer, parent_id: u64, new_id: u64, old_id: u64) !void {
        try self.appendRecord(.replace_child, id32(parent_id), id32(new_id), id32(old_id), 0, 0);
    }
};

fn flushOneshot(buf: *DomCmdBuffer) void {
    buf.flush();
    buf.deinit();
}

pub fn createElement(tag_id: usize, vnode_id: u64) void {
    if (active_buf) |buf| {
        buf.createElement(tag_id, vnode_id) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    tmp.createElement(tag_id, vnode_id) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn createElementNamed(tag_id: usize, name: []const u8, vnode_id: u64) void {
    if (active_buf) |buf| {
        buf.createElementNamed(tag_id, name, vnode_id) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    tmp.createElementNamed(tag_id, name, vnode_id) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn createText(text: []const u8, vnode_id: u64) void {
    if (active_buf) |buf| {
        buf.createText(text, vnode_id) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    const kept = tmp.dupe(text) catch {
        tmp.deinit();
        return;
    };
    tmp.createText(kept, vnode_id) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn hydrateInsert(vnode_id: u64, end_comment_ref: u64) void {
    if (active_buf) |buf| {
        buf.hydrateInsert(vnode_id, end_comment_ref) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    tmp.hydrateInsert(vnode_id, end_comment_ref) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn setAttr(vnode_id: u64, name: []const u8, val: []const u8) void {
    if (active_buf) |buf| {
        buf.setAttr(vnode_id, name, val) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    const n = tmp.dupe(name) catch {
        tmp.deinit();
        return;
    };
    const v = tmp.dupe(val) catch {
        tmp.deinit();
        return;
    };
    tmp.setAttr(vnode_id, n, v) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn setProp(vnode_id: u64, name: []const u8, val: []const u8) void {
    if (active_buf) |buf| {
        buf.setProp(vnode_id, name, val) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    const n = tmp.dupe(name) catch {
        tmp.deinit();
        return;
    };
    const v = tmp.dupe(val) catch {
        tmp.deinit();
        return;
    };
    tmp.setProp(vnode_id, n, v) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn removeAttr(vnode_id: u64, name: []const u8) void {
    if (active_buf) |buf| {
        buf.removeAttr(vnode_id, name) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    const n = tmp.dupe(name) catch {
        tmp.deinit();
        return;
    };
    tmp.removeAttr(vnode_id, n) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn setNodeValue(vnode_id: u64, text: []const u8) void {
    if (active_buf) |buf| {
        buf.setNodeValue(vnode_id, text) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    const t = tmp.dupe(text) catch {
        tmp.deinit();
        return;
    };
    tmp.setNodeValue(vnode_id, t) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn setInnerHtml(vnode_id: u64, html: []const u8) void {
    if (active_buf) |buf| {
        buf.setInnerHtml(vnode_id, html) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    const h = tmp.dupe(html) catch {
        tmp.deinit();
        return;
    };
    tmp.setInnerHtml(vnode_id, h) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn appendChild(parent_id: u64, child_id: u64) void {
    if (active_buf) |buf| {
        buf.appendChild(parent_id, child_id) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    tmp.appendChild(parent_id, child_id) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn insertBefore(parent_id: u64, child_id: u64, ref_id: u64) void {
    if (active_buf) |buf| {
        buf.insertBefore(parent_id, child_id, ref_id) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    tmp.insertBefore(parent_id, child_id, ref_id) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn removeChild(parent_id: u64, child_id: u64) void {
    if (active_buf) |buf| {
        buf.removeChild(parent_id, child_id) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    tmp.removeChild(parent_id, child_id) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}

pub fn replaceChild(parent_id: u64, new_id: u64, old_id: u64) void {
    if (active_buf) |buf| {
        buf.replaceChild(parent_id, new_id, old_id) catch {};
        return;
    }
    var tmp = DomCmdBuffer.init(std.heap.wasm_allocator);
    tmp.replaceChild(parent_id, new_id, old_id) catch {
        tmp.deinit();
        return;
    };
    flushOneshot(&tmp);
}
