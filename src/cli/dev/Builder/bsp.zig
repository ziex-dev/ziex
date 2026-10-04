/// Build Server Protocol backend (`zig build --listen=-`).
const Bsp = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Configuration = std.Build.Configuration;
const Client = std.zig.Client;
const Server = std.zig.Server;

const Builder = @import("../Builder.zig");
const log = std.log.scoped(.builder_bsp);

const Event = Builder.Event;
const Diagnostic = Builder.Diagnostic;
const InitOptions = Builder.InitOptions;

allocator: Allocator,
io: Io,
child_process: std.process.Child,
multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined,
multi_reader: Io.File.MultiReader = undefined,
stdin_buffer: [256]u8 = undefined,
stdin_writer: Io.File.Writer = undefined,
client: Client = undefined,
conf_arena: std.heap.ArenaAllocator,
configuration: ?Configuration = null,
pending: std.ArrayList(Event) = .empty,
first_build_done: bool = false,
previous_had_errors: bool = false,
cycle_started_at: ?Io.Timestamp = null,
/// Accumulated during one build_started…build_completed cycle.
cycle: Cycle = .{},
watching: bool = false,
closed: bool = false,

const Cycle = struct {
    server_fresh: bool = false,
    client_fresh: bool = false,
    assets_fresh: bool = false,
    had_failure: bool = false,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    asset_paths: std.ArrayList([]const u8) = .empty,

    fn reset(self: *Cycle, allocator: Allocator) void {
        freeDiagnostics(allocator, &self.diagnostics);
        for (self.asset_paths.items) |p| allocator.free(p);
        self.asset_paths.clearRetainingCapacity();
        self.server_fresh = false;
        self.client_fresh = false;
        self.assets_fresh = false;
        self.had_failure = false;
    }

    fn deinit(self: *Cycle, allocator: Allocator) void {
        freeDiagnostics(allocator, &self.diagnostics);
        self.diagnostics.deinit(allocator);
        for (self.asset_paths.items) |p| allocator.free(p);
        self.asset_paths.deinit(allocator);
    }
};

pub fn init(self: *Bsp, io: Io, options: InitOptions) !void {
    var argv = try std.ArrayList([]const u8).initCapacity(options.allocator, options.argv.len + 2);
    defer argv.deinit(options.allocator);
    try argv.appendSlice(options.allocator, options.argv);
    if (argv.items.len == 0 or !std.mem.eql(u8, argv.items[argv.items.len - 1], "--listen=-")) {
        try argv.append(options.allocator, "--listen=-");
    }

    log.debug("bsp cmd: {f}", .{std.zig.SubprocessCommand{ .argv = argv.items }});

    var child_process = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = options.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = options.pgid,
    });
    errdefer child_process.kill(io);

    self.* = .{
        .allocator = options.allocator,
        .io = io,
        .child_process = child_process,
        .conf_arena = .init(options.allocator),
    };
    errdefer self.conf_arena.deinit();

    self.multi_reader.init(
        options.allocator,
        io,
        self.multi_reader_buffer.toStreams(),
        &.{ child_process.stdout.?, child_process.stderr.? },
    );
    errdefer self.multi_reader.deinit();

    self.stdin_writer = child_process.stdin.?.writerStreaming(io, &self.stdin_buffer);
    self.client = .{
        .in = self.multi_reader.reader(0),
        .out = &self.stdin_writer.interface,
    };

    try self.handshakeAndWatch(io);
}

pub fn builder(self: *Bsp) Builder {
    return .{
        .userdata = self,
        .vtable = &.{
            .deinit = &vtableDeinit,
            .kill = &vtableKill,
            .next = &vtableNext,
            .child = &vtableChild,
        },
    };
}

fn vtableDeinit(userdata: ?*anyopaque, io: Io) void {
    const self: *Bsp = @ptrCast(@alignCast(userdata));
    self.deinit(io);
}

