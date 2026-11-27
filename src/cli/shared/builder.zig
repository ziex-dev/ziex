const std = @import("std");
const tui = @import("../../tui/main.zig");
const Colors = tui.Colors;
const log = std.log.scoped(.cli);

const RESTART_COOLDOWN_NS = std.time.ns_per_ms * 10;

pub const BuildStats = struct {
    max_duration_ms: u64,

    pub fn init() BuildStats {
        return .{ .max_duration_ms = 0 };
    }

    /// Parse duration from string like "6s", "123ms", "45us", "1m"
    fn parseDuration(text: []const u8) ?u64 {
        if (text.len < 2) return null;

        // Find where the number ends and unit begins
        var num_end: usize = 0;
        while (num_end < text.len) : (num_end += 1) {
            const c = text[num_end];
            if (!std.ascii.isDigit(c) and c != '.') break;
        }

        if (num_end == 0) return null;

        const num_str = text[0..num_end];
        const unit = text[num_end..];

        const value = std.fmt.parseFloat(f64, num_str) catch return null;

        // Convert to milliseconds
        const ms = if (std.mem.eql(u8, unit, "s"))
            value * 1000.0
        else if (std.mem.eql(u8, unit, "ms"))
            value
        else if (std.mem.eql(u8, unit, "us"))
            value / 1000.0
        else if (std.mem.eql(u8, unit, "ns"))
            value / 1_000_000.0
        else if (std.mem.eql(u8, unit, "m"))
            value * 60_000.0
        else if (std.mem.eql(u8, unit, "h"))
            value * 3_600_000.0
        else
            return null;

        return @intFromFloat(ms);
    }

    /// Update stats by parsing a line from build summary
    pub fn parseLine(self: *BuildStats, line: []const u8) void {
        // Look for duration indicators: "6s", "123ms", etc.
        // They appear after status words like "success", "cached", "failure"
        var it = std.mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |token| {
            if (parseDuration(token)) |duration_ms| {
                if (duration_ms > self.max_duration_ms) {
                    self.max_duration_ms = duration_ms;
                    log.debug("Found build duration: {d}ms from '{s}'", .{ duration_ms, token });
                }
            }
        }
    }
};

pub const BuildWatcher = struct {
    allocator: std.mem.Allocator,
    builder_stderr: std.fs.File,
    should_restart: bool,
    mutex: std.Thread.Mutex,
    first_build_done: bool,
    restart_pending: bool,
    last_restart_time_ns: i128,
    binary_path: []const u8,
    last_binary_mtime: i128,
    build_stats: BuildStats, // Parsed build statistics
    build_output: std.ArrayList(u8), // Buffered build output for current build
    current_build_has_errors: bool, // Whether the current build has errors
    error_output_ready: bool, // Whether error output is ready to be displayed
    previous_build_had_errors: bool, // Whether the previous build had errors
    show_resolved_message: bool, // Whether to show "errors resolved" message

    pub fn init(
        allocator: std.mem.Allocator,
        builder_stderr: std.fs.File,
        binary_path: []const u8,
        initial_mtime: i128,
    ) BuildWatcher {
        return .{
            .allocator = allocator,
            .builder_stderr = builder_stderr,
            .should_restart = false,
            .mutex = .{},
            .first_build_done = false,
            .restart_pending = false,
            .last_restart_time_ns = 0,
            .binary_path = binary_path,
            .last_binary_mtime = initial_mtime,
            .build_stats = BuildStats.init(),
            .build_output = std.ArrayList(u8).empty,
            .current_build_has_errors = false,
            .error_output_ready = false,
            .previous_build_had_errors = false,
            .show_resolved_message = false,
        };
    }

    pub fn getBuildDurationMs(self: *BuildWatcher) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.build_stats.max_duration_ms;
    }

    pub fn shouldRestart(self: *BuildWatcher) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.should_restart;
        self.should_restart = false;
        return result;
    }

    pub fn markRestartComplete(self: *BuildWatcher, new_mtime: i128) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.restart_pending = false;
        self.last_restart_time_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
        self.last_binary_mtime = new_mtime;
    }

    /// Check if there are errors to display and return the output
    /// Returns the error output once, then clears the flag
    pub fn checkErrors(self: *BuildWatcher) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.error_output_ready and self.build_output.items.len > 0) {
            self.error_output_ready = false;
            return self.build_output.items;
        }
        return null;
    }

    /// Check if we should show the "errors resolved" message
    pub fn shouldShowResolvedMessage(self: *BuildWatcher) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.show_resolved_message;
        self.show_resolved_message = false;
        return result;
    }

    pub fn deinit(self: *BuildWatcher) void {
        self.build_output.deinit(self.allocator);
    }
};

