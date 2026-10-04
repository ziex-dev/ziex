test "init" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    try test_cmd(.{
        .args = &.{"init"},
        .expected_exit_code = 0,
        .expected_stderr_strings = &.{
            "Initializing ZX project!",
            "main.zig",
            ".gitattributes",
            "client.zx",
            "page.zx",
        },
        .expected_files = &.{
            "build.zig.zon",
            "build.zig",
            "app/main.zig",
            "app/pages/page.zx",
            "app/pages/client.zx",
            "app/assets/style.css",
            "app/public/favicon.ico",
            ".gitignore",
            ".gitattributes",
            "README.md",
        },
    });
}

test "init → init" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    try test_cmd(.{
        .args = &.{"init"},
        .expected_exit_code = 0,
        .expected_stderr_strings = &.{
            "Directory is not empty",
        },
    });
}

test "init --force" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    try test_cmd(.{
        .args = &.{ "init", "--force" },
        .expected_exit_code = 0,
        .expected_stderr_strings = &.{
            "Initializing ZX project!",
            "main.zig",
            "page.zx",
        },
        .expected_files = &.{
            "build.zig.zon",
            "build.zig",
            "app/main.zig",
            "app/pages/page.zx",
            "app/pages/client.zx",
            ".gitignore",
            ".gitattributes",
            "README.md",
        },
    });
}

// test "serve" {
//     if (!sholdRunSlowTest()) return error.SkipZigTest; // Slow test, will enable later, and execute as another steps as e2e before release
//     if (true) return error.Todo;

//     const zx_bin_abs = try getZxPath();
//     const test_dir_abs = try getTestDirPath();
//     defer allocator.free(zx_bin_abs);
//     defer allocator.free(test_dir_abs);

//     const port = "3456";
//     const port_colon = try std.fmt.allocPrint(allocator, ":{s}", .{port});
//     defer allocator.free(port_colon);

//     // Kill anything on that port (cross-platform)
//     killPort(port) catch {};

//     var build_child = std.process.Child.init(&.{ "zig", "build" }, allocator);
//     build_child.cwd = test_dir_abs;
//     build_child.stdout_behavior = .Ignore;
//     build_child.stderr_behavior = .Ignore;
//     try build_child.spawn();
//     _ = build_child.wait() catch {};

//     var child = std.process.Child.init(&.{ zx_bin_abs, "serve", "--port", port }, allocator);
//     child.cwd = test_dir_abs;
//     // child.stdout_behavior = .Ignore;
//     // child.stderr_behavior = .Ignore;
//     try child.spawn();
//     defer _ = child.kill() catch {};
//     errdefer _ = child.kill() catch {};

//     var client = std.http.Client{ .allocator = allocator };
//     defer client.deinit();

//     var aw = std.Io.Writer.Allocating.init(allocator);
//     defer aw.deinit();

//     const url = try std.fmt.allocPrint(allocator, "http://{s}:{s}", .{ "localhost", port });
//     defer allocator.free(url);

//     // wait for 2 seconds
//     std.Thread.sleep(std.time.ns_per_s * 1);
//     const result = try client.fetch(.{
//         .method = .GET,
//         .location = .{ .url = url },
//         .headers = std.http.Client.Request.Headers{},
//         .response_writer = &aw.writer,
//     });

//     // Wait 500ms
//     std.Thread.sleep(std.time.ns_per_ms * 500);
//     _ = child.kill() catch {};
//     errdefer _ = child.kill() catch {};

//     try std.testing.expectEqual(result.status, std.http.Status.ok);
// }

test "init → build" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;

    const test_dir_abs = try getTestDirPath();
    defer allocator.free(test_dir_abs);

    // Update build.zig.zon to use the local zx dependency, copy local_zon_str to build.zig.zon
    const build_zig_zon_path = try std.fs.path.join(allocator, &.{ test_dir_abs, "build.zig.zon" });
    defer allocator.free(build_zig_zon_path);
    var build_zig_zon = try std.Io.Dir.openDirAbsolute(std.testing.io, test_dir_abs, .{});
    defer build_zig_zon.close(std.testing.io);
    try build_zig_zon.writeFile(std.testing.io, .{ .sub_path = build_zig_zon_path, .data = local_zon_str });

    const build_result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build", "-Dcli-command=dev" },
        .cwd = .{ .path = test_dir_abs },
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    switch (build_result.term) {
        .exited => |code| try std.testing.expectEqual(code, 0),
        else => try std.testing.expect(false),
    }
}

