// Browser file system for `Io.Web`: sync ops against the host's OPFS mirror (runtime/fs.ts).
const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const host = @import("../../../wasm/imports.zig");

pub const root: Dir = .{ .handle = 3 };

pub fn cwd() Dir {
    return root;
}

pub fn install(vt: *Io.VTable) void {
    vt.operate = &operate;
    vt.dirCreateDir = &dirCreateDir;
    vt.dirCreateDirPath = &dirCreateDirPath;
    vt.dirCreateDirPathOpen = &dirCreateDirPathOpen;
    vt.dirOpenDir = &dirOpenDir;
    vt.dirStat = &dirStat;
    vt.dirStatFile = &dirStatFile;
    vt.dirAccess = &dirAccess;
    vt.dirCreateFile = &dirCreateFile;
    vt.dirCreateFileAtomic = &dirCreateFileAtomic;
    vt.dirOpenFile = &dirOpenFile;
    vt.dirClose = &dirClose;
    vt.dirRead = &dirRead;
    vt.dirDeleteFile = &dirDeleteFile;
    vt.dirDeleteDir = &dirDeleteDir;
    vt.dirRename = &dirRename;
    vt.dirRenamePreserve = &dirRenamePreserve;
    vt.fileStat = &fileStat;
    vt.fileLength = &fileLength;
    vt.fileClose = &fileClose;
    vt.fileWritePositional = &fileWritePositional;
    vt.fileReadPositional = &fileReadPositional;
    vt.fileSeekBy = &fileSeekBy;
    vt.fileSeekTo = &fileSeekTo;
    vt.fileSync = &fileSync;
    vt.fileSetLength = &fileSetLength;
}

// Mirrored in fs.ts.
const open_read: u32 = 1;
const open_write: u32 = 2;
const open_create: u32 = 4;
const open_exclusive: u32 = 8;
const open_truncate: u32 = 16;
const open_directory: u32 = 32;
const open_allow_directory: u32 = 64;

// Written by `fs_stat`; mirrored in fs.ts.
const Stat = extern struct {
    kind: u32,
    _pad: u32 = 0,
    size: u64,
    mtime_ns: i64,

    fn toFile(s: Stat) File.Stat {
        const mtime: Io.Timestamp = .{ .nanoseconds = s.mtime_ns };
        return .{
            .inode = 0,
            .nlink = 0,
            .size = s.size,
            .permissions = .default_file,
            .kind = if (s.kind == 1) .directory else .file,
            .atime = null,
            .mtime = mtime,
            .ctime = mtime,
            .block_size = 4096,
        };
    }
};

// Negative host results are POSIX errnos.
fn fail(comptime E: type, rc: i32) E {
    const names: []const []const u8 = switch (rc) {
        -2 => &.{"FileNotFound"},
        -9 => &.{ "NotOpenForReading", "NotOpenForWriting" },
        -13 => &.{"AccessDenied"},
        -17 => &.{"PathAlreadyExists"},
        -20 => &.{"NotDir"},
        -21 => &.{"IsDir"},
        -22 => &.{"Unseekable"},
        -28 => &.{ "NoSpaceLeft", "DiskQuota" },
        -39 => &.{"DirNotEmpty"},
        host.unsupported => &.{ "NoDevice", "SystemResources" },
        else => &.{},
    };
    for (names) |name| {
        inline for (@typeInfo(E).error_set.error_names.?) |e| {
            if (std.mem.eql(u8, e, name)) return @field(E, e);
        }
    }
    return error.Unexpected;
}

fn open(comptime E: type, dir: Dir, sub_path: []const u8, flags: u32) E!i32 {
    const rc = host.call(.fs_open, .{ dir.handle, sub_path, flags });
    return if (rc < 0) fail(E, rc) else rc;
}

fn statAt(comptime E: type, fd: i32, sub_path: []const u8) E!File.Stat {
    var s: Stat = undefined;
    const rc = host.call(.fs_stat, .{ fd, sub_path, &s });
    return if (rc < 0) fail(E, rc) else s.toFile();
}

fn dirCreateDir(_: ?*anyopaque, dir: Dir, sub_path: []const u8, _: Dir.Permissions) Dir.CreateDirError!void {
    const rc = host.call(.fs_mkdir, .{ dir.handle, sub_path, false });
    if (rc < 0) return fail(Dir.CreateDirError, rc);
}

fn dirCreateDirPath(_: ?*anyopaque, dir: Dir, sub_path: []const u8, _: Dir.Permissions) Dir.CreateDirPathError!Dir.CreatePathStatus {
    const rc = host.call(.fs_mkdir, .{ dir.handle, sub_path, true });
    if (rc < 0) return fail(Dir.CreateDirPathError, rc);
    return if (rc == 1) .existed else .created;
}

fn dirCreateDirPathOpen(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
    options: Dir.OpenOptions,
) Dir.CreateDirPathOpenError!Dir {
    _ = try dirCreateDirPath(userdata, dir, sub_path, permissions);
    return dirOpenDir(userdata, dir, sub_path, options);
}