pub fn watchBuildOutput(watcher: *BuildWatcher) !void {
    var buf: [8192]u8 = undefined;
    var pattern_buf = std.ArrayList(u8).empty;
    defer pattern_buf.deinit(watcher.allocator);
    var line_buf = std.ArrayList(u8).empty;
    defer line_buf.deinit(watcher.allocator);
    var build_in_progress = false;

    log.debug("Build watcher thread started", .{});

    while (true) {
        const bytes_read = watcher.builder_stderr.read(&buf) catch |err| {
            if (err == error.EndOfStream) break;
            log.debug("Error reading stderr: {any}", .{err});
            continue;
        };
        if (bytes_read == 0) break;

        const chunk = buf[0..bytes_read];

        // Detect start of new build (any output after first build means new build starting)
        if (watcher.first_build_done and !build_in_progress) {
            build_in_progress = true;
            watcher.mutex.lock();
            watcher.build_stats = BuildStats.init();
            watcher.build_output.clearRetainingCapacity();
            watcher.current_build_has_errors = false;
            watcher.error_output_ready = false;
            watcher.mutex.unlock();
            log.debug("New build started", .{});
        }

        // Capture all output for error display
        watcher.mutex.lock();
        try watcher.build_output.appendSlice(watcher.allocator, chunk);
        watcher.mutex.unlock();

        // Check for error indicators in the output
        if (std.mem.find(u8, chunk, "error:") != null or
            std.mem.find(u8, chunk, "Error:") != null or
            std.mem.find(u8, chunk, "stderr") != null or
            std.mem.find(u8, chunk, "ERROR:") != null)
        {
            watcher.mutex.lock();
            watcher.current_build_has_errors = true;
            watcher.mutex.unlock();
            log.debug("Error detected in build output", .{});
        }

        // Process bytes line by line to parse build stats
        for (chunk) |byte| {
            if (byte == '\n') {
                if (line_buf.items.len > 0) {
                    watcher.mutex.lock();
                    watcher.build_stats.parseLine(line_buf.items);
                    watcher.mutex.unlock();
                }
                line_buf.clearRetainingCapacity();
            } else {
                try line_buf.append(watcher.allocator, byte);
            }
        }

        // Accumulate to detect "Build Summary:"
        try pattern_buf.appendSlice(watcher.allocator, chunk);

        if (pattern_buf.items.len > 1024) {
            const keep_from = pattern_buf.items.len - 512;
            @memmove(pattern_buf.items[0..512], pattern_buf.items[keep_from..]);
            pattern_buf.shrinkRetainingCapacity(512);
        }

        // Detect build completion via "Build Summary:"
        if (std.mem.find(u8, pattern_buf.items, "Build Summary:") != null) {
            const now = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
            log.debug("Build Summary detected", .{});

            const stat = std.Io.Dir.cwd().statFile(watcher.binary_path) catch |err| {
                log.debug("Failed to stat binary: {any}", .{err});
                pattern_buf.clearRetainingCapacity();
                build_in_progress = false;
                continue;
            };

            watcher.mutex.lock();
            defer watcher.mutex.unlock();

            const binary_changed = stat.mtime != watcher.last_binary_mtime;

            if (watcher.first_build_done) {
                // Build completed
                if (binary_changed and !watcher.restart_pending) {
                    // Binary changed - successful build, trigger restart
                    const time_since_last_restart = now - watcher.last_restart_time_ns;
                    if (time_since_last_restart >= RESTART_COOLDOWN_NS) {
                        watcher.should_restart = true;
                        watcher.restart_pending = true;
                        watcher.last_binary_mtime = stat.mtime;
                        log.debug("Build successful, triggering restart", .{});
                    }
                } else if (watcher.current_build_has_errors) {
                    // Build failed with errors - make output ready to display
                    watcher.error_output_ready = true;
                    log.debug("Build failed with errors, output ready to display", .{});
                } else if (!watcher.current_build_has_errors and !binary_changed) {
                    // Build completed without errors and no binary change (cached success)
                    // Check if previous build had errors - if so, show resolved message
                    if (watcher.previous_build_had_errors) {
                        watcher.show_resolved_message = true;
                        log.debug("Build cached successfully after errors, will show resolved message", .{});
                    }
                }

                // Check if errors were just resolved (current success after previous errors with binary change)
                if (binary_changed and watcher.previous_build_had_errors and !watcher.current_build_has_errors) {
                    watcher.show_resolved_message = true;
                    log.debug("Errors resolved with new build, will show resolved message", .{});
                }

                // Update previous build error state
                watcher.previous_build_had_errors = watcher.current_build_has_errors;
            } else {
                // First build
                watcher.first_build_done = true;
                watcher.last_binary_mtime = stat.mtime;
                watcher.last_restart_time_ns = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
                watcher.previous_build_had_errors = watcher.current_build_has_errors;
                log.debug("First build completed", .{});
            }

            pattern_buf.clearRetainingCapacity();
            build_in_progress = false;
        }
    }
}
