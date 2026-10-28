test "init" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    try test_cmd(.{
        .args = &.{"init"},
        .expected_exit_code = 0,
        .expected_stderr_strings = &.{
            "Initializing Ziex project!",
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
            "Initializing Ziex project!",
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
//     const port_colon = try allocator.print(":{s}", .{port});
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

//     const url = try allocator.print("http://{s}:{s}", .{ "localhost", port });
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
        .argv = &.{ "zig", "build", "-Dziex-config=.{ .command = .dev }" },
        .cwd = .{ .path = test_dir_abs },
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    switch (build_result.term) {
        .exited => |code| try std.testing.expectEqual(code, 0),
        else => try std.testing.expect(false),
    }
}

test "dev > lifecycle" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    const io = std.testing.io;

    killPort("3000") catch {};

    const test_dir_abs = try getTestDirPath();
    defer allocator.free(test_dir_abs);
    const page_path = try std.fs.path.join(allocator, &.{ test_dir_abs, "app", "pages", "page.zx" });
    defer allocator.free(page_path);
    const original = try std.Io.Dir.cwd().readFileAlloc(io, page_path, allocator, .limited(1024 * 1024));
    defer allocator.free(original);
    defer writePage(page_path, original, &.{}) catch {};

    const anchor = "Build full-stack web apps with Zig.";
    try std.testing.expect(std.mem.indexOf(u8, original, anchor) != null);

    var dev = try DevSession.start(io, test_dir_abs);
    defer dev.deinit();

    const port = try dev.waitForPort(0, 180_000);
    try dev.expectPage(port, anchor, 30_000);
    try std.testing.expect(std.mem.indexOf(u8, dev.snapshot(), "- v" ++ zx.info.version) != null);

    var mark = dev.len();
    try writePage(page_path, original, &.{.{ anchor, "zx-dev-change-1" }});
    try dev.waitFor("App Logs", mark, 180_000);
    try dev.expectPage(port, "zx-dev-change-1", 30_000);

    mark = dev.len();
    try writePage(page_path, original, &.{.{ anchor, "{zx_dev_undeclared_identifier}" }});
    try dev.waitFor("Error building", mark, 180_000);
    try dev.expectPage(port, "zx-dev-change-1", 10_000);
    mark = dev.len();
    try writePage(page_path, original, &.{.{ anchor, "zx-dev-change-2" }});
    try dev.waitFor("App Logs", mark, 180_000);
    try dev.expectPage(port, "zx-dev-change-2", 30_000);

    try dev.shutDown(port, .{});
}

test "dev > leaks" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    const io = std.testing.io;

    killPort("3000") catch {};

    const test_dir_abs = try getTestDirPath();
    defer allocator.free(test_dir_abs);
    const page_path = try std.fs.path.join(allocator, &.{ test_dir_abs, "app", "pages", "page.zx" });
    defer allocator.free(page_path);
    const original = try std.Io.Dir.cwd().readFileAlloc(io, page_path, allocator, .limited(1024 * 1024));
    defer allocator.free(original);
    defer writePage(page_path, original, &.{}) catch {};

    const anchor = "Build full-stack web apps with Zig.";
    const body_start = "    const query = ctx.request.query;\n";
    const leak = body_start ++ "    _ = zx.allocator.alloc(u8, 16) catch {};\n";
    try std.testing.expect(std.mem.indexOf(u8, original, body_start) != null);
    try writePage(page_path, original, &.{ .{ body_start, leak }, .{ anchor, "zx-dev-leak-0" } });

    var dev = try DevSession.start(io, test_dir_abs);
    defer dev.deinit();

    const port = try dev.waitForPort(0, 180_000);
    try dev.expectPage(port, "zx-dev-leak-0", 30_000);

    var mark = dev.len();
    try writePage(page_path, original, &.{ .{ body_start, leak }, .{ anchor, "zx-dev-leak-1" } });
    try dev.waitFor("App Logs", mark, 180_000);
    try dev.expectPage(port, "zx-dev-leak-1", 30_000);
    try dev.expectLeakSummary(mark);

    mark = dev.len();
    try dev.shutDown(port, .{});
    if (comptime builtin.os.tag != .windows) try dev.expectLeakSummary(mark);
}