test "dev" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;

    killPort("3000") catch {};

    try test_cmd_blocking(.{
        .args = &.{"dev"},
        .expected_stderr_strings = &.{
            "- v" ++ zx.info.version,
            "http://localhost:",
        },
        .timeout_ms = 180_000,
    });
}

test "export" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    killPort("3000") catch {};
    try test_cmd(.{
        .args = &.{"export"},
        .expected_exit_code = 0,
        .expected_stderr_strings = &.{
            "Exporting static site!",
            "dist",
            "index.html",
            "form.html",
            "actions.html",
            "actions" ++ std.fs.path.sep_str ++ "server.html",
            "actions" ++ std.fs.path.sep_str ++ "client.html",
            "assets" ++ std.fs.path.sep_str ++ "style.css",
            "favicon.ico",
        },
        .expected_files = &.{
            "dist/index.html",
            "dist/form.html",
            "dist/actions.html",
            "dist/actions/server.html",
            "dist/actions/client.html",
            "dist/assets/style.css",
            "dist/favicon.ico",
        },
    });
}

test "bundle" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    try test_cmd(.{
        .args = &.{"bundle"},
        .expected_exit_code = 0,
        .expected_stderr_strings = &.{
            "Bundling app!",
            "bundle",
            "ziex_app",
            "style.css",
            "favicon.ico",
        },
        .expected_files = &.{
            "bundle/ziex_app" ++ (if (builtin.os.tag == .windows) ".exe" else ""),
            "bundle/static/assets/style.css",
            "bundle/static/favicon.ico",
        },
    });
}

test "init -t docker" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    try test_cmd(.{
        .args = &.{ "init", "--template", "docker", "--existing" },
        .expected_exit_code = 0,
        .expected_stderr_strings = &.{
            "Initializing ZX project!",
            "docker",
            "Dockerfile",
            "compose.yml",
            ".dockerignore",
        },
        .expected_files = &.{
            "Dockerfile",
            "compose.yml",
            ".dockerignore",
        },
        .expected_file_contains = &.{
            // $BIN_NAME placeholder must resolve to the detected exe name.
            .{ .path = "Dockerfile", .needle = "ziex_app" },
            .{ .path = "compose.yml", .needle = "ziex_app" },
        },
        .expected_file_excludes = &.{
            .{ .path = "Dockerfile", .needle = "$BIN_NAME" },
            .{ .path = "compose.yml", .needle = "$BIN_NAME" },
            .{ .path = "compose.yml", .needle = "$PORT" },
        },
    });
}

test "init -t <remote>" {
    if (!test_util.shouldRunNetworkTest()) return error.SkipZigTest;
    // Fetches github:ziex-dev/template-cloudflare, renames the project to the
    // target directory name, and regenerates the build.zig.zon fingerprint.
    try test_cmd(.{
        .args = &.{ "init", "--template", "cloudflare", "remote-app", "--force" },
        .expected_exit_code = 0,
        .expected_stderr_strings = &.{
            "Initializing ZX project!",
            "github:ziex-dev/template-cloudflare",
        },
        .expected_files = &.{
            "remote-app/build.zig.zon",
            "remote-app/build.zig",
            "remote-app/app/main.zig",
        },
        .expected_file_contains = &.{
            // Project renamed from ziex_app to the directory name.
            .{ .path = "remote-app/build.zig.zon", .needle = ".name = .remote_app" },
        },
        .expected_file_excludes = &.{
            .{ .path = "remote-app/build.zig.zon", .needle = "ziex_app" },
        },
    });
}