fn dirOpenDir(_: ?*anyopaque, dir: Dir, sub_path: []const u8, _: Dir.OpenOptions) Dir.OpenError!Dir {
    return .{ .handle = try open(Dir.OpenError, dir, sub_path, open_read | open_directory) };
}

fn dirStat(_: ?*anyopaque, dir: Dir) Dir.StatError!Dir.Stat {
    return statAt(Dir.StatError, dir.handle, "");
}

fn dirStatFile(_: ?*anyopaque, dir: Dir, sub_path: []const u8, _: Dir.StatFileOptions) Dir.StatFileError!File.Stat {
    if (sub_path.len == 0) return error.FileNotFound;
    return statAt(Dir.StatFileError, dir.handle, sub_path);
}

fn dirAccess(_: ?*anyopaque, dir: Dir, sub_path: []const u8, _: Dir.AccessOptions) Dir.AccessError!void {
    if (sub_path.len == 0) return error.FileNotFound;
    _ = try statAt(Dir.AccessError, dir.handle, sub_path);
}

fn dirCreateFile(_: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.CreateFileOptions) File.OpenError!File {
    var flags = open_write | open_create;
    if (options.read) flags |= open_read;
    if (options.truncate) flags |= open_truncate;
    if (options.exclusive) flags |= open_exclusive;
    return .{ .handle = try open(File.OpenError, dir, sub_path, flags), .flags = .{ .nonblocking = false } };
}

fn dirOpenFile(_: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.OpenFileOptions) File.OpenError!File {
    var flags: u32 = switch (options.mode) {
        .read_only => open_read,
        .write_only => open_write,
        .read_write => open_read | open_write,
    };
    if (options.allow_directory) flags |= open_allow_directory;
    return .{ .handle = try open(File.OpenError, dir, sub_path, flags), .flags = .{ .nonblocking = false } };
}