test "dev > double ctrl+c" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    const io = std.testing.io;

    killPort("3000") catch {};

    const test_dir_abs = try getTestDirPath();
    defer allocator.free(test_dir_abs);

    var dev = try DevSession.start(io, test_dir_abs);
    defer dev.deinit();
    const port = try dev.waitForPort(0, 180_000);
    try dev.expectPage(port, "Build full-stack web apps with Zig.", 30_000);

    try dev.shutDown(port, .{ .double_ctrl_c = true });
}

test "build --static" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    killPort("3000") catch {};
    try test_cmd(.{
        .args = &.{ "build", "--static" },
        .expected_exit_code = 0,
        .expected_stderr_strings = &.{
            "Exporting static site!",
            "dist",
            "index.html",
            "form.html",
            "actions.html",
            "events.html",
            "db.html",
            "kv.html",
            "assets" ++ std.fs.path.sep_str ++ "style.css",
            "favicon.ico",
        },
        .expected_files = &.{
            "dist/index.html",
            "dist/form.html",
            "dist/actions.html",
            "dist/events.html",
            "dist/db.html",
            "dist/kv.html",
            "dist/assets/style.css",
            "dist/favicon.ico",
        },
    });
}

test "build --static --prerendered-only" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    killPort("3000") catch {};
    // No template page sets `.rendering = .prerendered`, so only static files are copied.
    try test_cmd(.{
        .args = &.{ "build", "--static", "--prerendered-only" },
        .expected_exit_code = 0,
        .expected_stderr_strings = &.{"Exporting static site!"},
        .expected_files = &.{
            "dist/assets/style.css",
            "dist/favicon.ico",
        },
        .unexpected_files = &.{
            "dist/index.html",
            "dist/form.html",
            "dist/404.html",
        },
    });
}

test "build --prerender" {
    if (!test_util.shouldRunSlowTest()) return error.SkipZigTest;
    killPort("3000") catch {};
    // Builds the app and runs the prerender step; unmarked pages stay dynamic.
    try test_cmd(.{
        .args = &.{ "build", "--prerender" },
        .expected_exit_code = 0,
        .expected_files = &.{
            "zig-out/bin/ziex_app" ++ (if (builtin.os.tag == .windows) ".exe" else ""),
            "zig-out/static/assets/style.css",
        },
        .unexpected_files = &.{
            "zig-out/static/index.html",
            "zig-out/static/404.html",
        },
    });
}

test "build --static rejects a cross-compile target" {
    try test_cmd(.{
        .args = &.{ "build", "--static", "--target=wasm32-wasi" },
        .expected_exit_code = 1,
        .expected_stdout_strings = &.{"can't be combined with --target=wasm32-wasi"},
    });
}