test "fmt" {
    try test_cmd(.{
        .args = &.{ "fmt", "app" ++ std.fs.path.sep_str ++ "pages" },
        .expected_exit_code = 0,
        .expected_stdout_strings = &.{
            // "app" ++ std.fs.path.sep_str ++ "pages" ++ std.fs.path.sep_str ++ "layout.zx",
            // "app" ++ std.fs.path.sep_str ++ "pages" ++ std.fs.path.sep_str ++ "page.zx",
        },
    });
}

test "upgrade" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    // always skip cuasing unnecessary downloads as install script does not change often
    if (true) return error.SkipZigTest;
    try test_cmd(.{
        .args = &.{"upgrade"},
        .expected_exit_code = 0,
        .expected_stdout_strings = &.{
            "was installed successfully",
            // "0.1.0-dev",
        },
        .expected_files = &.{},
        // .debug = true,
    });
}

const FileNeedle = struct {
    path: []const u8,
    needle: []const u8,
};

const TestCmdOptions = struct {
    args: []const []const u8,
    expected_stderr_strings: []const []const u8 = &.{},
    expected_stdout_strings: []const []const u8 = &.{},
    expected_exit_code: i32 = 0,
    expected_files: []const []const u8 = &.{},
    expected_file_contains: []const FileNeedle = &.{},
    expected_file_excludes: []const FileNeedle = &.{},
    debug: bool = false,
};
fn test_cmd(options: TestCmdOptions) !void {
    const zx_bin_abs = try getZxPath();
    const test_dir_abs = try getTestDirPath();
    defer allocator.free(zx_bin_abs);
    defer allocator.free(test_dir_abs);

    // Delete bundle or dist directory if it exists
    var test_dir = try std.Io.Dir.openDirAbsolute(std.testing.io, test_dir_abs, .{});
    defer test_dir.close(std.testing.io);
    test_dir.deleteTree(std.testing.io, "bundle") catch {};
    test_dir.deleteTree(std.testing.io, "dist") catch {};

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{zx_bin_abs});
    try args.appendSlice(allocator, options.args);

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = args.items,
        .cwd = .{ .path = test_dir_abs },
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (options.debug) {
        std.debug.print("\nstdout: {s}", .{result.stdout});
        std.debug.print("\nstderr: {s}", .{result.stderr});
    }

    for (options.expected_stderr_strings) |expected_string| {
        if (std.mem.indexOf(u8, result.stderr, expected_string) == null) {
            std.debug.print("\nExpected stderr to contain: '{s}'\nActual stderr:\n{s}\n", .{ expected_string, result.stderr });
            return error.TestExpectedEqual;
        }
    }
    for (options.expected_stdout_strings) |expected_string| {
        if (std.mem.indexOf(u8, result.stdout, expected_string) == null) {
            std.debug.print("\nExpected stdout to contain: '{s}'\nActual stdout:\n{s}\n", .{ expected_string, result.stdout });
            return error.TestExpectedEqual;
        }
    }
    switch (result.term) {
        .exited => |code| {
            if (code != options.expected_exit_code) {
                std.debug.print("\nExpected exit code: {d}, got: {d}\nstderr:\n{s}\nstdout:\n{s}\n", .{ options.expected_exit_code, code, result.stderr, result.stdout });
                return error.TestExpectedEqual;
            }
        },
        else => {
            std.debug.print("\nProcess terminated abnormally\nstderr:\n{s}\nstdout:\n{s}\n", .{ result.stderr, result.stdout });
            return error.TestExpectedEqual;
        },
    }

    var missing_file: u32 = 0;

    for (options.expected_files) |expected_file| {
        var expected_file_path = std.ArrayList([]const u8).empty;
        defer expected_file_path.deinit(allocator);
        try expected_file_path.appendSlice(allocator, &.{test_dir_abs});

        var path_iter = std.mem.splitSequence(u8, expected_file, "/");
        while (path_iter.next()) |part| {
            if (part.len > 0) {
                try expected_file_path.append(allocator, part);
            }
        }
        const expected_file_path_str = try std.fs.path.join(allocator, expected_file_path.items);
        defer allocator.free(expected_file_path_str);

        const file_stat = std.Io.Dir.cwd().statFile(std.testing.io, expected_file_path_str, .{}) catch |err| {
            std.log.err("\nExpected file '{s}' does not exist {s}\n", .{ expected_file_path_str, @errorName(err) });
            missing_file += 1;
            continue;
        };
        try std.testing.expectEqual(file_stat.kind, .file);
    }

    if (missing_file > 0) {
        std.log.err("\nTotal missing files: {d}\n", .{missing_file});
        return error.TestExpectedEqual;
    }

    for (options.expected_file_contains) |fc| {
        const path = try std.fs.path.join(allocator, &.{ test_dir_abs, fc.path });
        defer allocator.free(path);
        const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024));
        defer allocator.free(data);
        if (std.mem.indexOf(u8, data, fc.needle) == null) {
            std.debug.print("\nExpected file '{s}' to contain: '{s}'\nActual:\n{s}\n", .{ fc.path, fc.needle, data });
            return error.TestExpectedEqual;
        }
    }

    for (options.expected_file_excludes) |fc| {
        const path = try std.fs.path.join(allocator, &.{ test_dir_abs, fc.path });
        defer allocator.free(path);
        const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024));
        defer allocator.free(data);
        if (std.mem.indexOf(u8, data, fc.needle) != null) {
            std.debug.print("\nExpected file '{s}' to NOT contain: '{s}'\nActual:\n{s}\n", .{ fc.path, fc.needle, data });
            return error.TestExpectedEqual;
        }
    }
}