fn vtableKill(userdata: ?*anyopaque, io: Io) void {
    const self: *Bsp = @ptrCast(@alignCast(userdata));
    self.child_process.kill(io);
}

fn vtableChild(userdata: ?*anyopaque) *std.process.Child {
    const self: *Bsp = @ptrCast(@alignCast(userdata));
    return &self.child_process;
}

fn vtableNext(userdata: ?*anyopaque, io: Io) anyerror!?Event {
    const self: *Bsp = @ptrCast(@alignCast(userdata));
    return self.nextEvent(io);
}

pub fn deinit(self: *Bsp, io: Io) void {
    if (self.child_process.id != null) {
        if (!self.closed) {
            self.client.serveBodylessMessage(.exit) catch {};
            self.stdin_writer.interface.flush() catch {};
        }
        if (self.child_process.id != null) {
            _ = self.child_process.wait(io) catch {
                if (self.child_process.id != null) self.child_process.kill(io);
            };
        }
    }
    for (self.pending.items) |*event| freeEvent(event);
    self.pending.deinit(self.allocator);
    self.cycle.deinit(self.allocator);
    self.multi_reader.deinit();
    self.conf_arena.deinit();
}

fn handshakeAndWatch(self: *Bsp, io: Io) !void {
    const stdout = self.multi_reader.reader(0);

    // bsp_handshake
    {
        const header = try self.client.receiveMessageWithMultiReader(&self.multi_reader, .none);
        const body = stdout.take(header.bytes_len) catch unreachable;
        log.debug("received {t} ({d} bytes)", .{ header.tag, body.len });
        if (header.tag != .bsp_handshake) return error.UnexpectedMessage;
        var r: Io.Reader = .fixed(body);
        const handshake = try r.takeStruct(Server.Message.Handshake, .little);
        if (handshake.version != Server.build_system_version) {
            log.warn("bsp version mismatch: got {d} want {d}", .{ handshake.version, Server.build_system_version });
        }
        if (!handshake.flags.file_system_watch_supported) {
            log.warn("bsp server does not support file watching", .{});
        }
    }

    // bsp_configuration | bsp_configuration_failed
    {
        const header = try self.client.receiveMessageWithMultiReader(&self.multi_reader, .none);
        const body = stdout.take(header.bytes_len) catch unreachable;
        log.debug("received {t} ({d} bytes)", .{ header.tag, body.len });
        switch (header.tag) {
            .bsp_configuration => {
                const conf_arena = self.conf_arena.allocator();
                var file = try Io.Dir.cwd().openFile(io, body, .{});
                defer file.close(io);
                self.configuration = try Configuration.loadFile(conf_arena, io, file);
            },
            .bsp_configuration_failed => {
                var eb = try Server.allocErrorBundle(self.allocator, body);
                defer eb.deinit(self.allocator);
                try self.appendErrorBundle(&eb);
                try self.pending.append(self.allocator, .{ .errors = .{
                    .allocator = self.allocator,
                    .success = false,
                    .diagnostics = try self.cycle.diagnostics.toOwnedSlice(self.allocator),
                } });
                self.previous_had_errors = true;
                self.closed = true;
                return;
            },
            else => return error.UnexpectedMessage,
        }
    }

    const c = &self.configuration.?;
    try self.client.serveBuildSteps(&.{c.default_step}, .{ .watch = true });
    self.watching = true;
}

fn nextEvent(self: *Bsp, io: Io) !?Event {
    _ = io;
    if (self.pending.items.len > 0) {
        return self.pending.orderedRemove(0);
    }
    if (self.closed) return null;

    const stdout = self.multi_reader.reader(0);
    while (true) {
        const header = self.client.receiveMessageWithMultiReader(&self.multi_reader, .none) catch |err| switch (err) {
            error.EndOfStream => {
                self.closed = true;
                if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
                return null;
            },
            else => |e| return e,
        };
        const body = stdout.take(header.bytes_len) catch unreachable;
        log.debug("received {t} ({d} bytes)", .{ header.tag, body.len });

        if (try self.handleMessage(header.tag, body)) |event| return event;
        if (self.pending.items.len > 0) return self.pending.orderedRemove(0);
    }
}

