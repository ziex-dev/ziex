//! In-memory filesystem and a WASI preview1 host, for running `zig.wasm`, `zx.wasm`
//! and compiled playground programs inside the playground worker.
//!
//! The host functions are `export fn`s of the worker's own wasm, handed to the guest
//! as its `wasi_snapshot_preview1` imports (see `imports`), so guest syscalls are
//! direct wasm-to-wasm calls. Guest memory is reached through `js`.
const std = @import("std");
const zx = @import("zx");
const js = zx.client.js;

const gpa = zx.allocator;

// --- Filesystem ---

pub const Node = struct {
    ino: u64,
    /// Owns `data`, `children` and the nodes created under this one.
    alloc: std.mem.Allocator,
    mtime: u64 = 0,
    kind: Kind,
    data: std.ArrayList(u8) = .empty,
    children: std.array_hash_map.String(*Node) = .empty,

    pub const Kind = enum { file, dir };

    pub fn newDir(alloc: std.mem.Allocator) !*Node {
        const n = try alloc.create(Node);
        n.* = .{ .ino = nextIno(), .alloc = alloc, .kind = .dir, .mtime = now() };
        return n;
    }

    pub fn newFile(alloc: std.mem.Allocator, data: []const u8) !*Node {
        const n = try alloc.create(Node);
        n.* = .{ .ino = nextIno(), .alloc = alloc, .kind = .file, .mtime = now() };
        try n.data.appendSlice(alloc, data);
        return n;
    }

    pub fn get(self: *Node, name: []const u8) ?*Node {
        return self.children.get(name);
    }

    pub fn put(self: *Node, name: []const u8, child: *Node) !void {
        const gop = try self.children.getOrPut(self.alloc, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.alloc.dupe(u8, name);
        gop.value_ptr.* = child;
        self.mtime = now();
    }

    /// Writes `data` at `path` (`a/b/c.zig`), creating directories on the way.
    pub fn writePath(self: *Node, path: []const u8, data: []const u8) !void {
        var dir = self;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (it.peek() == null) {
                if (dir.get(seg)) |existing| if (existing.kind == .file) {
                    existing.data.clearRetainingCapacity();
                    try existing.data.appendSlice(existing.alloc, data);
                    return;
                };
                return dir.put(seg, try newFile(dir.alloc, data));
            }
            dir = dir.get(seg) orelse blk: {
                const d = try newDir(dir.alloc);
                try dir.put(seg, d);
                break :blk d;
            };
            if (dir.kind != .dir) return error.NotDir;
        }
    }

    pub fn readPath(self: *Node, path: []const u8) ?[]const u8 {
        var node = self;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |seg| node = node.get(seg) orelse return null;
        return if (node.kind == .file) node.data.items else null;
    }
};

var ino_counter: u64 = 1;
fn nextIno() u64 {
    ino_counter += 1;
    return ino_counter;
}

/// Unpacks a `.tar.gz`; entries under `strip` (e.g. `lib/`) land in `root` without it.
pub fn untarGz(root: *Node, tgz: []const u8, strip: []const u8) !void {
    var in: std.Io.Reader = .fixed(tgz);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var gz: std.compress.flate.Decompress = .init(&in, .gzip, window);

    var name_buf: [4096]u8 = undefined;
    var link_buf: [4096]u8 = undefined;
    var it: std.tar.Iterator = .init(&gz.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, strip)) continue;
        content.clearRetainingCapacity();
        const size: usize = @intCast(entry.size);
        try content.ensureTotalCapacity(gpa, size);
        content.items.len = size;
        try it.reader.readSliceAll(content.items);
        it.unread_file_bytes = 0;
        try root.writePath(entry.name[strip.len..], content.items);
    }
}

// --- Guest process ---

const Errno = enum(u16) {
    success = 0,
    acces = 2,
    badf = 8,
    exist = 20,
    inval = 28,
    io = 29,
    isdir = 31,
    noent = 44,
    nosys = 52,
    notdir = 54,
    notempty = 55,
    spipe = 70,
    notcapable = 76,
};

const Filetype = enum(u8) { unknown = 0, character_device = 2, directory = 3, regular_file = 4 };

const Fd = union(enum) {
    /// stdin: reads come from `Process.stdin`.
    stdin,
    /// stdout/stderr: appended to `Process.out[i]`.
    out: u1,
    node: struct { node: *Node, offset: u64 = 0, append: bool = false, preopen: ?[]const u8 = null },
};

pub const Preopen = struct { name: []const u8, dir: *Node };

