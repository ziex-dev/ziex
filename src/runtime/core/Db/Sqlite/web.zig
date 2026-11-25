// SQLite in the browser: a VFS over `Io.Web` files (OPFS).
// sqlite3.c is built with SQLITE_OS_OTHER (pkg/db-sqlite/build.zig), so it calls
// `sqlite3_os_init` to register this VFS.
const std = @import("std");
const c = @import("sqlite");
const Web = @import("../../Io/Web.zig");

const io = Web.io();
const File = std.Io.File;

// Locking is a no-op: one thread, and tabs don't share the file system mirror.
const WebFile = extern struct {
    base: c.sqlite3_file,
    fd: i32,
    // Set for SQLITE_OPEN_DELETEONCLOSE; sqlite keeps the name alive until xClose.
    delete_name: ?[*:0]const u8,

    fn file(w: *const WebFile) File {
        return .{ .handle = w.fd, .flags = .{ .nonblocking = false } };
    }
};

fn webFile(f: [*c]c.sqlite3_file) *WebFile {
    return @ptrCast(@alignCast(f));
}

fn xClose(f: [*c]c.sqlite3_file) callconv(.c) c_int {
    const w = webFile(f);
    w.file().close(io);
    if (w.delete_name) |name| std.Io.Dir.cwd().deleteFile(io, std.mem.span(name)) catch {};
    return c.SQLITE_OK;
}

fn xRead(f: [*c]c.sqlite3_file, buf: ?*anyopaque, amt: c_int, offset: c.sqlite3_int64) callconv(.c) c_int {
    const out = @as([*]u8, @ptrCast(buf.?))[0..@intCast(amt)];
    const n = webFile(f).file().readPositionalAll(io, out, @intCast(offset)) catch return c.SQLITE_IOERR_READ;
    if (n == out.len) return c.SQLITE_OK;
    // sqlite requires the unread tail zeroed.
    @memset(out[n..], 0);
    return c.SQLITE_IOERR_SHORT_READ;
}

fn xWrite(f: [*c]c.sqlite3_file, buf: ?*const anyopaque, amt: c_int, offset: c.sqlite3_int64) callconv(.c) c_int {
    const in = @as([*]const u8, @ptrCast(buf.?))[0..@intCast(amt)];
    webFile(f).file().writePositionalAll(io, in, @intCast(offset)) catch return c.SQLITE_IOERR_WRITE;
    return c.SQLITE_OK;
}

fn xTruncate(f: [*c]c.sqlite3_file, size: c.sqlite3_int64) callconv(.c) c_int {
    webFile(f).file().setLength(io, @intCast(size)) catch return c.SQLITE_IOERR_TRUNCATE;
    return c.SQLITE_OK;
}

fn xSync(f: [*c]c.sqlite3_file, _: c_int) callconv(.c) c_int {
    webFile(f).file().sync(io) catch return c.SQLITE_IOERR_FSYNC;
    return c.SQLITE_OK;
}

fn xFileSize(f: [*c]c.sqlite3_file, out: [*c]c.sqlite3_int64) callconv(.c) c_int {
    out.* = @intCast(webFile(f).file().length(io) catch return c.SQLITE_IOERR_FSTAT);
    return c.SQLITE_OK;
}

fn xLock(_: [*c]c.sqlite3_file, _: c_int) callconv(.c) c_int {
    return c.SQLITE_OK;
}

fn xCheckReservedLock(_: [*c]c.sqlite3_file, out: [*c]c_int) callconv(.c) c_int {
    out.* = 0;
    return c.SQLITE_OK;
}

fn xFileControl(_: [*c]c.sqlite3_file, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    return c.SQLITE_NOTFOUND;
}

fn xSectorSize(_: [*c]c.sqlite3_file) callconv(.c) c_int {
    return 4096;
}

fn xDeviceCharacteristics(_: [*c]c.sqlite3_file) callconv(.c) c_int {
    return 0;
}

const io_methods: c.sqlite3_io_methods = .{
    .iVersion = 1,
    .xClose = xClose,
    .xRead = xRead,
    .xWrite = xWrite,
    .xTruncate = xTruncate,
    .xSync = xSync,
    .xFileSize = xFileSize,
    .xLock = xLock,
    .xUnlock = xLock,
    .xCheckReservedLock = xCheckReservedLock,
    .xFileControl = xFileControl,
    .xSectorSize = xSectorSize,
    .xDeviceCharacteristics = xDeviceCharacteristics,
};