fn handleMessage(self: *Bsp, tag: Server.Message.Tag, body: []const u8) !?Event {
    const c = &(self.configuration orelse return error.UnexpectedMessage);

    switch (tag) {
        .bsp_build_started => {
            self.cycle.reset(self.allocator);
            self.cycle_started_at = Io.Timestamp.now(self.io, .awake);
            if (self.first_build_done) {
                log.debug("change_detected", .{});
                return .change_detected;
            }
            return null;
        },
        .bsp_step_started => return null,
        .bsp_step_completed => {
            var reader: Io.Reader = .fixed(body);
            const bsc = try reader.takeStruct(Server.Message.BuildStepCompleted, .little);
            const step_name = bsc.step_index.ptr(c).name.slice(c);

            var eb = try std.zig.ErrorBundle.readAlloc(
                &reader,
                self.allocator,
                bsc.error_bundle.extra_len,
                bsc.error_bundle.string_bytes_len,
            );
            defer eb.deinit(self.allocator);

            // Consume generated-file trailer so the reader stays consistent.
            const modified_files: []align(1) Server.Message.GeneratedFile = @ptrCast(
                try reader.take(bsc.generated_files_len * @sizeOf(Server.Message.GeneratedFile)),
            );
            for (modified_files) |modified_file| {
                _ = try reader.takeEnum(Server.Message.PathPrefix, .little);
                _ = try reader.take(modified_file.path_len);
            }

            log.debug("step {q} {t}", .{ step_name, bsc.status });

            switch (bsc.status) {
                .failure => {
                    self.cycle.had_failure = true;
                    try self.appendErrorBundle(&eb);
                },
                .success => {
                    if (isServerStep(step_name)) self.cycle.server_fresh = true;
                    if (isClientStep(step_name)) self.cycle.client_fresh = true;
                    if (isAssetStep(step_name)) {
                        self.cycle.assets_fresh = true;
                        try self.rememberAssetPath(step_name);
                    }
                },
                .skipped, .skipped_oom => {},
            }
            return null;
        },
        .bsp_build_completed => {
            const duration_ms = self.cycleDurationMs();
            if (self.cycle.had_failure or self.cycle.diagnostics.items.len > 0) {
                self.previous_had_errors = true;
                const diagnostics = try self.cycle.diagnostics.toOwnedSlice(self.allocator);
                self.cycle.diagnostics = .empty;
                return .{ .errors = .{
                    .allocator = self.allocator,
                    .success = false,
                    .diagnostics = diagnostics,
                } };
            }

            const restart = self.cycle.server_fresh or self.cycle.client_fresh;
            if (!self.first_build_done) {
                self.first_build_done = true;
                self.previous_had_errors = false;
                return .{ .should_restart = duration_ms };
            }
            if (restart) {
                self.previous_had_errors = false;
                return .{ .should_restart = duration_ms };
            }
            if (self.cycle.assets_fresh) {
                const files = self.cycle.asset_paths.toOwnedSlice(self.allocator) catch &.{};
                self.cycle.asset_paths = .empty;
                if (self.previous_had_errors) self.previous_had_errors = false;
                return .{ .assets_installed = .{
                    .allocator = self.allocator,
                    .files = files,
                    .build_duration_ms = duration_ms,
                } };
            }
            if (self.previous_had_errors) {
                self.previous_had_errors = false;
                return .resolved;
            }
            return .{ .build_complete_no_change = duration_ms };
        },
        .bsp_configuration => {
            // Hot reload of configuration is not needed for zx dev yet.
            log.warn("ignoring mid-session bsp_configuration", .{});
            return null;
        },
        else => {
            log.warn("unexpected bsp message: {t}", .{tag});
            return null;
        },
    }
}

