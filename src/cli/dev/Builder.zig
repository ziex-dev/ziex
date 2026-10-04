/// Dev-mode build watcher.
///
/// Backends:
/// - `Builder.Bsp` — `zig build --listen=-` (Build Server Protocol)
/// - `Builder.Cli` — scrape `zig build --watch` stderr (legacy, CLI backend)
const Builder = @This();

const std = @import("std");

userdata: ?*anyopaque = null,
vtable: *const VTable,

pub const Bsp = @import("Builder/bsp.zig");
pub const Cli = @import("Builder/cli.zig");

/// Backend used by `zx dev` unless overridden.
pub const default = Bsp;

pub const VTable = struct {
    deinit: *const fn (userdata: ?*anyopaque, io: std.Io) void,
    kill: *const fn (userdata: ?*anyopaque, io: std.Io) void,
    /// Block until the next event. `null` means the builder process closed.
    next: *const fn (userdata: ?*anyopaque, io: std.Io) anyerror!?Event,
    child: *const fn (userdata: ?*anyopaque) *std.process.Child,
};

pub const DiagKind = enum { @"error", warning, note };

pub const Diagnostic = struct {
    file: []const u8,
    line: u32,
    col: u32,
    kind: DiagKind,
    message: []const u8,
    source_line: ?[]const u8 = null,
    caret_line: ?[]const u8 = null,
};

pub const BuildResult = struct {
    allocator: std.mem.Allocator,
    success: bool,
    diagnostics: []Diagnostic,

    pub fn deinit(self: *BuildResult) void {
        for (self.diagnostics) |d| {
            if (d.file.len > 0) self.allocator.free(d.file);
            if (d.message.len > 0) self.allocator.free(d.message);
            if (d.source_line) |sl| self.allocator.free(sl);
            if (d.caret_line) |cl| self.allocator.free(cl);
        }
        self.allocator.free(self.diagnostics);
    }
};

pub const AssetChange = struct {
    allocator: std.mem.Allocator,
    files: []const []const u8, // web-relative paths like "/favicon.ico", "/assets/styles.css"
    build_duration_ms: u64,

    pub fn deinit(self: *AssetChange) void {
        for (self.files) |f| self.allocator.free(f);
        self.allocator.free(self.files);
    }
};

pub const Event = union(enum) {
    change_detected,
    should_restart: u64,
    errors: BuildResult,
    resolved,
    build_complete_no_change: u64,
    assets_installed: AssetChange,
};

pub const StepStatus = enum { success, cached, failure };

pub const InitOptions = struct {
    allocator: std.mem.Allocator,
    /// Base `zig build …` argv (without `--watch` / `--listen`).
    argv: []const []const u8,
    environ_map: ?*std.process.Environ.Map = null,
    pgid: ?std.posix.pid_t = null,
};

pub fn deinit(self: Builder, io: std.Io) void {
    self.vtable.deinit(self.userdata, io);
}

pub fn kill(self: Builder, io: std.Io) void {
    self.vtable.kill(self.userdata, io);
}

pub fn next(self: Builder, io: std.Io) !?Event {
    return self.vtable.next(self.userdata, io);
}

pub fn child(self: Builder) *std.process.Child {
    return self.vtable.child(self.userdata);
}

// --- Shared helpers (used by CLI parsing, diagnostics formatting, tests) ---

pub const BuildState = Cli.BuildState;
pub const parseDiagnostic = Cli.parseDiagnostic;
pub const parseInstallStatus = Cli.parseInstallStatus;
pub const parseAssetDirStatus = Cli.parseAssetDirStatus;
pub const parseStatusWord = Cli.parseStatusWord;
pub const parseUserAssetInstall = Cli.parseUserAssetInstall;
pub const parseDurationMs = Cli.parseDurationMs;
pub const stripTreePrefix = Cli.stripTreePrefix;
pub const stripAnsiInPlace = Cli.stripAnsiInPlace;
pub const isBuildCommandLine = Cli.isBuildCommandLine;
pub const isBuildCommandForOs = Cli.isBuildCommandForOs;

pub fn formatDiagnostics(allocator: std.mem.Allocator, diagnostics: []const Diagnostic) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    for (diagnostics) |d| {
        const kind_str: []const u8 = switch (d.kind) {
            .@"error" => "error",
            .warning => "warning",
            .note => "note",
        };
        const line = try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}: {s}\n", .{
            d.file, d.line, d.col, kind_str, d.message,
        });
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
        if (d.source_line) |sl| {
            try buf.appendSlice(allocator, sl);
            try buf.append(allocator, '\n');
        }
        if (d.caret_line) |cl| {
            try buf.appendSlice(allocator, cl);
            try buf.append(allocator, '\n');
        }
    }
    return buf.toOwnedSlice(allocator);
}
