const zx = @import("zx");
const Context = @import("Context.zig");
const site_opts = @import("site_opts");

const context: Context = .{ .port = 5588 };
const config: zx.AppConfig = .{ .server = .{ .port = context.port } };

pub fn main(init: zx.Init) !void {
    var app = try zx.App.init(init, zx.io(), zx.allocator, config, context);
    defer app.deinit();

    if (comptime site_opts.use_dusty and zx.platform.isServer() and zx.platform.os != .wasi) {
        const Dusty = @import("server/Dusty.zig");
        const dusty_server = try Dusty.Backend(Context).init(zx.io(), zx.allocator, app.config, context, init);
        dusty_server.info();
        app.server = dusty_server.server();
    }

    try app.start();
}

pub const std_options = zx.std_options;
