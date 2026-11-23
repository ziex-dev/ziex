comptime {
    @setEvalBranchQuota(100_000);
}

const std = @import("std");
const build_options = @import("build_options");
const lsp = @import("lsp");
const Handler = @import("Handler.zig");
const Message = @import("transport/Message.zig");
const CommandContext = @import("../cli/shared/context.zig").CommandContext;

pub const RunOptions = struct {
    messages: []const []const u8 = &.{},
    zx_module: ?[]const u8 = null,
};

pub fn run(ctx: CommandContext, options: RunOptions) !void {
    if (options.messages.len > 0) {
        try Message.runMessages(options.messages, ctx.writer, ctx.app.environ_map);
        return;
    }
    try runStdio(ctx, options.zx_module);
}

fn runStdio(ctx: CommandContext, zx_module: ?[]const u8) !void {
    const gpa = ctx.allocator;
    const io = ctx.app.io;
    const environ_map = ctx.app.environ_map;

    @setEvalBranchQuota(100_000);

    var read_buffer: [256]u8 = undefined;
    var stdio_transport: lsp.Transport.Stdio = .init(&read_buffer, .stdin(), .stdout());
    // Writes come from the request loop and from background `zx check` runs.
    var safe_transport: lsp.ThreadSafeTransport(.{ .thread_safe_read = false, .thread_safe_write = true }) = .init(&stdio_transport.transport);
    const transport: *lsp.Transport = &safe_transport.transport;

    var handler: Handler = .init(gpa, transport, io);
    defer handler.deinit();
    handler.checker.environ_map = environ_map;

    if (comptime Handler.Zls.enabled) {
        const backing = try Handler.Zls.create(.{
            .allocator = gpa,
            .io = io,
            .transport = transport,
            .environ_map = environ_map,
            .zx_module = zx_module,
        });
        handler.setBacking(backing.ptr, backing.vtable);
    }

    lsp.basic_server.run(
        io,
        gpa,
        transport,
        &handler,
        std.log.err,
    ) catch |err| {
        if (err != error.EndOfStream) {
            return err;
        }
    };
}