const TestCmdBlockingOptions = struct {
    args: []const []const u8,
    expected_stderr_strings: []const []const u8 = &.{},
    timeout_ms: u64 = 30_000,
    debug: bool = false,
};

const StreamResult = union(enum) {
    matched,
    ended,
    failed,
    timed_out,
};

fn test_cmd_blocking(options: TestCmdBlockingOptions) !void {
    const io = std.testing.io;

    const zx_bin_abs = try getZxPath();
    const test_dir_abs = try getTestDirPath();
    defer allocator.free(zx_bin_abs);
    defer allocator.free(test_dir_abs);

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{zx_bin_abs});
    try args.appendSlice(allocator, options.args);

    var child = try std.process.spawn(io, .{
        .argv = args.items,
        .cwd = .{ .path = test_dir_abs },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer killChildTree(&child, io);

    const Reader = struct {
        fn run(
            r_io: std.Io,
            stderr: std.Io.File,
            expected: []const []const u8,
            debug: bool,
        ) StreamResult {
            var acc = std.ArrayList(u8).empty;
            defer acc.deinit(allocator);

            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = stderr.readStreaming(r_io, &.{&chunk}) catch |err| switch (err) {
                    error.EndOfStream => return .ended,
                    else => return .failed,
                };
                if (n == 0) continue;
                acc.appendSlice(allocator, chunk[0..n]) catch return .failed;
                if (debug) std.debug.print("{s}", .{chunk[0..n]});

                var all_found = true;
                for (expected) |needle| {
                    if (std.mem.indexOf(u8, acc.items, needle) == null) {
                        all_found = false;
                        break;
                    }
                }
                if (all_found) return .matched;
            }
        }
    };

    const Timer = struct {
        fn run(t_io: std.Io, ms: u64) StreamResult {
            t_io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
            return .timed_out;
        }
    };

    const Selector = std.Io.Select(union(enum) {
        reader: StreamResult,
        timer: StreamResult,
    });
    var buffer: [2]Selector.Union = undefined;
    var selector = Selector.init(io, &buffer);

    selector.async(.reader, Reader.run, .{ io, child.stderr.?, options.expected_stderr_strings, options.debug });
    selector.async(.timer, Timer.run, .{ io, options.timeout_ms });

    const winner = try selector.await();
    // Cancel and drain the loser before returning so its resources are freed.
    while (selector.cancel()) |_| {}

    const result: StreamResult = switch (winner) {
        .reader => |r| r,
        .timer => |t| t,
    };

    switch (result) {
        .matched => {},
        .ended => {
            std.debug.print("\n`{s}` stderr ended before all expected strings appeared\n", .{options.args[0]});
            return error.TestExpectedEqual;
        },
        .failed => {
            std.debug.print("\nFailed reading stderr from `{s}`\n", .{options.args[0]});
            return error.TestExpectedEqual;
        },
        .timed_out => {
            std.debug.print(
                "\n`{s}` timed out after {d}ms before all expected strings appeared\n",
                .{ options.args[0], options.timeout_ms },
            );
            return error.TestExpectedEqual;
        },
    }
}