/// One guest run: its argv, fds and output.
pub const Process = struct {
    args: []const []const u8,
    env: []const []const u8 = &.{},
    stdin: []const u8 = "",
    stdin_pos: usize = 0,
    fds: std.ArrayList(?Fd) = .empty,
    out: [2]std.ArrayList(u8) = .{ .empty, .empty },
    /// stdout and stderr into the same buffer (keeps them interleaved).
    merge_output: bool = false,
    exit_code: ?u32 = null,
    memory: js.Value = .undefined,
    view: js.Value = .undefined,

    pub fn init(args: []const []const u8, preopens: []const Preopen) !Process {
        var p: Process = .{ .args = args };
        try p.fds.appendSlice(gpa, &.{ .stdin, .{ .out = 0 }, .{ .out = 1 } });
        for (preopens) |po| try p.fds.append(gpa, .{ .node = .{ .node = po.dir, .preopen = po.name } });
        return p;
    }

    pub fn deinit(p: *Process) void {
        p.fds.deinit(gpa);
        p.out[0].deinit(gpa);
        p.out[1].deinit(gpa);
        p.view.deinit();
        p.memory.deinit();
    }

    pub fn stdout(p: *Process) []const u8 {
        return p.out[0].items;
    }

    pub fn stderr(p: *Process) []const u8 {
        return if (p.merge_output) p.out[0].items else p.out[1].items;
    }
};

/// The process whose guest is running; host functions act on it.
var current: ?*Process = null;

pub const RunError = error{ InvalidWasm, MissingImport, InstantiateFailed, NoStart } || js.Error || std.mem.Allocator.Error;

pub const Extra = struct {
    /// Extra import modules, e.g. `__zx` for SSR wasm: `{ module, name, export }`.
    imports: []const Import = &.{},
    pub const Import = struct { module: []const u8, name: []const u8, @"export": []const u8 };
};

/// Instantiates `module` (a `WebAssembly.Module`) against this host and runs `_start`.
/// Returns false when the guest trapped (other than `proc_exit`); `p.exit_code` has its code.
pub fn run(p: *Process, module: js.Value, extra: Extra) RunError!bool {
    const exports = try instantiate(p, module, extra);
    defer exports.deinit();

    current = p;
    defer current = null;
    refreshView(p);
    if (exports.get(?js.Object, "__wasm_call_ctors") catch null) |ctors| {
        defer ctors.deinit();
        _ = exports.call(void, "__wasm_call_ctors", .{}) catch {};
    }
    const ok = exports.call(void, "_start", .{});
    if (ok) |_| {
        if (p.exit_code == null) p.exit_code = 0;
        return true;
    } else |_| {
        // proc_exit traps to unwind the guest.
        return p.exit_code != null;
    }
}

/// A guest kept alive between calls into its exports (e.g. a language server).
pub const Session = struct {
    process: Process,
    exports: js.Object,

    pub fn start(s: *Session, args: []const []const u8, env: []const []const u8, preopens: []const Preopen, module: js.Value) RunError!void {
        s.process = try .init(args, preopens);
        s.process.env = env;
        s.exports = try instantiate(&s.process, module, .{});
    }

    /// Makes the host functions act on this guest until `leave`.
    pub fn enter(s: *Session) void {
        current = &s.process;
        refreshView(&s.process);
    }

    pub fn leave(_: *Session) void {
        current = null;
    }

    /// Copies `bytes` into the guest at `ptr` (between `enter` and `leave`).
    pub fn write(s: *Session, ptr: u32, bytes: []const u8) void {
        writeMem(&s.process, ptr, bytes);
    }
};

fn instantiate(p: *Process, module: js.Value, extra: Extra) RunError!js.Object {
    const wa = try js.global.get(js.Object, "WebAssembly");
    defer wa.deinit();
    const imports = try buildImports(module, extra);
    defer imports.deinit();

    const Instance = try wa.get(js.Object, "Instance");
    defer Instance.deinit();
    const instance = Instance.new(.{ module, imports }) catch return error.InstantiateFailed;
    defer instance.deinit();
    const exports = try instance.get(js.Object, "exports");
    p.memory = try exports.get(js.Value, "memory");
    return exports;
}

/// `new WebAssembly.Module(bytes)`, without the start section (it would run before
/// `run` has the guest's memory).
pub fn compile(bytes: []const u8) !js.Value {
    const stripped = try stripStart(bytes);
    defer if (stripped.ptr != bytes.ptr) gpa.free(stripped);
    const wa = try js.global.get(js.Object, "WebAssembly");
    defer wa.deinit();
    const Module = try wa.get(js.Object, "Module");
    defer Module.deinit();
    const m = Module.new(.{js.bytes(stripped)}) catch return error.InvalidWasm;
    return m.value;
}

pub fn compileBuffer(buffer: js.Value) !js.Value {
    const wa = try js.global.get(js.Object, "WebAssembly");
    defer wa.deinit();
    const Module = try wa.get(js.Object, "Module");
    defer Module.deinit();
    const m = Module.new(.{buffer}) catch return error.InvalidWasm;
    return m.value;
}

