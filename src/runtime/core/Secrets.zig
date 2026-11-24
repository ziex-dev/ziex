// Read-only secret store, exposed at runtime as `zx.secrets`.
//
// Defaults: native reads the process env merged with `.env` files;
// WASI reads the host environ, then host secret bindings.
// Swap it for any backend (AWS Secrets Manager, Vault, ...) by assigning `zx.secrets`.
const Secrets = @This();

const std = @import("std");

userdata: ?*anyopaque = null,
vtable: *const VTable,

pub const Env = @import("Secrets/Env.zig");
pub const Wasm = @import("Secrets/Wasm.zig");
pub const Chain = @import("Secrets/Chain.zig");
pub const dotenv = @import("Secrets/dotenv.zig");

pub const VTable = struct {
    // Caller owns the returned value; null when the secret doesn't exist.
    get: *const fn (userdata: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]u8,
};

pub const Error = error{ SecretNotFound, Unavailable };

pub fn get(self: Secrets, allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return self.vtable.get(self.userdata, allocator, name);
}

pub fn require(self: Secrets, allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return try self.get(allocator, name) orelse {
        std.log.scoped(.zx_secrets).err("missing secret: {s}", .{name});
        return error.SecretNotFound;
    };
}

fn failingGet(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?[]u8 {
    return error.Unavailable;
}

fn emptyGet(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!?[]u8 {
    return null;
}

pub const failing = Secrets{ .vtable = &.{ .get = &failingGet } };
pub const empty = Secrets{ .vtable = &.{ .get = &emptyGet } };