test "export is not a command" {
    try test_cmd(.{
        .args = &.{"export"},
        .expected_exit_code = 1,
        .expected_stderr_strings = &.{"unexpected argument: export"},
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
            "Initializing Ziex project!",
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
            "Initializing Ziex project!",
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
    unexpected_files: []const []const u8 = &.{},
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

    for (options.unexpected_files) |unexpected| {
        const path = try std.fs.path.join(allocator, &.{ test_dir_abs, unexpected });
        defer allocator.free(path);
        if (std.Io.Dir.cwd().statFile(std.testing.io, path, .{})) |_| {
            std.debug.print("\nExpected file '{s}' to not exist\n", .{unexpected});
            return error.TestExpectedEqual;
        } else |_| {}
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

const DevSession = struct {
    io: std.Io,
    child: std.process.Child,
    readers: [2]std.Thread,
    mutex: std.Io.Mutex = .init,
    log: std.ArrayList(u8) = .empty,

    fn start(io: std.Io, cwd: []const u8) !*DevSession {
        const zx_bin_abs = try getZxPath();
        defer allocator.free(zx_bin_abs);

        // As under `zig build dev` in a terminal.
        var env = try std.testing.environ.createMap(allocator);
        defer env.deinit();
        try env.put("CLICOLOR_FORCE", "1");

        const self = try allocator.create(DevSession);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .child = try std.process.spawn(io, .{
                .argv = &.{ zx_bin_abs, "dev" },
                .cwd = .{ .path = cwd },
                .environ_map = &env,
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .pipe,
            }),
            .readers = undefined,
        };
        self.readers = .{
            try std.Thread.spawn(.{}, collect, .{ self, self.child.stdout.? }),
            try std.Thread.spawn(.{}, collect, .{ self, self.child.stderr.? }),
        };
        return self;
    }

    fn deinit(self: *DevSession) void {
        if (self.child.id != null) killChildTree(&self.child, self.io);
        for (self.readers) |t| t.join();
        self.log.deinit(allocator);
        allocator.destroy(self);
    }

    fn pid(self: *DevSession) std.posix.pid_t {
        return self.child.id.?;
    }

    fn collect(self: *DevSession, file: std.Io.File) void {
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = file.readStreaming(self.io, &.{&chunk}) catch return;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.log.appendSlice(allocator, chunk[0..n]) catch return;
        }
    }

    fn len(self: *DevSession) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.log.items.len;
    }

    fn snapshot(self: *DevSession) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.log.items;
    }

    fn find(self: *DevSession, needle: []const u8, since: usize) ?usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const i = std.mem.indexOfPos(u8, self.log.items, since, needle) orelse return null;
        return i + needle.len;
    }

    fn waitFor(self: *DevSession, needle: []const u8, since: usize, timeout_ms: u64) !void {
        _ = try self.waitForEnd(needle, since, timeout_ms);
    }

    fn waitForEnd(self: *DevSession, needle: []const u8, since: usize, timeout_ms: u64) !usize {
        const deadline = deadlineIn(timeout_ms);
        while (true) {
            if (self.find(needle, since)) |end| return end;
            if (pastDeadline(deadline)) return self.fail("timed out waiting for log line", needle);
            sleepMs(100);
        }
    }

    fn waitForPort(self: *DevSession, since: usize, timeout_ms: u64) !u16 {
        const start_digits = try self.waitForEnd("http://localhost:", since, timeout_ms);
        const deadline = deadlineIn(5_000);
        while (true) {
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                const rest = self.log.items[start_digits..];
                var end: usize = 0;
                while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
                if (end > 0 and end < rest.len) return std.fmt.parseInt(u16, rest[0..end], 10);
            }
            if (pastDeadline(deadline)) return self.fail("could not parse port", "http://localhost:");
            sleepMs(50);
        }
    }

    fn expectPage(self: *DevSession, port: u16, needle: []const u8, timeout_ms: u64) !void {
        const deadline = deadlineIn(timeout_ms);
        while (true) {
            if (httpGet(port)) |body| {
                defer allocator.free(body);
                if (std.mem.indexOf(u8, body, needle) != null) return;
            } else |_| {}
            if (pastDeadline(deadline)) return self.fail("page never contained", needle);
            sleepMs(250);
        }
    }

    /// Windows: std can't give zx its own console group, so Ctrl+C can't target it.
    fn shutDown(self: *DevSession, port: u16, opts: struct { double_ctrl_c: bool = false }) !void {
        if (comptime builtin.os.tag == .windows) return;

        const tree = try descendantPids(self.pid());
        defer allocator.free(tree);
        if (tree.len < 2) return self.fail("expected zig build and the app under zx", "");

        if (opts.double_ctrl_c) try std.posix.kill(self.pid(), .INT);
        const term = try self.interrupt();
        if (!std.meta.eql(term, std.process.Child.Term{ .exited = 130 })) return self.fail("unexpected exit", "130");
        if (!opts.double_ctrl_c and self.find("Stopping dev server...", 0) == null) return self.fail("missing shutdown message", "Stopping dev server...");

        try expectAllGone(tree, 3_000);
        if (canConnect(port)) return self.fail("port still open after shutdown", "");
    }

    fn interrupt(self: *DevSession) !std.process.Child.Term {
        const Watchdog = struct {
            fn run(io: std.Io, id: std.process.Child.Id, fired: *std.atomic.Value(bool)) void {
                io.sleep(.fromMilliseconds(3_000), .awake) catch return;
                _ = std.posix.system.kill(id, .INT);
                io.sleep(.fromMilliseconds(5_000), .awake) catch return;
                fired.store(true, .release);
                _ = std.posix.system.kill(id, .KILL);
            }
        };
        try std.posix.kill(self.pid(), .INT);
        var fired: std.atomic.Value(bool) = .init(false);
        var watchdog = try self.io.concurrent(Watchdog.run, .{ self.io, self.pid(), &fired });
        const term = try self.child.wait(self.io);
        watchdog.cancel(self.io);
        if (fired.load(.acquire)) return self.fail("zx did not exit after two Ctrl+C", "");
        return term;
    }

    fn expectLeakSummary(self: *DevSession, since: usize) !void {
        if (self.find("memory leak", since) == null) return self.fail("missing leak summary", "memory leak");
        if (self.find("error(DebugAllocator)", since) != null) return self.fail("raw leak trace leaked through", "error(DebugAllocator)");
        if (self.find("no stack trace", since) != null) return self.fail("leak without stack trace", "no stack trace");
        for ([_][]const u8{ "memory leak in `Page`", "page.zx:" }) |needle| {
            if (self.find(needle, since) == null) return self.fail("missing leak location", needle);
        }
    }

    fn fail(self: *DevSession, what: []const u8, needle: []const u8) error{TestUnexpectedResult} {
        std.debug.print("\nzx dev: {s} '{s}'\n---- zx dev output ----\n{s}\n-----------------------\n", .{ what, needle, self.snapshot() });
        return error.TestUnexpectedResult;
    }
};

