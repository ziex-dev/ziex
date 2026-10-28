const std = @import("std");
const std_cli = @import("std_cli");
const zx_info = @import("zx_info");

const Colors = @import("../../tui/Colors.zig");
const context = @import("context.zig");

const Command = std_cli.Command;
const Argument = std_cli.Argument;

pub const Options = struct {
    // Printed before the descent path in the usage line, e.g. "zx" or "zx app".
    prefix: []const u8 = "zx",
    color: bool = false,
};

pub fn useColor(app: *const context.AppContext) bool {
    if (app.environ_map.get("NO_COLOR")) |v| if (v.len > 0) return false;
    if (app.environ_map.get("FORCE_COLOR")) |v| if (v.len > 0) return true;
    return std.Io.File.stdout().isTty(app.io) catch false;
}

// Bun-style help for the active (deepest parsed) command.
pub fn write(comptime command: Command, parsed: std_cli.Parsed(command), out: *std.Io.Writer, opts: Options) std.Io.Writer.Error!void {
    return writeActive(command, std_cli.descentPath(command, parsed), parsed, out, opts);
}

fn writeActive(
    comptime command: Command,
    path: []const [:0]const u8,
    parsed: std_cli.Parsed(command),
    out: *std.Io.Writer,
    opts: Options,
) std.Io.Writer.Error!void {
    if (parsed.subcommand) |sub| switch (sub) {
        inline else => |value, tag| inline for (command.subcommands) |c| {
            if (comptime std.mem.eql(u8, @tagName(c.name), @tagName(tag))) return writeActive(c, path, value, out, opts);
        },
    };
    return writeCommand(command, path, out, opts);
}

pub fn writeCommand(comptime command: Command, path: []const [:0]const u8, out: *std.Io.Writer, opts: Options) std.Io.Writer.Error!void {
    const is_root = comptime std.mem.eql(u8, @tagName(command.name), "zx");
    const p: Painter = .{ .out = out, .color = opts.color };

    const description = comptime std.mem.trim(u8, if (command.help.len > 0) command.help else command.help_short, " \r\n");
    if (description.len > 0) {
        if (comptime is_root and std.mem.startsWith(u8, description, "Ziex")) {
            try p.paint(Colors.bold ++ Colors.green, "Ziex");
            try out.writeAll(description["Ziex".len..]);
        } else try out.writeAll(description);
        if (is_root) try p.paint(Colors.dim, " (" ++ zx_info.version ++ ")");
        try out.writeAll("\n\n");
    }

    try p.paint(Colors.bold, "Usage:");
    try out.writeAll(" ");
    if (opts.color) try out.writeAll(Colors.bold);
    try out.writeAll(opts.prefix);
    if (path.len > 1) for (path[1..]) |cmd| try out.print(" {s}", .{cmd});
    if (command.subcommands.len > 0) try out.writeAll(" <command>");
    if (opts.color) try out.writeAll(Colors.reset);
    try out.writeAll(" ");
    try p.paint(Colors.cyan, "[...flags]");
    const positional = comptime positionalUsage(command);
    if (positional.len > 0) {
        try out.writeAll(" ");
        try p.paint(Colors.blue, positional);
    }
    try out.writeAll("\n");

    if (command.subcommands.len > 0) {
        try out.writeAll("\n");
        try p.paint(Colors.bold, "Commands:");
        try out.writeAll("\n");
        try writeRows(comptime commandRows(command) ++ [_]Row{ .{}, .{
            .label = styled(Colors.bold ++ Colors.blue, "<command>").cat(raw(" ")).cat(styled(Colors.dim, "--help")),
            .help = "Print help text for command.",
        } }, out, opts.color);
    }

    const arg_rows = comptime argumentRows(command);
    if (arg_rows.len > 0) {
        try out.writeAll("\n");
        try p.paint(Colors.bold, "Arguments:");
        try out.writeAll("\n");
        try writeRows(arg_rows, out, opts.color);
    }

    try out.writeAll("\n");
    try p.paint(Colors.bold, "Flags:");
    try out.writeAll("\n");
    try writeRows(comptime flagRows(command), out, opts.color);

    if (is_root) {
        try out.writeAll("\n");
        try writeFooter(p, "Learn more about Ziex:", "https://ziex.dev/learn");
        try writeFooter(p, "Join our Discord community:", "https://ziex.dev/r/discord");
    }
}

fn writeFooter(p: Painter, comptime label: []const u8, comptime url: []const u8) !void {
    try p.out.writeAll(comptime label ++ spaces(32 - label.len));
    try p.paint(Colors.purple, url);
    try p.out.writeAll("\n");
}

const Painter = struct {
    out: *std.Io.Writer,
    color: bool,

    fn paint(self: Painter, comptime code: []const u8, comptime s: []const u8) !void {
        try self.out.writeAll(if (self.color) code ++ s ++ Colors.reset else s);
    }
};

// Same text with and without ANSI styling; `plain.len` is the display width.
const Text = struct {
    plain: []const u8 = "",
    ansi: []const u8 = "",

    fn cat(comptime a: Text, comptime b: Text) Text {
        return .{ .plain = a.plain ++ b.plain, .ansi = a.ansi ++ b.ansi };
    }
};

fn raw(comptime s: []const u8) Text {
    return .{ .plain = s, .ansi = s };
}

fn styled(comptime code: []const u8, comptime s: []const u8) Text {
    return .{ .plain = s, .ansi = if (s.len == 0) "" else code ++ s ++ Colors.reset };
}