fn stripStart(bytes: []const u8) ![]const u8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "\x00asm")) return error.InvalidWasm;
    var pos: usize = 8;
    while (pos < bytes.len) {
        const start = pos;
        const id = bytes[pos];
        pos += 1;
        var r: std.Io.Reader = .fixed(bytes[pos..]);
        const size = r.takeLeb128(u32) catch return error.InvalidWasm;
        pos += r.seek;
        const end = pos + size;
        if (end > bytes.len) return error.InvalidWasm;
        if (id == 8) {
            const out = try gpa.alloc(u8, bytes.len - (end - start));
            @memcpy(out[0..start], bytes[0..start]);
            @memcpy(out[start..], bytes[end..]);
            return out;
        }
        pos = end;
    }
    return bytes;
}

fn buildImports(module: js.Value, extra: Extra) !js.Object {
    const Object = try js.global.get(js.Object, "Object");
    defer Object.deinit();
    const wa = try js.global.get(js.Object, "WebAssembly");
    defer wa.deinit();
    const Module = try wa.get(js.Object, "Module");
    defer Module.deinit();
    const own = js.exports();
    defer own.deinit();

    const list = try Module.call(js.Object, "imports", .{module});
    defer list.deinit();
    const imports = try Object.new(.{});
    errdefer imports.deinit();

    const n = list.value.len();
    for (0..n) |i| {
        const entry: js.Object = .{ .value = list.value.at(i) };
        defer entry.deinit();
        const mod = try entry.getAlloc(js.String, gpa, "module");
        defer gpa.free(mod);
        const name = try entry.getAlloc(js.String, gpa, "name");
        defer gpa.free(name);

        var export_buf: [96]u8 = undefined;
        const export_name: []const u8 = if (std.mem.eql(u8, mod, "wasi_snapshot_preview1"))
            std.mem.print(&export_buf, "pgwasi_{s}", .{name}) catch return error.MissingImport
        else for (extra.imports) |imp| {
            if (std.mem.eql(u8, imp.module, mod) and std.mem.eql(u8, imp.name, name)) break imp.@"export";
        } else {
            std.log.err("playground: unsupported import {s}.{s}", .{ mod, name });
            return error.MissingImport;
        };
        const func = own.get(?js.Object, export_name) catch null orelse {
            std.log.err("playground: unsupported import {s}.{s}", .{ mod, name });
            return error.MissingImport;
        };
        defer func.deinit();

        const ns = try imports.get(?js.Object, mod) orelse blk: {
            const o = try Object.new(.{});
            try imports.set(mod, o);
            break :blk o;
        };
        defer ns.deinit();
        try ns.set(name, func);
    }
    return imports;
}

// --- Guest memory ---

fn refreshView(p: *Process) void {
    p.view.deinit();
    const memory: js.Object = .{ .value = p.memory };
    const buffer = memory.get(js.Object, "buffer") catch return;
    defer buffer.deinit();
    const U8 = js.global.get(js.Object, "Uint8Array") catch return;
    defer U8.deinit();
    const view = U8.new(.{buffer}) catch return;
    p.view = view.value;
}

fn readMem(p: *Process, ptr: u32, dst: []u8) void {
    if (dst.len == 0) return;
    var tries: u2 = 0;
    while (tries < 2) : (tries += 1) {
        const view: js.Object = .{ .value = p.view };
        if (view.call(js.Value, "subarray", .{ ptr, @as(u64, ptr) + dst.len })) |sub| {
            defer sub.deinit();
            if (sub.copyBytes(dst) == dst.len) return;
        } else |_| {}
        // Memory grew: the old buffer is detached.
        refreshView(p);
    }
    @memset(dst, 0);
}

fn writeMem(p: *Process, ptr: u32, src: []const u8) void {
    if (src.len == 0) return;
    var tries: u2 = 0;
    while (tries < 2) : (tries += 1) {
        const view: js.Object = .{ .value = p.view };
        if (view.call(void, "set", .{ js.bytes(src), ptr })) |_| return else |_| {}
        refreshView(p);
    }
}

fn readAlloc(p: *Process, ptr: u32, len: u32) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    readMem(p, ptr, buf);
    return buf;
}

fn readInt(p: *Process, comptime T: type, ptr: u32) T {
    var b: [@sizeOf(T)]u8 = undefined;
    readMem(p, ptr, &b);
    return std.mem.readInt(T, &b, .little);
}

fn writeInt(p: *Process, comptime T: type, ptr: u32, v: T) void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    writeMem(p, ptr, &b);
}

const Iovec = struct { ptr: u32, len: u32 };

fn readIovs(p: *Process, iovs: u32, n: u32) ![]Iovec {
    const raw = try readAlloc(p, iovs, n * 8);
    defer gpa.free(raw);
    const out = try gpa.alloc(Iovec, n);
    for (out, 0..) |*v, i| v.* = .{
        .ptr = std.mem.readInt(u32, raw[i * 8 ..][0..4], .little),
        .len = std.mem.readInt(u32, raw[i * 8 + 4 ..][0..4], .little),
    };
    return out;
}