fn dirCreateFileAtomic(
    userdata: ?*anyopaque,
    dir: Dir,
    dest_path: []const u8,
    options: Dir.CreateFileAtomicOptions,
) Dir.CreateFileAtomicError!File.Atomic {
    var parent = dir;
    var close_parent = false;
    if (Dir.path.dirname(dest_path)) |dirname| {
        parent = if (options.make_path)
            dirCreateDirPathOpen(userdata, dir, dirname, .default_dir, .{}) catch |err| return switch (err) {
                error.FileNotFound, error.NotDir, error.AccessDenied, error.NoSpaceLeft => |e| e,
                else => error.Unexpected,
            }
        else
            dirOpenDir(userdata, dir, dirname, .{}) catch |err| return switch (err) {
                error.FileNotFound, error.NotDir, error.AccessDenied => |e| e,
                else => error.Unexpected,
            };
        close_parent = true;
    }
    errdefer if (close_parent) dirClose(userdata, &.{parent});

    while (true) {
        var random: u64 = undefined;
        Io.random(webIo(), std.mem.asBytes(&random));
        const tmp = std.fmt.hex(random);
        const file = dirCreateFile(userdata, parent, &tmp, .{ .read = true, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            error.FileNotFound, error.NotDir, error.AccessDenied, error.NoSpaceLeft => |e| return e,
            else => return error.Unexpected,
        };
        return .{
            .file = file,
            .file_basename_hex = random,
            .file_open = true,
            .file_exists = true,
            .dir = parent,
            .close_dir_on_deinit = close_parent,
            .dest_sub_path = Dir.path.basename(dest_path),
        };
    }
}

fn webIo() Io {
    return @import("../Web.zig").io();
}

fn dirClose(_: ?*anyopaque, dirs: []const Dir) void {
    for (dirs) |dir| _ = host.call(.fs_close, .{dir.handle});
}

// Host packs entries into `r.buffer` as `[kind: u8][len: u16 le][name]`.
fn dirRead(_: ?*anyopaque, r: *Dir.Reader, entries: []Dir.Entry) Dir.Reader.Error!usize {
    var n: usize = 0;
    while (n < entries.len) {
        if (r.index >= r.end) {
            if (r.state == .finished) break;
            const reset = r.state == .reset;
            r.state = .reading;
            const rc = host.call(.fs_readdir, .{ r.dir.handle, reset, r.buffer });
            if (rc < 0) return fail(Dir.Reader.Error, rc);
            r.index = 0;
            r.end = @intCast(rc);
            if (rc == 0) {
                r.state = .finished;
                break;
            }
        }
        const rec = r.buffer[r.index..r.end];
        const len = std.mem.readInt(u16, rec[1..3], .little);
        entries[n] = .{
            .name = rec[3..][0..len],
            .kind = if (rec[0] == 1) .directory else .file,
            .inode = 0,
        };
        r.index += 3 + len;
        n += 1;
    }
    return n;
}

fn dirDeleteFile(_: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteFileError!void {
    const rc = host.call(.fs_remove, .{ dir.handle, sub_path, false });
    if (rc < 0) return fail(Dir.DeleteFileError, rc);
}

fn dirDeleteDir(_: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteDirError!void {
    const rc = host.call(.fs_remove, .{ dir.handle, sub_path, true });
    if (rc < 0) return fail(Dir.DeleteDirError, rc);
}

fn dirRename(_: ?*anyopaque, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) Dir.RenameError!void {
    const rc = host.call(.fs_rename, .{ old_dir.handle, old_sub_path, new_dir.handle, new_sub_path, true });
    if (rc < 0) return fail(Dir.RenameError, rc);
}

fn dirRenamePreserve(_: ?*anyopaque, old_dir: Dir, old_sub_path: []const u8, new_dir: Dir, new_sub_path: []const u8) Dir.RenamePreserveError!void {
    const rc = host.call(.fs_rename, .{ old_dir.handle, old_sub_path, new_dir.handle, new_sub_path, false });
    if (rc < 0) return fail(Dir.RenamePreserveError, rc);
}

fn fileStat(_: ?*anyopaque, file: File) File.StatError!File.Stat {
    return statAt(File.StatError, file.handle, "");
}

fn fileLength(_: ?*anyopaque, file: File) File.LengthError!u64 {
    return (try statAt(File.LengthError, file.handle, "")).size;
}

fn fileClose(_: ?*anyopaque, files: []const File) void {
    for (files) |file| _ = host.call(.fs_close, .{file.handle});
}

// `offset` null writes at the file position.
fn writeAll(comptime E: type, fd: i32, header: []const u8, data: []const []const u8, splat: usize, offset: ?u64) E!usize {
    var total: usize = 0;
    const put = struct {
        fn put(comptime Err: type, f: i32, bytes: []const u8, at: ?u64, sum: *usize) Err!void {
            if (bytes.len == 0) return;
            const pos: i64 = if (at) |o| @intCast(o + sum.*) else -1;
            const rc = host.call(.fs_write, .{ f, bytes, pos });
            if (rc < 0) return fail(Err, rc);
            sum.* += @intCast(rc);
        }
    }.put;
    try put(E, fd, header, offset, &total);
    if (data.len == 0) return total;
    for (data[0 .. data.len - 1]) |bytes| try put(E, fd, bytes, offset, &total);
    for (0..splat) |_| try put(E, fd, data[data.len - 1], offset, &total);
    return total;
}

fn fileWritePositional(
    _: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) File.WritePositionalError!usize {
    return writeAll(File.WritePositionalError, file.handle, header, data, splat, offset);
}

// `offset` null reads at the file position.
fn readAll(comptime E: type, fd: i32, data: []const []u8, offset: ?u64) E!usize {
    var total: usize = 0;
    for (data) |buf| {
        if (buf.len == 0) continue;
        const pos: i64 = if (offset) |o| @intCast(o + total) else -1;
        const rc = host.call(.fs_read, .{ fd, buf, pos });
        if (rc < 0) return fail(E, rc);
        const n: usize = @intCast(rc);
        total += n;
        if (n < buf.len) break;
    }
    return total;
}

fn fileReadPositional(_: ?*anyopaque, file: File, data: []const []u8, offset: u64) File.ReadPositionalError!usize {
    return readAll(File.ReadPositionalError, file.handle, data, offset);
}

fn seek(fd: i32, offset: i64, whence: u32) File.SeekError!void {
    const rc = host.call(.fs_seek, .{ fd, offset, whence });
    if (rc < 0) return fail(File.SeekError, rc);
}

fn fileSeekBy(_: ?*anyopaque, file: File, relative_offset: i64) File.SeekError!void {
    return seek(file.handle, relative_offset, 1);
}

fn fileSeekTo(_: ?*anyopaque, file: File, absolute_offset: u64) File.SeekError!void {
    return seek(file.handle, @intCast(absolute_offset), 0);
}

// Only starts persisting: waiting for OPFS would suspend.
fn fileSync(_: ?*anyopaque, file: File) File.SyncError!void {
    const rc = host.call(.fs_sync, .{file.handle});
    if (rc < 0) return fail(File.SyncError, rc);
}

fn fileSetLength(_: ?*anyopaque, file: File, length: u64) File.SetLengthError!void {
    const rc = host.call(.fs_set_len, .{ file.handle, @as(i64, @intCast(length)) });
    if (rc < 0) return fail(File.SetLengthError, rc);
}

fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => |op| .{ .file_read_streaming = readStreaming(op) },
        .file_write_streaming => |op| .{
            .file_write_streaming = writeAll(Io.Operation.FileWriteStreaming.Error, op.file.handle, op.header, op.data, op.splat, null),
        },
        else => Io.failingOperate(userdata, operation),
    };
}

fn readStreaming(op: Io.Operation.FileReadStreaming) Io.Operation.FileReadStreaming.Error!usize {
    const n = try readAll(Io.Operation.FileReadStreaming.Error, op.file.handle, op.data, null);
    if (n == 0) for (op.data) |buf| {
        if (buf.len > 0) return error.EndOfStream;
    };
    return n;
}
