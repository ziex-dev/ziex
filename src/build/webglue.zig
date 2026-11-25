//! Per-app JS glue: the `__zx_web` shims a client wasm actually imports.
const std = @import("std");
const shims = @import("../runtime/client/web/shims.zig");

pub const module_name = "__zx_web";

/// Returns `globalThis.__zx_web=({...helpers})=>({...shims})` for the imports
/// of `wasm`. Always defines it (`false` without imports) so init() knows
/// not to fetch the glue separately.
pub fn generate(allocator: std.mem.Allocator, wasm: []const u8) ![]u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(allocator);
    try importNames(allocator, wasm, module_name, &names);
    if (names.items.len == 0) return allocator.dupe(u8, "globalThis.__zx_web=false;\n");

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    // Enum tables referenced as `E_<Name>` by the selected shims.
    var enums: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer enums.deinit(allocator);
    for (names.items) |n| {
        const src = lookup(&shims.shims, n) orelse continue;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, src, i, "E_")) |at| {
            var end = at + 2;
            while (end < src.len and (std.ascii.isAlphanumeric(src[end]) or src[end] == '_')) end += 1;
            try enums.put(allocator, src[at + 2 .. end], {});
            i = end;
        }
    }

    try w.writeAll("globalThis.__zx_web=({R,S,N,H,W,F,V,A,T})=>{");
    for (enums.keys()) |e| {
        const arr = lookup(&shims.enums, e) orelse continue;
        try w.print("const E_{s}={s};", .{ e, arr });
    }
    try w.writeAll("return{");
    var first = true;
    for (names.items) |n| {
        const src = lookup(&shims.shims, n) orelse continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}\":{s}", .{ n, src });
    }
    try w.writeAll("}};\n");
    return out.toOwnedSlice();
}

fn lookup(table: []const shims.Entry, name: []const u8) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, table[mid][0], name)) {
            .eq => return table[mid][1],
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// Appends the field names of `module`'s imports (sorted, deduped).
pub fn importNames(allocator: std.mem.Allocator, wasm: []const u8, module: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var r: Reader = .{ .bytes = wasm };
    if (wasm.len < 8 or !std.mem.eql(u8, wasm[0..4], "\x00asm")) return error.InvalidWasm;
    r.pos = 8;
    while (r.pos < wasm.len) {
        const id = try r.byte();
        const size = try r.uleb();
        const end = r.pos + size;
        if (end > wasm.len) return error.InvalidWasm;
        if (id != 2) {
            r.pos = end;
            continue;
        }
        const count = try r.uleb();
        for (0..count) |_| {
            const mod = try r.name();
            const field = try r.name();
            switch (try r.byte()) {
                0x00 => _ = try r.uleb(), // func
                0x01 => {
                    _ = try r.byte();
                    try r.limits();
                },
                0x02 => try r.limits(),
                0x03 => {
                    _ = try r.byte();
                    _ = try r.byte();
                },
                0x04 => {
                    _ = try r.byte();
                    _ = try r.uleb();
                },
                else => return error.InvalidWasm,
            }
            if (std.mem.eql(u8, mod, module)) try out.append(allocator, field);
        }
        break;
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *Reader) !u8 {
        if (self.pos >= self.bytes.len) return error.InvalidWasm;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    fn uleb(self: *Reader) !usize {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.byte();
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            shift = std.math.add(u6, shift, 7) catch return error.InvalidWasm;
        }
        return @intCast(result);
    }

    fn name(self: *Reader) ![]const u8 {
        const len = try self.uleb();
        if (self.pos + len > self.bytes.len) return error.InvalidWasm;
        defer self.pos += len;
        return self.bytes[self.pos..][0..len];
    }

    fn limits(self: *Reader) !void {
        const flags = try self.byte();
        _ = try self.uleb();
        if (flags & 1 != 0) _ = try self.uleb();
    }
};
