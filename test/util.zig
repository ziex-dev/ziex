pub const TestFileCache = struct {
    files: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    pub const test_files = [_][]const u8{
        // Control Flow
        "control_flow/if",
        "control_flow/if_error",
        "control_flow/if_block",

        "control_flow/if_only",
        "control_flow/if_only_block",

        "control_flow/for",
        "control_flow/for_block",

        "control_flow/switch",
        "control_flow/switch_capture",
        "control_flow/switch_multicaseval",
        "control_flow/switch_block",

        "control_flow/while",
        "control_flow/while_block",

        // Nested Control Flow (2-level nesting)
        "control_flow/if_if",
        "control_flow/if_for",
        "control_flow/if_switch",
        "control_flow/if_while",
        "control_flow/if_if_only",
        "control_flow/if_if_only_block",
        "control_flow/if_else_if",
        "control_flow/if_capture",

        "control_flow/for_if",
        "control_flow/for_for",
        "control_flow/for_switch",
        "control_flow/for_while",

        "control_flow/switch_if",
        "control_flow/switch_for",
        "control_flow/switch_switch",
        "control_flow/switch_while",

        "control_flow/while_if",
        "control_flow/while_for",
        "control_flow/while_switch",
        "control_flow/while_while",
        "control_flow/while_capture",
        "control_flow/while_else",
        "control_flow/while_error",

        // Deeply Nested Control Flow (3-level nesting)
        "control_flow/if_for_if",
        "control_flow/if_while_if",

        // Expression
        "expression/text",
        "expression/text_lifetime",
        "expression/sibling_space",
        "expression/format",
        "expression/component",
        "expression/mixed",
        "expression/struct_access",
        "expression/function_call",
        "expression/multiline_string",

        // Component
        "component/basic",
        "component/multiple",
        "component/nested",
        "component/children_only",
        "component/contexted",
        "component/contexted_props",
        "component/csr_zig",
        "component/import",
        "component/root_cmp",
        "component/caching",
        "component/zx_collision",

        // Attribute
        "attribute/builtin",
        "attribute/component",
        "attribute/builtin_escaping",
        "attribute/dynamic",
        "attribute/types",
        "attribute/shorthand",
        "attribute/spread",

        // Element
        "element/void",
        "element/empty",
        "element/nested",
        "element/fragment",
        "element/fragment_root",
        "element/whitespace",

        // Expression
        "expression/optional",
        "expression/template",

        // Raw
        "escaping/pre",
        "escaping/quotes",
    };
    pub fn init(allocator: std.mem.Allocator) !TestFileCache {
        loadEnvFlags();

        var cache = TestFileCache{
            .files = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };

        const base_path = "test/data/";

        // Load .zx and .zig files for each test file
        for (test_files) |file_path| {
            for ([_]struct { ext: []const u8 }{ .{ .ext = ".zx" }, .{ .ext = ".zig" } }) |ext_info| {
                const full_path = try allocator.print("{s}{s}{s}", .{ base_path, file_path, ext_info.ext });
                defer allocator.free(full_path);

                const content = std.Io.Dir.cwd().readFileAlloc(
                    std.testing.io,
                    full_path,
                    allocator,
                    .limited(std.math.maxInt(usize)),
                ) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                const cache_key = try allocator.print("{s}{s}", .{ file_path, ext_info.ext });
                try cache.files.put(cache_key, content);
            }
        }

        return cache;
    }

    pub fn deinit(self: *TestFileCache) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit();
    }

    pub fn get(self: *TestFileCache, path: []const u8) !?[]const u8 {
        // Check if file is already in cache
        if (self.files.get(path)) |content| {
            return content;
        }

        // File not in cache, try to fetch it from disk
        const base_path = "test/data/";
        const full_path = try self.allocator.print("{s}{s}", .{ base_path, path });
        defer self.allocator.free(full_path);

        const content = std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            full_path,
            self.allocator,
            .limited(std.math.maxInt(usize)),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

        // Cache the file for future calls
        const cache_key = try self.allocator.print("{s}", .{path});
        try self.files.put(cache_key, content);

        return content;
    }
};

const EnvFlags = struct {
    slow: bool = false,
    network: bool = false,
    snapshot: bool = false,
    sm_debug: bool = false,
    loaded: bool = false,
};

var env_flags: EnvFlags = .{};

pub fn loadEnvFlags() void {
    if (env_flags.loaded) return;
    env_flags.slow = testing.environ.containsConstant("E2E");
    env_flags.network = testing.environ.containsConstant("E2E_NET");
    env_flags.snapshot = testing.environ.containsConstant("SS");
    env_flags.sm_debug = testing.environ.containsConstant("SM_DEBUG");
    env_flags.loaded = true;
}

pub fn shouldRunSlowTest() bool {
    return env_flags.slow;
}

pub fn shouldRunNetworkTest() bool {
    return env_flags.network;
}

pub fn isSnapshotMode() bool {
    return env_flags.snapshot;
}

pub fn shouldGenerateDebugFiles() bool {
    return env_flags.sm_debug;
}

/// Prints a perf line prefixed with ⏲, dimming ` > ` and ` | ` separators like the test runner.
pub fn perf(comptime format: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, format, args) catch format;
    std.debug.print("\x1b[33m⏲\x1b[0m ", .{});
    var start: usize = 0;
    var i: usize = 0;
    while (i + 3 <= line.len) {
        const sep = line[i..][0..3];
        if (std.mem.eql(u8, sep, " > ") or std.mem.eql(u8, sep, " | ")) {
            std.debug.print("{s} \x1b[90m{c}\x1b[0m ", .{ line[start..i], sep[1] });
            i += 3;
            start = i;
        } else i += 1;
    }
    std.debug.print("{s}\n", .{line[start..]});
}

/// Throughput for perf prints. Formats as MB/s when ≥ 1 MB/s, otherwise KB/s (SI units).
pub const Throughput = struct {
    bytes: u64,
    elapsed_ns: u64,

    pub fn init(bytes: u64, elapsed_ns: u64) Throughput {
        return .{ .bytes = bytes, .elapsed_ns = elapsed_ns };
    }

    pub fn format(self: Throughput, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const secs = @as(f64, @floatFromInt(self.elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        const bytes_per_s = if (secs > 0)
            @as(f64, @floatFromInt(self.bytes)) / secs
        else
            0.0;
        if (bytes_per_s >= 1_000_000.0) {
            try w.print("{d:.2} MB/s", .{bytes_per_s / 1_000_000.0});
        } else {
            try w.print("{d:.2} KB/s", .{bytes_per_s / 1_000.0});
        }
    }
};

const std = @import("std");
const testing = std.testing;
const zx = @import("zx");