fn spaces(comptime n: usize) []const u8 {
    const s: [n]u8 = @splat(' ');
    return &s;
}

fn pad(comptime n: usize) Text {
    return raw(spaces(n));
}

// An empty row renders as a blank separator line.
const Row = struct {
    label: Text = .{},
    help: []const u8 = "",
    default: []const u8 = "",
};

fn writeRows(comptime rows: []const Row, out: *std.Io.Writer, color: bool) !void {
    const width = comptime blk: {
        var w: usize = 0;
        for (rows) |r| w = @max(w, r.label.plain.len);
        break :blk w + 4;
    };
    inline for (rows) |row| {
        if (row.label.plain.len == 0) {
            try out.writeAll("\n");
            continue;
        }
        try out.writeAll("  ");
        try out.writeAll(if (color) row.label.ansi else row.label.plain);
        var lines = std.mem.tokenizeAny(u8, row.help, "\r\n");
        var first = true;
        while (lines.next()) |line| : (first = false) {
            if (!first) try out.writeAll("\n  ");
            try out.splatByteAll(' ', if (first) width - row.label.plain.len else width);
            try out.writeAll(line);
        }
        if (row.default.len > 0) {
            if (first) try out.splatByteAll(' ', width - row.label.plain.len) else try out.writeAll(" ");
            if (color) try out.writeAll(Colors.dim);
            try out.writeAll("(default: " ++ row.default ++ ")");
            if (color) try out.writeAll(Colors.reset);
        }
        try out.writeAll("\n");
    }
}

fn commandRows(comptime command: Command) []const Row {
    @setEvalBranchQuota(100_000);
    var name_width: usize = 0;
    for (command.subcommands) |c| name_width = @max(name_width, @tagName(c.name).len);

    var rows: []const Row = &.{};
    for (command.subcommands) |c| {
        if (c.hidden) continue;
        const name = @tagName(c.name);
        const usage = if (c.subcommands.len > 0) "<command>" else positionalUsage(c);
        rows = rows ++ [_]Row{.{
            .label = styled(Colors.bold ++ Colors.green, name).cat(pad(name_width - name.len + 2)).cat(styled(Colors.dim, usage)),
            .help = c.help_short,
        }};
    }
    return rows;
}

fn argumentRows(comptime command: Command) []const Row {
    @setEvalBranchQuota(100_000);
    var rows: []const Row = &.{};
    for (command.positional_args) |arg| {
        if (arg.hidden) continue;
        rows = rows ++ [_]Row{.{
            .label = styled(Colors.blue, positionalName(arg)),
            .help = arg.help,
            .default = defaultText(arg),
        }};
    }
    return rows;
}

fn flagRows(comptime command: Command) []const Row {
    @setEvalBranchQuota(100_000);
    var rows: []const Row = &.{};
    for (command.named_args) |arg| {
        if (arg.hidden) continue;
        const Value = switch (arg.count) {
            .one => arg.type,
            .unlimited => std.meta.Child(arg.type),
        };
        const Base = switch (@typeInfo(Value)) {
            .optional => |o| o.child,
            else => Value,
        };
        const short: Text = if (arg.short) |c| styled(Colors.cyan, "-" ++ [_]u8{c}).cat(raw(", ")) else pad(4);
        const long: Text = switch (@typeInfo(Base)) {
            .bool => if (defaultText(arg).len > 0)
                styled(Colors.cyan, "--[no-]" ++ arg.name)
            else
                styled(Colors.cyan, "--" ++ arg.name),
            .@"enum" => styled(Colors.cyan, "--" ++ arg.name).cat(styled(Colors.dim, "=<" ++ enumNames(Base) ++ ">")),
            else => styled(Colors.cyan, "--" ++ arg.name).cat(styled(Colors.dim, "=<val>")),
        };
        rows = rows ++ [_]Row{.{ .label = short.cat(long), .help = arg.help, .default = defaultText(arg) }};
    }
    return rows ++ [_]Row{.{
        .label = styled(Colors.cyan, "-h").cat(raw(", ")).cat(styled(Colors.cyan, "--help")),
        .help = "Display this menu and exit",
    }};
}

fn positionalName(comptime arg: Argument) []const u8 {
    const rest = if (arg.count == .unlimited) "..." else "";
    return if (arg.isOptional()) "[" ++ arg.name ++ rest ++ "]" else "<" ++ arg.name ++ rest ++ ">";
}

fn positionalUsage(comptime command: Command) []const u8 {
    var s: []const u8 = "";
    for (command.positional_args) |arg| {
        if (arg.hidden) continue;
        s = s ++ (if (s.len > 0) " " else "") ++ positionalName(arg);
    }
    return s;
}

fn enumNames(comptime E: type) []const u8 {
    var s: []const u8 = "";
    for (@typeInfo(E).@"enum".field_names, 0..) |name, i| s = s ++ (if (i > 0) "|" else "") ++ name;
    return s;
}

// Empty for zero-ish defaults (false, 0, "", null), which read as "unset",
// and when the help text already documents its default.
fn defaultText(comptime arg: Argument) []const u8 {
    if (arg.count == .unlimited or std.mem.indexOf(u8, arg.help, "default") != null) return "";
    const value = arg.attrs.defaultValue(arg.type) orelse return "";
    return switch (@typeInfo(arg.type)) {
        .bool => if (value) "true" else "",
        .int, .float => if (value == 0) "" else std.fmt.comptimePrint("{d}", .{value}),
        .pointer => if (value.len == 0) "" else "\"" ++ value ++ "\"",
        .@"enum" => @tagName(value),
        else => "",
    };
}
