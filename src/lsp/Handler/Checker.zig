//! Compile diagnostics for `zx lsp`: on save, type-checks the app in the background
//! (`zx build --check`) and publishes its errors merged with each file's syntax
//! diagnostics. Errors land on `.zx`/`.zig` source, including comptime validation
//! (route signatures, server handler registration) relocated onto user code.
const Checker = @This();

const std = @import("std");
const builtin = @import("builtin");
const lsp = @import("lsp");
const text = @import("../text.zig");
const check = @import("../../cli/shared/check.zig");

const Diagnostic = lsp.types.flat.Diagnostic;

/// Spawning `zig build` needs a native OS.
pub const supported = builtin.os.tag != .wasi and builtin.os.tag != .freestanding;

const Entry = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Diagnostic,

    fn deinit(self: *Entry) void {
        self.arena.deinit();
    }
};

allocator: std.mem.Allocator,
io: std.Io,
/// Must be thread-safe for writes: published from the background check too.
transport: *lsp.Transport,
environ_map: ?*std.process.Environ.Map = null,
encoding: lsp.offsets.Encoding = .@"utf-16",

group: std.Io.Group = .init,
mutex: std.Io.Mutex = .init,
running: bool = false,
pending_root: ?[]u8 = null,
// Per URI, guarded by `mutex`.
syntax: std.StringHashMapUnmanaged(Entry) = .empty,
compile: std.StringHashMapUnmanaged(Entry) = .empty,

pub fn init(allocator: std.mem.Allocator, io: std.Io, transport: *lsp.Transport) Checker {
    return .{ .allocator = allocator, .io = io, .transport = transport };
}

pub fn deinit(self: *Checker) void {
    self.group.cancel(self.io);
    if (self.pending_root) |r| self.allocator.free(r);
    freeMap(self.allocator, &self.syntax);
    freeMap(self.allocator, &self.compile);
}

/// Publish `uri`'s syntax diagnostics together with its latest compile errors.
pub fn publish(self: *Checker, uri: []const u8, syntax: []const Diagnostic) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const entry = cloneEntry(self.allocator, syntax) catch return;
    putEntry(self.allocator, &self.syntax, uri, entry) catch return;
    self.send(uri);
}

/// Forget `uri`'s syntax diagnostics (closed document); compile errors stay.
pub fn close(self: *Checker, uri: []const u8) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.syntax.fetchRemove(uri)) |kv| {
        self.allocator.free(kv.key);
        var e = kv.value;
        e.deinit();
    }
    self.send(uri);
}

/// Type-check the Ziex app containing `path` in the background. Saves during a
/// run queue one more run rather than overlapping.
pub fn request(self: *Checker, path: []const u8) void {
    if (comptime !supported) return;
    const root = findRoot(self.io, self.allocator, path) orelse return;

    self.mutex.lockUncancelable(self.io);
    if (self.running) {
        if (self.pending_root) |r| self.allocator.free(r);
        self.pending_root = root;
        self.mutex.unlock(self.io);
        return;
    }
    self.running = true;
    self.mutex.unlock(self.io);

    self.group.concurrent(self.io, loop, .{ self, root }) catch {
        self.mutex.lockUncancelable(self.io);
        self.running = false;
        self.mutex.unlock(self.io);
        self.allocator.free(root);
    };
}

fn loop(self: *Checker, first_root: []u8) void {
    var root = first_root;
    while (true) {
        self.runOnce(root);
        self.allocator.free(root);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        root = self.pending_root orelse {
            self.running = false;
            return;
        };
        self.pending_root = null;
    }
}

fn runOnce(self: *Checker, root: []const u8) void {
    var result = check.run(self.io, self.allocator, .{
        .root = root,
        .environ_map = self.environ_map,
    }) catch |err| {
        std.log.warn("zx check failed to run: {t}", .{err});
        return;
    };
    defer result.deinit();

    var next: std.StringHashMapUnmanaged(std.ArrayList(Diagnostic)) = .empty;
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    self.collect(a, root, result.diagnostics, &next) catch return;

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    // Republish every URI whose compile errors appeared, changed or cleared.
    var touched: std.ArrayList([]const u8) = .empty;
    var old = self.compile.iterator();
    while (old.next()) |kv| touched.append(a, a.dupe(u8, kv.key_ptr.*) catch continue) catch {};
    freeMap(self.allocator, &self.compile);
    self.compile = .empty;

    var it = next.iterator();
    while (it.next()) |kv| {
        const entry = cloneEntry(self.allocator, kv.value_ptr.items) catch continue;
        putEntry(self.allocator, &self.compile, kv.key_ptr.*, entry) catch continue;
        touched.append(a, kv.key_ptr.*) catch {};
    }
    for (touched.items) |uri| self.send(uri);
}