fn cycleDurationMs(self: *const Bsp) u64 {
    const started = self.cycle_started_at orelse return 0;
    const now = Io.Timestamp.now(self.io, .awake);
    return @intCast(started.durationTo(now).toMilliseconds());
}

fn rememberAssetPath(self: *Bsp, step_name: []const u8) !void {
    const web_path = assetWebPath(step_name) orelse return;
    const owned = try self.allocator.dupe(u8, web_path);
    errdefer self.allocator.free(owned);
    try self.cycle.asset_paths.append(self.allocator, owned);
}

fn appendErrorBundle(self: *Bsp, eb: *const std.zig.ErrorBundle) !void {
    if (eb.errorMessageCount() == 0) return;
    for (eb.getMessages()) |msg_index| {
        const msg = eb.getErrorMessage(msg_index);
        const message = try self.allocator.dupe(u8, eb.nullTerminatedString(msg.msg));
        errdefer self.allocator.free(message);

        var file: []const u8 = "";
        var line: u32 = 0;
        var col: u32 = 0;
        var source_line: ?[]const u8 = null;
        if (msg.src_loc != .none) {
            const src = eb.getSourceLocation(msg.src_loc);
            file = try self.allocator.dupe(u8, eb.nullTerminatedString(src.src_path));
            line = src.line + 1;
            col = src.column + 1;
            if (src.source_line != 0) {
                source_line = try self.allocator.dupe(u8, eb.nullTerminatedString(src.source_line));
            }
        } else {
            file = try self.allocator.dupe(u8, "");
        }
        errdefer self.allocator.free(file);
        errdefer if (source_line) |sl| self.allocator.free(sl);

        try self.cycle.diagnostics.append(self.allocator, .{
            .file = file,
            .line = line,
            .col = col,
            .kind = .@"error",
            .message = message,
            .source_line = source_line,
        });

        for (eb.getNotes(msg_index)) |note_index| {
            const note = eb.getErrorMessage(note_index);
            const note_msg = try self.allocator.dupe(u8, eb.nullTerminatedString(note.msg));
            errdefer self.allocator.free(note_msg);
            var note_file: []const u8 = "";
            var note_line: u32 = 0;
            var note_col: u32 = 0;
            if (note.src_loc != .none) {
                const src = eb.getSourceLocation(note.src_loc);
                note_file = try self.allocator.dupe(u8, eb.nullTerminatedString(src.src_path));
                note_line = src.line + 1;
                note_col = src.column + 1;
            } else {
                note_file = try self.allocator.dupe(u8, file);
            }
            errdefer self.allocator.free(note_file);
            try self.cycle.diagnostics.append(self.allocator, .{
                .file = note_file,
                .line = note_line,
                .col = note_col,
                .kind = .note,
                .message = note_msg,
            });
        }
    }
}

fn isServerStep(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "server") != null;
}

fn isClientStep(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "client") != null;
}

fn isAssetStep(name: []const u8) bool {
    return std.mem.eql(u8, name, "install public/") or
        std.mem.eql(u8, name, "install assets/") or
        std.mem.startsWith(u8, name, "install public") or
        std.mem.startsWith(u8, name, "install assets");
}

fn assetWebPath(step_name: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, step_name, "public")) |_| return "/";
    if (std.mem.indexOf(u8, step_name, "assets")) |_| return "/assets/";
    return null;
}

fn freeDiagnostics(allocator: Allocator, diagnostics: *std.ArrayList(Diagnostic)) void {
    for (diagnostics.items) |d| {
        allocator.free(d.file);
        allocator.free(d.message);
        if (d.source_line) |sl| allocator.free(sl);
        if (d.caret_line) |cl| allocator.free(cl);
    }
    diagnostics.clearRetainingCapacity();
}

fn freeEvent(event: *Event) void {
    switch (event.*) {
        .errors => |*r| r.deinit(),
        .assets_installed => |*a| a.deinit(),
        else => {},
    }
}