// --- Clock ---

fn now() u64 {
    const date = js.global.get(js.Object, "Date") catch return 0;
    defer date.deinit();
    const ms = date.call(f64, "now", .{}) catch return 0;
    return @intFromFloat(ms * std.time.ns_per_ms);
}

fn monotonic() u64 {
    const perf = js.global.get(js.Object, "performance") catch return now();
    defer perf.deinit();
    const ms = perf.call(f64, "now", .{}) catch return now();
    return @intFromFloat(ms * std.time.ns_per_ms);
}

var prng: ?std.Random.DefaultPrng = null;

// --- Path resolution ---

fn dirNode(p: *Process, fd: u32) ?*Node {
    if (fd >= p.fds.items.len) return null;
    const f = p.fds.items[fd] orelse return null;
    return switch (f) {
        .node => |n| if (n.node.kind == .dir) n.node else null,
        else => null,
    };
}

const Resolved = struct { parent: *Node, name: []const u8, node: ?*Node };

/// Resolves `path` under `base`. `..` can't leave `base` (WASI capability rules).
const ResolveError = error{ NoEnt, NotDir, NotCapable, Inval };

fn errnoOf(e: ResolveError) Errno {
    return switch (e) {
        error.NoEnt => .noent,
        error.NotDir => .notdir,
        error.NotCapable => .notcapable,
        error.Inval => .inval,
    };
}

fn resolve(base: *Node, path: []const u8) ResolveError!Resolved {
    var stack: [64]*Node = undefined;
    var depth: usize = 0;
    stack[0] = base;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    var last: []const u8 = ".";
    while (it.next()) |seg| {
        const is_last = it.peek() == null;
        if (std.mem.eql(u8, seg, ".")) {
            if (is_last) last = ".";
            continue;
        }
        if (std.mem.eql(u8, seg, "..")) {
            if (depth == 0) return error.NotCapable;
            depth -= 1;
            if (is_last) last = ".";
            continue;
        }
        if (is_last) {
            last = seg;
            break;
        }
        const next = stack[depth].get(seg) orelse return error.NoEnt;
        if (next.kind != .dir) return error.NotDir;
        if (depth + 1 >= stack.len) return error.Inval;
        depth += 1;
        stack[depth] = next;
    }
    if (std.mem.eql(u8, last, ".")) {
        const parent = if (depth > 0) stack[depth - 1] else stack[0];
        return .{ .parent = parent, .name = ".", .node = stack[depth] };
    }
    return .{ .parent = stack[depth], .name = last, .node = stack[depth].get(last) };
}

fn readPath(p: *Process, ptr: u32, len: u32) ![]u8 {
    return readAlloc(p, ptr, len);
}

// --- Stat ---

fn writeFilestat(p: *Process, ptr: u32, node: ?*Node, filetype: Filetype) void {
    var b: [64]u8 = @splat(0);
    if (node) |n| {
        std.mem.writeInt(u64, b[8..16], n.ino, .little);
        std.mem.writeInt(u64, b[24..32], 1, .little);
        std.mem.writeInt(u64, b[32..40], if (n.kind == .file) n.data.items.len else 0, .little);
        std.mem.writeInt(u64, b[40..48], n.mtime, .little);
        std.mem.writeInt(u64, b[48..56], n.mtime, .little);
        std.mem.writeInt(u64, b[56..64], n.mtime, .little);
    }
    b[16] = @intFromEnum(filetype);
    writeMem(p, ptr, &b);
}

fn nodeType(n: *Node) Filetype {
    return if (n.kind == .dir) .directory else .regular_file;
}

// --- Host functions ---

const all_rights: u64 = std.math.maxInt(u64);

fn proc() *Process {
    return current.?;
}

fn ret(e: Errno) u32 {
    return @intFromEnum(e);
}

fn sizesGet(list: []const []const u8, count_ptr: u32, size_ptr: u32) u32 {
    const p = proc();
    var size: u32 = 0;
    for (list) |a| size += @intCast(a.len + 1);
    writeInt(p, u32, count_ptr, @intCast(list.len));
    writeInt(p, u32, size_ptr, size);
    return 0;
}

fn listGet(list: []const []const u8, ptrs: u32, buf: u32) u32 {
    const p = proc();
    var off = buf;
    for (list, 0..) |a, i| {
        writeInt(p, u32, ptrs + @as(u32, @intCast(i)) * 4, off);
        writeMem(p, off, a);
        writeMem(p, off + @as(u32, @intCast(a.len)), &.{0});
        off += @intCast(a.len + 1);
    }
    return 0;
}

