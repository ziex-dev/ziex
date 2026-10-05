const App = @import("../App.zig");
const impl = @import("../../client/Client.zig");

pub const Client = impl.Client;

pub const run = impl.Client.run;

pub fn server() App.Server {
    return .{ .userdata = null, .vtable = &vtable };
}

fn start(_: ?*anyopaque) anyerror!void {
    return impl.Client.run();
}

const vtable = App.Server.VTable{
    .start = &start,
    .stop = App.Server.failing_vtable.stop,
    .deinit = App.Server.failing_vtable.deinit,
    .info = App.Server.failing_vtable.info,
};