fn writePage(path: []const u8, original: []const u8, edits: []const [2][]const u8) !void {
    var content = try allocator.dupe(u8, original);
    defer allocator.free(content);
    for (edits) |e| {
        const next = try std.mem.replaceOwned(u8, allocator, content, e[0], e[1]);
        allocator.free(content);
        content = next;
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = content });
}

fn httpGet(port: u16) ![]u8 {
    const io = std.testing.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var w = stream.writer(io, &write_buf);
    try w.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try w.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var r = stream.reader(io, &read_buf);
    return r.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024));
}

fn canConnect(port: u16) bool {
    const io = std.testing.io;
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return false;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

fn descendantPids(root: std.posix.pid_t) ![]std.posix.pid_t {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "ps", "-A", "-o", "pid=", "-o", "ppid=" },
        .stdout_limit = .limited(4 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const Pair = struct { pid: std.posix.pid_t, ppid: std.posix.pid_t };
    var pairs = std.ArrayList(Pair).empty;
    defer pairs.deinit(allocator);
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        var cols = std.mem.tokenizeAny(u8, line, " \t");
        const p = std.fmt.parseInt(std.posix.pid_t, cols.next() orelse continue, 10) catch continue;
        const pp = std.fmt.parseInt(std.posix.pid_t, cols.next() orelse continue, 10) catch continue;
        try pairs.append(allocator, .{ .pid = p, .ppid = pp });
    }

    var found = std.ArrayList(std.posix.pid_t).empty;
    errdefer found.deinit(allocator);
    try found.append(allocator, root);
    var i: usize = 0;
    while (i < found.items.len) : (i += 1) {
        for (pairs.items) |pair| {
            if (pair.ppid == found.items[i]) try found.append(allocator, pair.pid);
        }
    }
    _ = found.orderedRemove(0);
    return found.toOwnedSlice(allocator);
}

fn expectAllGone(pids: []const std.posix.pid_t, timeout_ms: u64) !void {
    const deadline = deadlineIn(timeout_ms);
    while (true) {
        var alive: usize = 0;
        for (pids) |p| {
            if (std.posix.errno(std.posix.system.kill(p, @fromBackingInt(0))) != .SRCH) alive += 1;
        }
        if (alive == 0) return;
        if (pastDeadline(deadline)) {
            for (pids) |p| {
                if (std.posix.errno(std.posix.system.kill(p, @fromBackingInt(0))) == .SRCH) continue;
                std.debug.print("\nzx dev: pid {d} survived shutdown\n", .{p});
                _ = std.posix.system.kill(p, .KILL);
            }
            return error.TestUnexpectedResult;
        }
        sleepMs(50);
    }
}

fn deadlineIn(ms: u64) std.Io.Timestamp {
    return std.Io.Timestamp.now(std.testing.io, .awake).addDuration(.fromMilliseconds(@intCast(ms)));
}

fn pastDeadline(deadline: std.Io.Timestamp) bool {
    return std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds >= deadline.nanoseconds;
}

fn sleepMs(ms: u64) void {
    std.Io.sleep(std.testing.io, .fromMilliseconds(@intCast(ms)), .awake) catch {};
}

fn killPort(port: []const u8) !void {
    const target_os = builtin.target.os.tag;

    if (target_os == .windows) {
        const cmd = try allocator.print(
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
        const kill_command = try allocator.print("kill -9 $(lsof -t -i:{s})", .{port});
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
