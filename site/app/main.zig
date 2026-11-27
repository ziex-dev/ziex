const zx = @import("zx");
const Context = @import("Context.zig");
const site_opts = @import("site_opts");

const context: Context = .{ .port = 5588 };
const config: zx.AppConfig = .{};

pub fn main(init: zx.Init) !void {
    if (comptime site_opts.use_dusty and zx.platform.isServer() and zx.platform.os != .wasi) {
        const zio = @import("zio");
        const Dusty = @import("server/Dusty.zig");

        const rt = try zio.Runtime.init(zx.allocator, .{});
        defer rt.deinit();
        const io = rt.io();

        var app = try zx.App.init(init, io, zx.allocator, config, context);
        defer app.deinit();

        const dusty_server = try Dusty.Backend(Context).init(io, zx.allocator, app.config, context, init);
        dusty_server.info();
        app.server = dusty_server.server();
        try app.start();
        return;
    }

    var app = try zx.App.init(init, zx.Io.default(), zx.allocator, config, context);
    defer app.deinit();
    try app.start();
}

pub const std_options = zx.std_options;