const host = struct {
    pub fn args_sizes_get(count: u32, size: u32) callconv(.c) u32 {
        return sizesGet(proc().args, count, size);
    }
    pub fn args_get(argv: u32, buf: u32) callconv(.c) u32 {
        return listGet(proc().args, argv, buf);
    }
    pub fn environ_sizes_get(count: u32, size: u32) callconv(.c) u32 {
        return sizesGet(proc().env, count, size);
    }
    pub fn environ_get(env: u32, buf: u32) callconv(.c) u32 {
        return listGet(proc().env, env, buf);
    }
    pub fn clock_res_get(_: u32, out: u32) callconv(.c) u32 {
        writeInt(proc(), u64, out, std.time.ns_per_ms);
        return 0;
    }
    pub fn clock_time_get(id: u32, _: u64, out: u32) callconv(.c) u32 {
        writeInt(proc(), u64, out, if (id == 0) now() else monotonic());
        return 0;
    }
    pub fn fd_advise(_: u32, _: u64, _: u64, _: u32) callconv(.c) u32 {
        return 0;
    }
    pub fn fd_allocate(_: u32, _: u64, _: u64) callconv(.c) u32 {
        return 0;
    }
    pub fn fd_close(fd: u32) callconv(.c) u32 {
        const p = proc();
        if (fd >= p.fds.items.len or p.fds.items[fd] == null) return ret(.badf);
        p.fds.items[fd] = null;
        return 0;
    }
    pub fn fd_datasync(_: u32) callconv(.c) u32 {
        return 0;
    }
    pub fn fd_fdstat_get(fd: u32, out: u32) callconv(.c) u32 {
        const p = proc();
        if (fd >= p.fds.items.len) return ret(.badf);
        const f = p.fds.items[fd] orelse return ret(.badf);
        var b: [24]u8 = @splat(0);
        b[0] = @intFromEnum(switch (f) {
            .stdin, .out => Filetype.character_device,
            .node => |n| nodeType(n.node),
        });
        if (f == .node and f.node.append) b[2] = 1;
        std.mem.writeInt(u64, b[8..16], all_rights, .little);
        std.mem.writeInt(u64, b[16..24], all_rights, .little);
        writeMem(p, out, &b);
        return 0;
    }
    pub fn fd_fdstat_set_flags(_: u32, _: u32) callconv(.c) u32 {
        return 0;
    }
    pub fn fd_fdstat_set_rights(_: u32, _: u64, _: u64) callconv(.c) u32 {
        return 0;
    }
    pub fn fd_filestat_get(fd: u32, out: u32) callconv(.c) u32 {
        const p = proc();
        if (fd >= p.fds.items.len) return ret(.badf);
        const f = p.fds.items[fd] orelse return ret(.badf);
        switch (f) {
            .node => |n| writeFilestat(p, out, n.node, nodeType(n.node)),
            else => writeFilestat(p, out, null, .character_device),
        }
        return 0;
    }
    pub fn fd_filestat_set_size(fd: u32, size: u64) callconv(.c) u32 {
        const n = fileNode(fd) orelse return ret(.badf);
        n.data.resize(n.alloc, @intCast(size)) catch return ret(.io);
        n.mtime = now();
        return 0;
    }
    pub fn fd_filestat_set_times(_: u32, _: u64, _: u64, _: u32) callconv(.c) u32 {
        return 0;
    }
    pub fn fd_pread(fd: u32, iovs: u32, n_iovs: u32, offset: u64, out: u32) callconv(.c) u32 {
        const n = fileNode(fd) orelse return ret(.badf);
        var pos = offset;
        const e = readInto(proc(), n, iovs, n_iovs, &pos);
        if (e != .success) return ret(e);
        writeInt(proc(), u32, out, @intCast(pos - offset));
        return 0;
    }
    pub fn fd_prestat_get(fd: u32, out: u32) callconv(.c) u32 {
        const p = proc();
        if (fd >= p.fds.items.len) return ret(.badf);
        const f = p.fds.items[fd] orelse return ret(.badf);
        if (f != .node or f.node.preopen == null) return ret(.badf);
        var b: [8]u8 = @splat(0);
        std.mem.writeInt(u32, b[4..8], @intCast(f.node.preopen.?.len), .little);
        writeMem(p, out, &b);
        return 0;
    }
    pub fn fd_prestat_dir_name(fd: u32, ptr: u32, len: u32) callconv(.c) u32 {
        const p = proc();
        if (fd >= p.fds.items.len) return ret(.badf);
        const f = p.fds.items[fd] orelse return ret(.badf);
        if (f != .node or f.node.preopen == null) return ret(.badf);
        const name = f.node.preopen.?;
        writeMem(p, ptr, name[0..@min(name.len, len)]);
        return 0;
    }
    pub fn fd_pwrite(fd: u32, iovs: u32, n_iovs: u32, offset: u64, out: u32) callconv(.c) u32 {
        const p = proc();
        if (fd < p.fds.items.len) if (p.fds.items[fd]) |f| if (f != .node) return ret(.spipe);
        const n = fileNode(fd) orelse return ret(.badf);
        var pos = offset;
        const e = writeFrom(p, n, iovs, n_iovs, &pos);
        if (e != .success) return ret(e);
        writeInt(p, u32, out, @intCast(pos - offset));
        return 0;
    }
    pub fn fd_read(fd: u32, iovs: u32, n_iovs: u32, out: u32) callconv(.c) u32 {
        const p = proc();
        if (fd >= p.fds.items.len) return ret(.badf);
        const f = &(p.fds.items[fd] orelse return ret(.badf));
        switch (f.*) {
            .stdin => {
                const vs = readIovs(p, iovs, n_iovs) catch return ret(.io);
                defer gpa.free(vs);
                var total: u32 = 0;
                for (vs) |v| {
                    const rest = p.stdin[p.stdin_pos..];
                    const take = @min(rest.len, v.len);
                    writeMem(p, v.ptr, rest[0..take]);
                    p.stdin_pos += take;
                    total += @intCast(take);
                    if (take < v.len) break;
                }
                writeInt(p, u32, out, total);
                return 0;
            },
            .out => return ret(.badf),
            .node => |*n| {
                if (n.node.kind == .dir) return ret(.isdir);
                const start = n.offset;
                const e = readInto(p, n.node, iovs, n_iovs, &n.offset);
                if (e != .success) return ret(e);
                writeInt(p, u32, out, @intCast(n.offset - start));
                return 0;
            },
        }
    }
    pub fn fd_readdir(fd: u32, buf: u32, buf_len: u32, cookie: u64, out: u32) callconv(.c) u32 {
        const p = proc();
        const dir = dirNode(p, fd) orelse return ret(.notdir);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        var i: usize = @intCast(cookie);
        const keys = dir.children.keys();
        const values = dir.children.values();
        while (i < keys.len and bytes.items.len < buf_len) : (i += 1) {
            var head: [24]u8 = @splat(0);
            std.mem.writeInt(u64, head[0..8], i + 1, .little);
            std.mem.writeInt(u64, head[8..16], values[i].ino, .little);
            std.mem.writeInt(u32, head[16..20], @intCast(keys[i].len), .little);
            head[20] = @intFromEnum(nodeType(values[i]));
            bytes.appendSlice(gpa, &head) catch return ret(.io);
            bytes.appendSlice(gpa, keys[i]) catch return ret(.io);
        }
        const used = @min(bytes.items.len, buf_len);
        writeMem(p, buf, bytes.items[0..used]);
        writeInt(p, u32, out, @intCast(used));
        return 0;
    }
    pub fn fd_renumber(from: u32, to: u32) callconv(.c) u32 {
        const p = proc();
        if (from >= p.fds.items.len or to >= p.fds.items.len) return ret(.badf);
        p.fds.items[to] = p.fds.items[from];
        p.fds.items[from] = null;
        return 0;
    }
    pub fn fd_seek(fd: u32, offset: i64, whence: u32, out: u32) callconv(.c) u32 {
        const p = proc();
        if (fd >= p.fds.items.len) return ret(.badf);
        const f = &(p.fds.items[fd] orelse return ret(.badf));
        if (f.* != .node) return ret(.spipe);
        const n = &f.node;
        const base: i64 = switch (whence) {
            0 => 0,
            1 => @intCast(n.offset),
            2 => @intCast(n.node.data.items.len),
            else => return ret(.inval),
        };
        const pos = base + offset;
        if (pos < 0) return ret(.inval);
        n.offset = @intCast(pos);
        writeInt(p, u64, out, n.offset);
        return 0;
    }
    pub fn fd_sync(_: u32) callconv(.c) u32 {
        return 0;
    }
    pub fn fd_tell(fd: u32, out: u32) callconv(.c) u32 {
        const p = proc();
        if (fd >= p.fds.items.len) return ret(.badf);
        const f = p.fds.items[fd] orelse return ret(.badf);
        if (f != .node) return ret(.spipe);
        writeInt(p, u64, out, f.node.offset);
        return 0;
    }
    pub fn fd_write(fd: u32, iovs: u32, n_iovs: u32, out: u32) callconv(.c) u32 {
        const p = proc();
        if (fd >= p.fds.items.len) return ret(.badf);
        const f = &(p.fds.items[fd] orelse return ret(.badf));
        switch (f.*) {
            .stdin => return ret(.badf),
            .out => |which| {
                const vs = readIovs(p, iovs, n_iovs) catch return ret(.io);
                defer gpa.free(vs);
                const sink = &p.out[if (p.merge_output) 0 else which];
                var total: u32 = 0;
                for (vs) |v| {
                    const old = sink.items.len;
                    sink.resize(gpa, old + v.len) catch return ret(.io);
                    readMem(p, v.ptr, sink.items[old..]);
                    total += v.len;
                }
                writeInt(p, u32, out, total);
                return 0;
            },
            .node => |*n| {
                if (n.node.kind == .dir) return ret(.isdir);
                if (n.append) n.offset = n.node.data.items.len;
                const start = n.offset;
                const e = writeFrom(p, n.node, iovs, n_iovs, &n.offset);
                if (e != .success) return ret(e);
                writeInt(p, u32, out, @intCast(n.offset - start));
                return 0;
            },
        }
    }
    pub fn path_create_directory(fd: u32, path: u32, len: u32) callconv(.c) u32 {
        const p = proc();
        const base = dirNode(p, fd) orelse return ret(.notdir);
        const name = readPath(p, path, len) catch return ret(.io);
        defer gpa.free(name);
        const r = resolve(base, name) catch |e| return ret(errnoOf(e));
        if (r.node != null) return ret(.exist);
        r.parent.put(r.name, Node.newDir(r.parent.alloc) catch return ret(.io)) catch return ret(.io);
        return 0;
    }
    pub fn path_filestat_get(fd: u32, _: u32, path: u32, len: u32, out: u32) callconv(.c) u32 {
        const p = proc();
        const base = dirNode(p, fd) orelse return ret(.notdir);
        const name = readPath(p, path, len) catch return ret(.io);
        defer gpa.free(name);
        const r = resolve(base, name) catch |e| return ret(errnoOf(e));
        const n = r.node orelse return ret(.noent);
        writeFilestat(p, out, n, nodeType(n));
        return 0;
    }
    pub fn path_filestat_set_times(_: u32, _: u32, _: u32, _: u32, _: u64, _: u64, _: u32) callconv(.c) u32 {
        return 0;
    }
    pub fn path_link(_: u32, _: u32, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) u32 {
        return ret(.nosys);
    }
    pub fn path_open(
        fd: u32,
        _: u32,
        path: u32,
        len: u32,
        oflags: u32,
        _: u64,
        _: u64,
        fdflags: u32,
        out: u32,
    ) callconv(.c) u32 {
        const p = proc();
        const base = dirNode(p, fd) orelse return ret(.notdir);
        const name = readPath(p, path, len) catch return ret(.io);
        defer gpa.free(name);
        const r = resolve(base, name) catch |e| return ret(errnoOf(e));
        const creat = oflags & 1 != 0;
        const directory = oflags & 2 != 0;
        const excl = oflags & 4 != 0;
        const trunc = oflags & 8 != 0;

        const node = if (r.node) |n| blk: {
            if (creat and excl) return ret(.exist);
            if (directory and n.kind != .dir) return ret(.notdir);
            if (trunc and n.kind == .file) n.data.clearRetainingCapacity();
            break :blk n;
        } else blk: {
            if (!creat) return ret(.noent);
            if (directory) return ret(.noent);
            const n = Node.newFile(r.parent.alloc, "") catch return ret(.io);
            r.parent.put(r.name, n) catch return ret(.io);
            break :blk n;
        };
        const new_fd = for (p.fds.items, 0..) |slot, i| {
            if (i > 2 and slot == null) break i;
        } else blk: {
            p.fds.append(gpa, null) catch return ret(.io);
            break :blk p.fds.items.len - 1;
        };
        p.fds.items[new_fd] = .{ .node = .{ .node = node, .append = fdflags & 1 != 0 } };
        writeInt(p, u32, out, @intCast(new_fd));
        return 0;
    }
    pub fn path_readlink(_: u32, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) u32 {
        return ret(.inval);
    }
    pub fn path_remove_directory(fd: u32, path: u32, len: u32) callconv(.c) u32 {
        return remove(fd, path, len, .dir);
    }
    pub fn path_rename(fd: u32, old: u32, old_len: u32, new_fd: u32, new: u32, new_len: u32) callconv(.c) u32 {
        const p = proc();
        const from_base = dirNode(p, fd) orelse return ret(.notdir);
        const to_base = dirNode(p, new_fd) orelse return ret(.notdir);
        const from_name = readPath(p, old, old_len) catch return ret(.io);
        defer gpa.free(from_name);
        const to_name = readPath(p, new, new_len) catch return ret(.io);
        defer gpa.free(to_name);
        const from = resolve(from_base, from_name) catch |e| return ret(errnoOf(e));
        const node = from.node orelse return ret(.noent);
        const to = resolve(to_base, to_name) catch |e| return ret(errnoOf(e));
        if (to.node) |existing| {
            if (existing == node) return 0;
            if (existing.kind == .dir and existing.children.count() > 0) return ret(.notempty);
        }
        _ = from.parent.children.orderedRemove(from.name);
        to.parent.put(to.name, node) catch return ret(.io);
        return 0;
    }
    pub fn path_symlink(_: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) u32 {
        return ret(.nosys);
    }
    pub fn path_unlink_file(fd: u32, path: u32, len: u32) callconv(.c) u32 {
        return remove(fd, path, len, .file);
    }
    pub fn poll_oneoff(in: u32, out: u32, n: u32, out_n: u32) callconv(.c) u32 {
        // Single-threaded and nothing blocks: every subscription is ready now.
        const p = proc();
        for (0..n) |i| {
            const sub = in + @as(u32, @intCast(i)) * 48;
            var ev: [32]u8 = @splat(0);
            readMem(p, sub, ev[0..8]);
            var tag: [1]u8 = undefined;
            readMem(p, sub + 8, &tag);
            ev[10] = tag[0];
            writeMem(p, out + @as(u32, @intCast(i)) * 32, &ev);
        }
        writeInt(p, u32, out_n, n);
        return 0;
    }
    pub fn proc_exit(code: u32) callconv(.c) void {
        current.?.exit_code = code;
        @trap();
    }
    pub fn proc_raise(_: u32) callconv(.c) u32 {
        return ret(.nosys);
    }
    pub fn random_get(ptr: u32, len: u32) callconv(.c) u32 {
        const p = proc();
        if (prng == null) prng = .init(monotonic() ^ now());
        const buf = gpa.alloc(u8, len) catch return ret(.io);
        defer gpa.free(buf);
        prng.?.random().bytes(buf);
        writeMem(p, ptr, buf);
        return 0;
    }
    pub fn sched_yield() callconv(.c) u32 {
        return 0;
    }
    pub fn sock_accept(_: u32, _: u32, _: u32) callconv(.c) u32 {
        return ret(.nosys);
    }
    pub fn sock_recv(_: u32, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) u32 {
        return ret(.nosys);
    }
    pub fn sock_send(_: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) u32 {
        return ret(.nosys);
    }
    pub fn sock_shutdown(_: u32, _: u32) callconv(.c) u32 {
        return ret(.nosys);
    }
};

