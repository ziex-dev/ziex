const Server = @This();

const std = @import("std");

pub const Std = @import("Server/Std.zig");
pub const Wasm = @import("Server/Wasm.zig");
pub const Httpz = @import("Server/Httpz.zig");

pub const Pipeline = @import("Server/Pipeline.zig");
pub const PubSub = Pipeline.PubSub;
pub const Config = Pipeline.Config;
pub const AccessLog = @import("Server/AccessLog.zig");
pub const Devtool = @import("Server/Devtool.zig");
pub const Handler = @import("Router/Handler.zig");

userdata: ?*anyopaque = null,
vtable: *const VTable,

pub const VTable = struct {
    start: *const fn (userdata: ?*anyopaque) anyerror!void,
    stop: *const fn (userdata: ?*anyopaque) void,
    deinit: *const fn (userdata: ?*anyopaque) void,
    info: *const fn (userdata: ?*anyopaque) void,
};

/// Forwarding vtable for backends that expose `start` / `stop` / `deinit` / `info` on `*T`.
pub fn bind(comptime T: type) VTable {
    return .{
        .start = struct {
            fn call(userdata: ?*anyopaque) anyerror!void {
                try cast(T, userdata).start();
            }
        }.call,
        .stop = struct {
            fn call(userdata: ?*anyopaque) void {
                cast(T, userdata).stop();
            }
        }.call,
        .deinit = struct {
            fn call(userdata: ?*anyopaque) void {
                cast(T, userdata).deinit();
            }
        }.call,
        .info = struct {
            fn call(userdata: ?*anyopaque) void {
                cast(T, userdata).info();
            }
        }.call,
    };
}

fn cast(comptime T: type, userdata: ?*anyopaque) *T {
    return @ptrCast(@alignCast(userdata.?));
}

pub fn start(self: Server) !void {
    return self.vtable.start(self.userdata);
}

pub fn stop(self: Server) void {
    self.vtable.stop(self.userdata);
}

pub fn deinit(self: *Server) void {
    self.vtable.deinit(self.userdata);
    self.* = failing;
}

pub fn info(self: Server) void {
    self.vtable.info(self.userdata);
}

fn failStart(_: ?*anyopaque) anyerror!void {
    return error.AppUnavailable;
}
fn failStop(_: ?*anyopaque) void {}
fn failDeinit(_: ?*anyopaque) void {}
fn failInfo(_: ?*anyopaque) void {}

pub const failing_vtable = VTable{
    .start = &failStart,
    .stop = &failStop,
    .deinit = &failDeinit,
    .info = &failInfo,
};

pub const failing: Server = .{ .vtable = &failing_vtable };
