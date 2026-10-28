const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const std_cli = @import("std_cli");

const context = @import("shared/context.zig");
const tui = @import("../tui/main.zig");
const version = @import("version.zig");
const init = @import("init.zig");
const dev = @import("dev.zig");
const serve = @import("serve.zig");
const build_cmd = @import("build.zig");
const transpile = @import("transpile.zig");
const app_cmd = @import("app.zig");
const fmt = @import("fmt.zig");
const diagnose = @import("diagnose.zig");
const env = @import("env.zig");
const lsp = @import("lsp.zig");
const bundle = @import("bundle.zig");
const update = @import("update.zig");
const upgrade = @import("upgrade.zig");
const cli_args = @import("root.zig");
const help = @import("shared/help.zig");

pub const AppContext = context.AppContext;
pub const CommandContext = context.CommandContext;
pub const root_command = cli_args.root_command;
pub const commands = cli_args.commands;

const Spinner = tui.Spinner;

const use_debug_allocator = builtin.optimize == .debug and switch (builtin.os.tag) {
    .wasi, .freestanding => false,
    else => true,
};

const os_modules = switch (builtin.os.tag) {
    .wasi, .freestanding => .{ version, dev, transpile, fmt, diagnose, lsp },
    else => .{ version, init, app_cmd, dev, serve, build_cmd, transpile, fmt, diagnose, env, lsp, bundle, update, upgrade },
};

pub fn main(init_process: std.process.Init) !void {
    if (comptime build_options.enable_lsp) {
        @import("../lsp/transport/Message.zig").setEnvironMap(init_process.environ_map);
    }

    var dbg: if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void =
        if (use_debug_allocator) .init else {};
    defer if (comptime use_debug_allocator) std.debug.assert(dbg.deinit() == .ok);

    const allocator: std.mem.Allocator = if (comptime use_debug_allocator)
        dbg.allocator()
    else switch (builtin.os.tag) {
        .wasi, .freestanding => std.heap.wasm_allocator,
        else => std.heap.smp_allocator,
    };

    if (comptime builtin.os.tag == .windows) {
        _ = SetConsoleOutputCP(65001);
    }

    var stdout_writer = std.Io.File.stdout().writerStreaming(init_process.io, &.{});
    const stdout = &stdout_writer.interface;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init_process.io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    var app_ctx: AppContext = .{
        .io = init_process.io,
        .environ_map = init_process.environ_map,
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const args = try init_process.minimal.args.toSlice(arena_state.allocator());

    try run(stdout, stdin, allocator, args, &app_ctx);
    try stdout.flush();
}

pub fn run(
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    app: *AppContext,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std_cli.parseAlloc(root_command, arena, args, .{
        .exit_usage_error = true,
        .render_usage_errors = true,
        .exit_help = false,
        .render_help = .none,
    });

    if (parsed.subcommand == null and parsed.kind == .args and parsed.kind.args.version) {
        try writer.print("{s}\n", .{@import("zx_info").version});
        return;
    }

    if (std_cli.helpWanted(parsed) or parsed.subcommand == null) {
        // Ignore broken pipes, e.g. `zx --help | head`.
        help.write(root_command, parsed, writer, .{ .color = help.useColor(app) }) catch {};
        return;
    }

    const is_wasm = builtin.cpu.arch.isWasm();
    var spinner: if (is_wasm) void else Spinner = if (is_wasm) {} else .init(writer, reader, allocator, .{});
    defer if (!is_wasm) spinner.deinit();
    if (!is_wasm) spinner.interactive = std.Io.File.stdout().isTty(app.io) catch false;

    const ctx: CommandContext = .{
        .allocator = allocator,
        .writer = writer,
        .reader = reader,
        .spinner = if (is_wasm) {} else &spinner,
        .app = app,
    };

    switch (parsed.subcommand.?) {
        inline else => |s, tag| inline for (os_modules) |mod| {
            if (comptime std.mem.eql(u8, @tagName(mod.command.name), @tagName(tag))) {
                if (comptime mod.command.subcommands.len > 0) {
                    return mod.run(ctx, s);
                } else switch (s.kind) {
                    .help => unreachable,
                    .args => |cmd_args| return mod.run(ctx, cmd_args),
                }
            }
        },
    }
}

comptime {
    if ((builtin.os.tag == .wasi or builtin.os.tag == .freestanding) and build_options.enable_lsp) {
        _ = @import("../lsp/transport/Message.zig");
    }
}

extern "kernel32" fn SetConsoleOutputCP(wCodePageID: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;

pub const std_options = std.Options{
    // Windows client disconnects surface as error.Unexpected, which would dump a trace on every reload.
    .unexpected_error_tracing = builtin.os.tag != .windows,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .cli, .level = @fromBackingInt(@intCast(build_options.log_level)) },
        .{ .scope = .devserver, .level = @fromBackingInt(@intCast(build_options.log_level)) },
        .{ .scope = .builder, .level = @fromBackingInt(@intCast(build_options.log_level)) },
        .{ .scope = .builder_bsp, .level = @fromBackingInt(@intCast(build_options.log_level)) },
        .{ .scope = .builder_cli, .level = @fromBackingInt(@intCast(build_options.log_level)) },
    },
};
