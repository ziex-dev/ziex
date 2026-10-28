const Action = @This();

const std = @import("std");
const zx = @import("../../root.zig");
const Request = @import("../core/http/Request.zig");
const Response = @import("../core/http/Response.zig");
const CoreEvent = @import("../core/Event.zig");
const File = @import("../core/http/File.zig");

const StateContext = CoreEvent.StateContext;
const Allocator = std.mem.Allocator;

request: Request = undefined,
response: Response = undefined,
allocator: Allocator = undefined,
arena: Allocator = undefined,

_internal: Internal = .{},

pub const Internal = struct {
    action_ref: u64 = 0,
    state_ctx: ?*StateContext = null,
    inputs: ?[]const []const u8 = null,
};

pub fn init(action_ref: u64) Action {
    return .{ ._internal = .{ .action_ref = action_ref } };
}

pub fn data(self: Action, comptime T: type) T {
    comptime if (@typeInfo(T) != .@"struct") @compileError("ctx.data() requires a struct type, got: " ++ @typeName(T));

    const content_type = self.request.headers.get("content-type") orelse "";
    var result: T = undefined;
    const type_struct = @typeInfo(T).@"struct";

    if (std.mem.indexOf(u8, content_type, "multipart/form-data") != null) {
        const mfd = self.request.multiFormData();
        inline for (type_struct.field_names, type_struct.field_types) |field_name, field_type| {
            if (comptime field_type == File) {
                const val = mfd.get(field_name);
                @field(result, field_name) = if (val) |v| File.fromBytes(v.data, v.filename orelse "", "", self.arena) else File{};
            } else if (comptime field_type == ?File) {
                const val = mfd.get(field_name);
                @field(result, field_name) = if (val) |v| File.fromBytes(v.data, v.filename orelse "", "", self.arena) else null;
            } else {
                @field(result, field_name) = parseFormField(field_type, mfd.getValue(field_name), self.arena);
            }
        }
    } else {
        const fd = self.request.formData();
        inline for (type_struct.field_names, type_struct.field_types) |field_name, field_type| {
            if (comptime field_type == File or field_type == ?File) {
                @field(result, field_name) = if (comptime field_type == File) File{} else null;
            } else {
                @field(result, field_name) = parseFormField(field_type, fd.get(field_name), self.arena);
            }
        }
    }

    return result;
}

/// Stateful server action - provides `state()` access to bound component state.
/// Use `fn(*zx.server.Action.Stateful) void` with `ctx.bind()` to get this type.
pub const Stateful = struct {
    inner: *Action,

    /// Access the component's state (server-side).
    /// Must be called in the same order as `ctx.state()` in the render function.
    pub fn state(self: *Stateful, comptime T: type) CoreEvent.StateHandle(T) {
        return self.inner._internal.state_ctx.?.state(T);
    }

    /// Parse form data from the action request into struct type T.
    pub fn data(self: *Stateful, comptime T: type) T {
        return self.inner.data(T);
    }

    pub fn fmt(self: Stateful, comptime format: []const u8, args: anytype) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.inner._internal.state_ctx.?.arena);
        defer aw.deinit();
        aw.writer.print(format, args) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        return aw.toOwnedSlice();
    }
};

fn parseFormField(comptime T: type, raw: ?[]const u8, allocator: Allocator) T {
    _ = allocator;
    switch (@typeInfo(T)) {
        .optional => |opt| return parseFormField(opt.child, raw orelse return null, undefined),
        .pointer => {
            comptime if (T != []const u8) @compileError("ctx.data(): unsupported pointer type: " ++ @typeName(T));
            return raw orelse "";
        },
        .bool => {
            const val = raw orelse return false;
            return std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "on");
        },
        .int => return std.fmt.parseInt(T, raw orelse return 0, 10) catch 0,
        .float => return std.fmt.parseFloat(T, raw orelse return 0) catch 0,
        else => @compileError("ctx.data(): unsupported field type '" ++ @typeName(T) ++ "'"),
    }
}