fn fileNode(fd: u32) ?*Node {
    const p = proc();
    if (fd >= p.fds.items.len) return null;
    const f = p.fds.items[fd] orelse return null;
    return switch (f) {
        .node => |n| if (n.node.kind == .file) n.node else null,
        else => null,
    };
}

fn readInto(p: *Process, n: *Node, iovs: u32, n_iovs: u32, pos: *u64) Errno {
    const vs = readIovs(p, iovs, n_iovs) catch return .io;
    defer gpa.free(vs);
    for (vs) |v| {
        const data = n.data.items;
        if (pos.* >= data.len) break;
        const start: usize = @intCast(pos.*);
        const take = @min(data.len - start, v.len);
        writeMem(p, v.ptr, data[start..][0..take]);
        pos.* += take;
        if (take < v.len) break;
    }
    return .success;
}

fn writeFrom(p: *Process, n: *Node, iovs: u32, n_iovs: u32, pos: *u64) Errno {
    const vs = readIovs(p, iovs, n_iovs) catch return .io;
    defer gpa.free(vs);
    for (vs) |v| {
        const start: usize = @intCast(pos.*);
        const end = start + v.len;
        if (end > n.data.items.len) {
            const old = n.data.items.len;
            n.data.resize(n.alloc, end) catch return .io;
            if (start > old) @memset(n.data.items[old..start], 0);
        }
        readMem(p, v.ptr, n.data.items[start..end]);
        pos.* = end;
    }
    n.mtime = now();
    return .success;
}

fn remove(fd: u32, path: u32, len: u32, kind: Node.Kind) u32 {
    const p = proc();
    const base = dirNode(p, fd) orelse return ret(.notdir);
    const name = readPath(p, path, len) catch return ret(.io);
    defer gpa.free(name);
    const r = resolve(base, name) catch |e| return ret(errnoOf(e));
    const n = r.node orelse return ret(.noent);
    if (kind == .dir) {
        if (n.kind != .dir) return ret(.notdir);
        if (n.children.count() > 0) return ret(.notempty);
    } else if (n.kind == .dir) return ret(.isdir);
    _ = r.parent.children.orderedRemove(r.name);
    return 0;
}

/// Copies guest memory of the running process (for host imports outside this file).
pub fn readGuest(a: std.mem.Allocator, ptr: u32, len: u32) ![]u8 {
    const p = current orelse return error.NoProcess;
    const buf = try a.alloc(u8, len);
    readMem(p, ptr, buf);
    return buf;
}

// Only the worker wasm hosts guests; the page and server just see the types.
comptime {
    if (@hasDecl(@import("root"), "zx_worker")) for (@typeInfo(host).@"struct".decl_names) |name| {
        @export(&@field(host, name), .{ .name = "pgwasi_" ++ name });
    };
}