fn collect(
    self: *Checker,
    a: std.mem.Allocator,
    root: []const u8,
    diagnostics: []const check.Builder.Diagnostic,
    out: *std.StringHashMapUnmanaged(std.ArrayList(Diagnostic)),
) !void {
    var sources: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (diagnostics) |d| {
        if (d.kind != .@"error" or d.file.len == 0 or d.line == 0) continue;
        const path = if (std.fs.path.isAbsolute(d.file)) d.file else try std.fs.path.join(a, &.{ root, d.file });
        // Only project sources; errors left in dependencies have no editor file to land on.
        if (!std.mem.startsWith(u8, path, root)) continue;

        const source = sources.get(path) orelse blk: {
            const s = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(16 << 20)) catch continue;
            try sources.put(a, path, s);
            break :blk s;
        };
        const line: u32 = d.line - 1;
        const col: u32 = d.col -| 1;
        const gop = try out.getOrPut(a, try std.fmt.allocPrint(a, "file://{s}", .{path}));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, .{
            .range = .{
                .start = text.byteColumnToPosition(source, line, col, self.encoding),
                .end = text.byteColumnToPosition(source, line, col + wordLen(source, line, col), self.encoding),
            },
            .severity = .Error,
            .source = "zx check",
            .message = .{ .string = d.message },
        });
    }
}

/// Write `uri`'s syntax + compile diagnostics. Caller holds `mutex`.
fn send(self: *Checker, uri: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const syntax = if (self.syntax.get(uri)) |e| e.items else &.{};
    const compile = if (self.compile.get(uri)) |e| e.items else &.{};
    const merged = std.mem.concat(a, Diagnostic, &.{ syntax, compile }) catch return;

    self.transport.writeNotification(
        self.io,
        a,
        "textDocument/publishDiagnostics",
        lsp.types.flat.PublishDiagnosticsParams,
        .{ .uri = uri, .diagnostics = merged },
        .{ .emit_null_optional_fields = false },
    ) catch |err| std.log.err("Failed to write publishDiagnostics: {}", .{err});
}

/// Nearest ancestor directory whose `build.zig` imports ziex.
fn findRoot(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var dir = std.fs.path.dirname(path);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const build_zig = std.fs.path.join(allocator, &.{ d, "build.zig" }) catch return null;
        defer allocator.free(build_zig);
        const source = std.Io.Dir.cwd().readFileAlloc(io, build_zig, allocator, .limited(1 << 20)) catch continue;
        defer allocator.free(source);
        if (std.mem.indexOf(u8, source, "@import(\"ziex\")") != null) return allocator.dupe(u8, d) catch null;
    }
    return null;
}

// Underline the identifier at the error, or one character.
fn wordLen(source: []const u8, line: u32, col: u32) u32 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var i: u32 = 0;
    while (lines.next()) |l| : (i += 1) {
        if (i != line) continue;
        var n: u32 = 0;
        while (col + n < l.len and (std.ascii.isAlphanumeric(l[col + n]) or l[col + n] == '_')) n += 1;
        return @max(n, 1);
    }
    return 1;
}

fn cloneEntry(allocator: std.mem.Allocator, items: []const Diagnostic) !Entry {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const out = try a.alloc(Diagnostic, items.len);
    for (items, out) |d, *o| {
        o.* = d;
        if (d.source) |s| o.source = try a.dupe(u8, s);
        o.message = switch (d.message) {
            .string => |s| .{ .string = try a.dupe(u8, s) },
            else => d.message,
        };
    }
    return .{ .arena = arena, .items = out };
}

fn putEntry(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(Entry), uri: []const u8, entry: Entry) !void {
    var e = entry;
    if (map.getPtr(uri)) |existing| {
        existing.deinit();
        existing.* = e;
        return;
    }
    errdefer e.deinit();
    const key = try allocator.dupe(u8, uri);
    errdefer allocator.free(key);
    try map.put(allocator, key, e);
}

fn freeMap(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(Entry)) void {
    var it = map.iterator();
    while (it.next()) |kv| {
        allocator.free(kv.key_ptr.*);
        kv.value_ptr.deinit();
    }
    map.deinit(allocator);
}