const local_zon_str =
    \\.{
    \\    .name = .ziex_app,
    \\    .version = "0.0.0",
    \\    .fingerprint = 0x7246d8c908f650a4,
    \\    .minimum_zig_version = "0.17.0",
    \\    .dependencies = .{
    \\        .ziex = .{
    \\            .path = "../../",
    \\        },
    \\    },
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "app",
    \\    },
    \\}
;

var local_wasm_zon_str = .{
    .name = .ziex_app,
    .version = "0.0.0",
    .fingerprint = 0x7246d8c908f650a4,
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .ziex = .{
            .path = "../../../",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "app",
    },
};

test "tests:beforeAll" {
    std.Io.Dir.cwd().deleteTree(std.testing.io, "test/tmp") catch {};
    std.Io.Dir.cwd().createDir(std.testing.io, "test/tmp", .default_dir) catch {};
}

test "tests:afterAll" {
    // std.Io.Dir.cwd().deleteTree("test/tmp") catch {};
}

fn getZxPath() ![]u8 {
    const zx_bin_rel = if (builtin.os.tag == .windows) "zig-out/bin/zx.exe" else "zig-out/bin/zx";
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, zx_bin_rel, &buffer);
    return allocator.dupe(u8, buffer[0..n]);
}

fn getTestDirPath() ![]const u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, "test/tmp" });
}

/// Terminate `child` and, on Windows, its descendants (`taskkill /T`).
fn killChildTree(child: *std.process.Child, io: std.Io) void {
    if (comptime builtin.os.tag == .windows) {
        if (child.id) |handle| {
            const pid = win32.GetProcessId(handle);
            if (pid != 0) {
                var pid_buf: [16]u8 = undefined;
                if (std.fmt.bufPrint(&pid_buf, "{d}", .{pid})) |pid_str| {
                    const result = std.process.run(allocator, io, .{
                        .argv = &.{ "taskkill", "/T", "/F", "/PID", pid_str },
                        .stdout_limit = .limited(4096),
                        .stderr_limit = .limited(4096),
                    }) catch null;
                    if (result) |r| {
                        allocator.free(r.stdout);
                        allocator.free(r.stderr);
                    }
                } else |_| {}
            }
        }
    }
    child.kill(io);
}

fn killPort(port: []const u8) !void {
    const target_os = builtin.target.os.tag;

    if (target_os == .windows) {
        const cmd = try std.fmt.allocPrint(
            allocator,
            "for /f \"tokens=5\" %a in ('netstat -ano ^| findstr \":{s}\"') do @taskkill /F /PID %a >nul 2>&1",
            .{port},
        );
        defer allocator.free(cmd);

        const result = std.process.run(allocator, std.testing.io, .{
            .argv = &.{ "cmd", "/C", cmd },
            .stdout_limit = .limited(8192),
            .stderr_limit = .limited(8192),
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    } else {
        // Unix-like: Use lsof and kill
        const kill_command = try std.fmt.allocPrint(allocator, "kill -9 $(lsof -t -i:{s})", .{port});
        defer allocator.free(kill_command);

        const result = std.process.run(allocator, std.testing.io, .{
            .argv = &.{ "sh", "-c", kill_command },
            .stdout_limit = .limited(8192),
            .stderr_limit = .limited(8192),
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
}

const win32 = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn GetProcessId(hProcess: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;
} else struct {};

const allocator = std.testing.allocator;
const test_util = @import("./../util.zig");

const std = @import("std");
const zx = @import("zx");
const builtin = @import("builtin");