fn xOpen(_: [*c]c.sqlite3_vfs, name: [*c]const u8, f: [*c]c.sqlite3_file, flags: c_int, out_flags: [*c]c_int) callconv(.c) c_int {
    const w = webFile(f);
    w.base.pMethods = null;
    // A null name asks for a temp file; SQLITE_TEMP_STORE=3 keeps those in memory.
    if (name == null) return c.SQLITE_CANTOPEN;
    const path = std.mem.span(name);
    const cwd = std.Io.Dir.cwd();
    const read_only = flags & c.SQLITE_OPEN_READONLY != 0;
    const opened = if (flags & c.SQLITE_OPEN_CREATE != 0)
        cwd.createFile(io, path, .{ .read = true, .truncate = false, .exclusive = flags & c.SQLITE_OPEN_EXCLUSIVE != 0 })
    else
        cwd.openFile(io, path, .{ .mode = if (read_only) .read_only else .read_write });
    const file = opened catch return c.SQLITE_CANTOPEN;
    w.* = .{
        .base = .{ .pMethods = &io_methods },
        .fd = file.handle,
        .delete_name = if (flags & c.SQLITE_OPEN_DELETEONCLOSE != 0) name else null,
    };
    if (out_flags != null) out_flags.* = flags;
    return c.SQLITE_OK;
}

fn xDelete(_: [*c]c.sqlite3_vfs, name: [*c]const u8, _: c_int) callconv(.c) c_int {
    std.Io.Dir.cwd().deleteFile(io, std.mem.span(name)) catch |err| return switch (err) {
        error.FileNotFound => c.SQLITE_IOERR_DELETE_NOENT,
        else => c.SQLITE_IOERR_DELETE,
    };
    return c.SQLITE_OK;
}

fn xAccess(_: [*c]c.sqlite3_vfs, name: [*c]const u8, _: c_int, out: [*c]c_int) callconv(.c) c_int {
    _ = std.Io.Dir.cwd().statFile(io, std.mem.span(name), .{}) catch {
        out.* = 0;
        return c.SQLITE_OK;
    };
    out.* = 1;
    return c.SQLITE_OK;
}

fn xFullPathname(_: [*c]c.sqlite3_vfs, name: [*c]const u8, n_out: c_int, out: [*c]u8) callconv(.c) c_int {
    const path = std.mem.span(name);
    if (path.len + 1 > n_out) return c.SQLITE_CANTOPEN;
    @memcpy(out[0..path.len], path);
    out[path.len] = 0;
    return c.SQLITE_OK;
}

fn xRandomness(_: [*c]c.sqlite3_vfs, n: c_int, out: [*c]u8) callconv(.c) c_int {
    io.random(out[0..@intCast(n)]);
    return n;
}

// Never called without lock contention; sleeping here would block the page.
fn xSleep(_: [*c]c.sqlite3_vfs, us: c_int) callconv(.c) c_int {
    return us;
}

fn xCurrentTimeInt64(_: [*c]c.sqlite3_vfs, out: [*c]c.sqlite3_int64) callconv(.c) c_int {
    // Julian day in ms.
    out.* = std.Io.Timestamp.now(io, .real).toMilliseconds() + 210_866_760_000_000;
    return c.SQLITE_OK;
}

fn xCurrentTime(v: [*c]c.sqlite3_vfs, out: [*c]f64) callconv(.c) c_int {
    var ms: c.sqlite3_int64 = 0;
    _ = xCurrentTimeInt64(v, &ms);
    out.* = @as(f64, @floatFromInt(ms)) / 86_400_000.0;
    return c.SQLITE_OK;
}

fn xGetLastError(_: [*c]c.sqlite3_vfs, _: c_int, _: [*c]u8) callconv(.c) c_int {
    return 0;
}

var vfs: c.sqlite3_vfs = .{
    .iVersion = 2,
    .szOsFile = @sizeOf(WebFile),
    .mxPathname = 1024,
    .zName = "zx-web",
    .xOpen = xOpen,
    .xDelete = xDelete,
    .xAccess = xAccess,
    .xFullPathname = xFullPathname,
    .xRandomness = xRandomness,
    .xSleep = xSleep,
    .xCurrentTime = xCurrentTime,
    .xGetLastError = xGetLastError,
    .xCurrentTimeInt64 = xCurrentTimeInt64,
};

export fn sqlite3_os_init() c_int {
    return c.sqlite3_vfs_register(&vfs, 1);
}

export fn sqlite3_os_end() c_int {
    return c.SQLITE_OK;
}

// libzigc (linked by pkg/db-sqlite) sets it; hidden so it isn't a host export.
var errno: c_int = 0;
comptime {
    @export(&errno, .{ .name = "errno", .visibility = .hidden });
}
