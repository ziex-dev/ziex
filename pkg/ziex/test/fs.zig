// Fixture for fs.test.ts: drives `zx.Io.Web`'s file system through plain std APIs.
// Built from a temp copy of src/runtime (see the test), so it imports by that layout.
const std = @import("std");
const Web = @import("core/Io/Web.zig");

pub const std_options_cwd = Web.cwd;

const io = Web.io();
const Dir = std.Io.Dir;

var err_name: []const u8 = "";
export fn errPtr() [*]const u8 {
    return err_name.ptr;
}
export fn errLen() usize {
    return err_name.len;
}

fn run(comptime f: fn () anyerror!void) i32 {
    f() catch |err| {
        err_name = @errorName(err);
        return 1;
    };
    return 0;
}

fn expectEqual(expected: []const u8, actual: []const u8) !void {
    if (!std.mem.eql(u8, expected, actual)) return error.Mismatch;
}

fn expectError(expected: anyerror, result: anytype) !void {
    if (result) |_| return error.ExpectedError else |err| if (err != expected) return err;
}

/// The same calls `Kv.Fs.put`/`get` make.
fn put(key: []const u8, value: []const u8) !void {
    var file = try Dir.cwd().createFileAtomic(io, key, .{ .make_path = true, .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, "[1,0]\n");
    try file.file.writeStreamingAll(io, value);
    try file.replace(io);
}

fn get(key: []const u8, buf: []u8) ![]u8 {
    var file = try Dir.cwd().openFile(io, key, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, buf, 0);
    if (try file.length(io) != n) return error.LengthMismatch;
    return buf[0..n];
}

export fn atomicRoundtrip() i32 {
    return run(struct {
        fn f() !void {
            var buf: [64]u8 = undefined;
            try put("kv/ns/key", "first");
            try expectEqual("[1,0]\nfirst", try get("kv/ns/key", &buf));
            try put("kv/ns/key", "second, longer");
            try expectEqual("[1,0]\nsecond, longer", try get("kv/ns/key", &buf));
            try Dir.cwd().deleteFile(io, "kv/ns/key");
            try expectError(error.FileNotFound, get("kv/ns/key", &buf));
        }
    }.f);
}

export fn iterate() i32 {
    return run(struct {
        fn f() !void {
            const cwd = Dir.cwd();
            try cwd.createDirPath(io, "list/c");
            (try cwd.createFile(io, "list/b", .{})).close(io);
            (try cwd.createFile(io, "list/a", .{})).close(io);

            var dir = try cwd.openDir(io, "list", .{ .iterate = true });
            defer dir.close(io);
            var names: [8]u8 = undefined;
            var kinds: [8]std.Io.File.Kind = undefined;
            var n: usize = 0;
            var it = dir.iterate();
            while (try it.next(io)) |entry| : (n += 1) {
                names[n] = entry.name[0];
                kinds[n] = entry.kind;
            }
            try expectEqual("abc", names[0..n]);
            if (kinds[0] != .file or kinds[2] != .directory) return error.WrongKind;
        }
    }.f);
}

export fn errors() i32 {
    return run(struct {
        fn f() !void {
            const cwd = Dir.cwd();
            try expectError(error.FileNotFound, cwd.openFile(io, "missing", .{}));
            (try cwd.createFile(io, "once", .{ .exclusive = true })).close(io);
            try expectError(error.PathAlreadyExists, cwd.createFile(io, "once", .{ .exclusive = true }));
            try cwd.createDir(io, "full", .default_dir);
            try expectError(error.PathAlreadyExists, cwd.createDir(io, "full", .default_dir));
            (try cwd.createFile(io, "full/x", .{})).close(io);
            try expectError(error.DirNotEmpty, cwd.deleteDir(io, "full"));
            try expectError(error.IsDir, cwd.openFile(io, "full", .{ .allow_directory = false }));
            try expectError(error.NotDir, cwd.openDir(io, "once", .{}));
            try expectError(error.FileNotFound, cwd.createFile(io, "nope/x", .{}));
            try cwd.deleteFile(io, "full/x");
            try cwd.deleteDir(io, "full");
            try expectError(error.FileNotFound, cwd.statFile(io, "full", .{}));
        }
    }.f);
}

export fn streaming() i32 {
    return run(struct {
        fn f() !void {
            const cwd = Dir.cwd();
            {
                var file = try cwd.createFile(io, "s.txt", .{});
                defer file.close(io);
                var wbuf: [8]u8 = undefined;
                var w = file.writerStreaming(io, &wbuf);
                try w.interface.print("{s}-{d}-{s}", .{ "hello", 42, "a much longer tail than the buffer" });
                try w.interface.flush();
            }
            var file = try cwd.openFile(io, "s.txt", .{});
            defer file.close(io);
            var rbuf: [4]u8 = undefined;
            var r = file.readerStreaming(io, &rbuf);
            var out: [128]u8 = undefined;
            const n = try r.interface.readSliceShort(&out);
            try expectEqual("hello-42-a much longer tail than the buffer", out[0..n]);

            // Positional reader (std's default).
            var pbuf: [4]u8 = undefined;
            var pr = file.reader(io, &pbuf);
            try pr.seekTo(6);
            var two: [2]u8 = undefined;
            try pr.interface.readSliceAll(&two);
            try expectEqual("42", &two);

            // The fd's own position, which streaming reads advance.
            try io.vtable.fileSeekTo(io.userdata, file, 0);
            try io.vtable.fileSeekBy(io.userdata, file, 9);
            var tail: [6]u8 = undefined;
            _ = try file.readStreaming(io, &.{&tail});
            try expectEqual("a much", &tail);
        }
    }.f);
}

export fn relative() i32 {
    return run(struct {
        fn f() !void {
            const cwd = Dir.cwd();
            var rel = try cwd.createDirPathOpen(io, "rel/deep", .{});
            defer rel.close(io);
            var file = try rel.createFile(io, "f", .{ .read = true });
            try file.writeStreamingAll(io, "abc");
            file.close(io);

            const st = try cwd.statFile(io, "rel/deep/f", .{});
            if (st.size != 3 or st.kind != .file) return error.WrongStat;
            try cwd.rename("rel/deep/f", rel, "../moved", io);
            var buf: [8]u8 = undefined;
            try expectEqual("abc", try get("rel/moved", &buf));
            try expectError(error.FileNotFound, rel.statFile(io, "f", .{}));
        }
    }.f);
}
