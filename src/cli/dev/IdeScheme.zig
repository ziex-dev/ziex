const std = @import("std");

const CodeEditorScheme = @This();

name: []const u8,
args: []const []const u8,
/// environment keys that must exist OR matches "KEY=VALUE" (value can have *)
envs: []const []const u8,

pub fn match(self: CodeEditorScheme, env_map: *const std.process.Environ.Map) bool {
    if (self.envs.len == 0) return false;

    for (self.envs) |env_spec| {
        if (std.mem.indexOfScalar(u8, env_spec, '=')) |eq_idx| {
            const key = env_spec[0..eq_idx];
            const pattern = env_spec[eq_idx + 1 ..];
            const val = env_map.get(key) orelse return false;

            if (std.mem.startsWith(u8, pattern, "*") and std.mem.endsWith(u8, pattern, "*")) {
                const inner = pattern[1 .. pattern.len - 1];
                if (std.mem.indexOf(u8, val, inner) == null) return false;
            } else if (std.mem.startsWith(u8, pattern, "*")) {
                const inner = pattern[1..];
                if (!std.mem.endsWith(u8, val, inner)) return false;
            } else if (std.mem.endsWith(u8, pattern, "*")) {
                const inner = pattern[0 .. pattern.len - 1];
                if (!std.mem.startsWith(u8, val, inner)) return false;
            } else {
                if (!std.mem.eql(u8, val, pattern)) return false;
            }
        } else {
            // Just check if key exists
            if (env_map.get(env_spec) == null) return false;
        }
    }
    return true;
}

pub fn format(self: CodeEditorScheme, allocator: std.mem.Allocator, file: []const u8, line: []const u8, col: []const u8) ![]const []const u8 {
    var args_list = std.ArrayList([]const u8).empty;

    for (self.args) |arg| {
        var new_arg = try allocator.dupe(u8, arg);
        new_arg = try replaceAll(allocator, new_arg, "{file}", file);
        new_arg = try replaceAll(allocator, new_arg, "{line}", line);
        new_arg = try replaceAll(allocator, new_arg, "{col}", col);
        try args_list.append(allocator, new_arg);
    }
    return args_list.toOwnedSlice(allocator);
}

// Detect editor and return command args to open file
pub fn detect(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, file: []const u8, line: []const u8, col: []const u8) ![]const []const u8 {
    // 1. ZIEX_EDITOR override (e.g., "zed --open {file}:{line}:{col}")
    if (env_map.get("ZIEX_EDITOR")) |editor_cmd| {
        var args_list = std.ArrayList([]const u8).empty;
        var it = std.mem.tokenizeAny(u8, editor_cmd, " \t");
        while (it.next()) |token| {
            var arg = try allocator.dupe(u8, token);
            arg = try replaceAll(allocator, arg, "{file}", file);
            arg = try replaceAll(allocator, arg, "{line}", line);
            arg = try replaceAll(allocator, arg, "{col}", col);
            try args_list.append(allocator, arg);
        }
        if (args_list.items.len > 0) return try args_list.toOwnedSlice(allocator);
    }

    // 2. Auto-detect from environment using schema system
    for (EDITORS) |scheme| {
        if (scheme.match(env_map)) {
            return scheme.format(allocator, file, line, col);
        }
    }

    // Default to 'code' if nothing else matches
    var args = try allocator.alloc([]const u8, 3);
    args[0] = try allocator.dupe(u8, "code");
    args[1] = try allocator.dupe(u8, "-g");
    args[2] = try allocator.print("{s}:{s}:{s}", .{ file, line, col });
    return args;
}

fn replaceAll(allocator: std.mem.Allocator, input: []const u8, pattern: []const u8, replacement: []const u8) ![]u8 {
    const size = std.mem.replacementSize(u8, input, pattern, replacement);
    const output = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, input, pattern, replacement, output);
    allocator.free(input); // free previous string (used for chained replacement)
    return output;
}

pub const EDITORS = [_]CodeEditorScheme{
    .{
        .name = "Antigravity",
        .args = &.{ "agy", "-g", "{file}:{line}:{col}" },
        .envs = &.{ "TERM_PROGRAM=vscode", "VSCODE_GIT_ASKPASS_NODE=*Antigravity*" },
    },
    .{
        .name = "Cursor",
        .args = &.{ "cursor", "-g", "{file}:{line}:{col}" },
        .envs = &.{ "TERM_PROGRAM=vscode", "VSCODE_GIT_ASKPASS_NODE=*Cursor*" },
    },
    .{
        .name = "VS Code",
        .args = &.{ "code", "-g", "{file}:{line}:{col}" },
        .envs = &.{"TERM_PROGRAM=vscode"},
    },
    .{
        .name = "Zed",
        .args = &.{ "zed", "{file}:{line}:{col}" },
        .envs = &.{"ZED_TERM"},
    },
    .{
        .name = "IntelliJ IDEA",
        .args = &.{ "idea", "--line", "{line}", "--column", "{col}", "{file}" },
        .envs = &.{"TERMINAL_EMULATOR=JetBrains*"},
    },
    .{
        .name = "Emacs",
        .args = &.{ "emacsclient", "-n", "+{line}:{col} {file}" },
        .envs = &.{"INSIDE_EMACS"},
    },
    .{
        .name = "Vim",
        .args = &.{ "vim", "+{line}", "{file}" },
        .envs = &.{"VIM"},
    },
    .{
        .name = "Vim (Runtime)",
        .args = &.{ "vim", "+{line}", "{file}" },
        .envs = &.{"VIMRUNTIME"},
    },
};
