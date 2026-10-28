// Docs tables built from the framework's own types, so they can't drift from the code.
// Every public field needs a description; a missing or stale one is a compile error.

pub const Field = struct {
    name: []const u8,
    type_name: []const u8,
    default: ?[]const u8 = null,
    doc: []const u8,
};

// Shared descriptions; `overrides` in `fields` wins where a field means something else.
const common = .{
    .request = "Incoming request: headers, cookies, query, route params, and body.",
    .response = "Outgoing response: status, headers, cookies, and body.",
    .allocator = "App-lifetime allocator. Nothing is freed for you; prefer `arena` unless the memory must outlive the request.",
    .arena = "Request-scoped allocator, freed after the response is sent. Use it for most allocations.",
    .io = "The app's `std.Io`, for files, networking, sleeping, and timers.",
    .data = "Request-scoped key/value store (`ctx.data.set` / `ctx.data.get`). Pages run first, so they can set values such as the title for layouts to read.",
    .socket = "WebSocket handle: `upgrade`, `send`, `subscribe`, `unsubscribe`, `publish`.",
    .rendering = "How the route renders: `.prerendered`, `.request`, `.streamed`, or individual fields. Pages inherit it from the nearest layout when null.",
    .caching = "Cache the rendered output, for example `.{ .ttl = .fromSeconds(300) }`. See Caching.",
    .static = "Function that lists the params of a dynamic route to pre-render with `--static` or `--prerender`.",
};

pub const page_context = fields(zx.PageContext, .{});
pub const error_context = fields(zx.ErrorContext, .{
    .err = "The error returned by the page or route handler.",
});
pub const route_context = fields(zx.RouteContext, .{});
pub const proxy_context = fields(zx.ProxyContext, .{});
pub const socket_context = fields(zx.SocketContext, .{
    .message = "The received message: `.text` or `.binary`.",
    .data = "The value passed to `ctx.socket.upgrade(data)`. Use `zx.SocketCtx(T)` to type it.",
    .arena = "Allocator freed after this message is handled.",
});
pub const component_context = fields(zx.ComponentCtx(Props), .{
    .props = "The component's props; `void` for `zx.ComponentContext`.",
    .allocator = "Allocator for this render. On the server it is the request arena, so it is freed after the response.",
    .children = "Content passed between the component's tags, or null.",
});

pub const page_options = fields(zx.PageOptions, .{
    .methods = "HTTP methods the page answers. Add `.POST` for pages that handle form actions.",
});
pub const layout_options = fields(zx.LayoutOptions, .{
    .rendering = "Default rendering for every page below this layout. A page's own setting wins.",
});
pub const route_options = fields(zx.RouteOptions, .{
    .rendering = "Only `prerender` and `dynamic` apply. Not inherited from layouts.",
});
pub const notfound_options = fields(zx.NotFoundOptions, .{});

pub fn fields(comptime T: type, comptime overrides: anytype) []const Field {
    comptime {
        const info = @typeInfo(T).@"struct";
        var out: []const Field = &.{};
        for (info.field_names, info.field_types, info.field_attrs) |name, FieldType, attrs| {
            if (name[0] == '_') continue;
            const doc = if (@hasField(@TypeOf(overrides), name))
                @field(overrides, name)
            else if (@hasField(@TypeOf(common), name))
                @field(common, name)
            else
                @compileError("docs: no description for " ++ @typeName(T) ++ "." ++ name);
            const default: ?[]const u8 = if (attrs.default_value_ptr != null)
                defaultLabel(FieldType, attrs.defaultValue(FieldType).?)
            else
                null;
            out = out ++ [_]Field{.{ .name = name, .type_name = typeLabel(FieldType), .default = default, .doc = doc }};
        }
        for (@typeInfo(@TypeOf(overrides)).@"struct".field_names) |name| {
            if (!@hasField(T, name)) @compileError("docs: " ++ @typeName(T) ++ " has no field '" ++ name ++ "'");
        }
        const frozen = out[0..out.len].*;
        return &frozen;
    }
}

// The name users write for `T`, e.g. `?zx.PageOptions.Rendering` instead of the internal path.
pub fn typeLabel(comptime T: type) []const u8 {
    comptime {
        for (known) |entry| {
            if (entry[0] == T) return entry[1];
        }
        return switch (@typeInfo(T)) {
            .optional => |o| "?" ++ typeLabel(o.child),
            .pointer => |p| switch (p.size) {
                .one => "*" ++ (if (p.attrs.@"const") "const " else "") ++ typeLabel(p.child),
                .slice => "[]" ++ (if (p.attrs.@"const") "const " else "") ++ typeLabel(p.child),
                else => @typeName(T),
            },
            else => @typeName(T),
        };
    }
}

// Stands in for a user's props type in `zx.ComponentCtx(Props)`.
const Props = struct {};

const known = .{
    .{ Props, "Props" },
    .{ std.mem.Allocator, "std.mem.Allocator" },
    .{ std.Io, "std.Io" },
    .{ zx.Component, "zx.Component" },
    .{ zx.http.Request, "zx.http.Request" },
    .{ zx.http.Response, "zx.http.Response" },
    .{ zx.PageData, "zx.PageData" },
    .{ zx.Socket, "zx.Socket" },
    .{ zx.WebSocket.Message, "zx.WebSocket.Message" },
    .{ zx.StaticFn, "zx.StaticFn" },
    .{ zx.PageOptions.Rendering, "zx.PageOptions.Rendering" },
    .{ zx.PageOptions.Method, "zx.PageOptions.Method" },
    .{ zx.BuiltinAttribute.Caching, "zx.BuiltinAttribute.Caching" },
};

fn defaultLabel(comptime T: type, comptime value: T) []const u8 {
    comptime {
        return switch (@typeInfo(T)) {
            .optional => |o| if (value) |v| defaultLabel(o.child, v) else "null",
            .bool => if (value) "true" else "false",
            .int, .comptime_int => std.fmt.comptimePrint("{d}", .{value}),
            .@"enum" => "." ++ @tagName(value),
            .pointer => |p| if (p.size == .slice) blk: {
                var label: []const u8 = "&.{";
                for (value, 0..) |item, i| label = label ++ (if (i == 0) " " else ", ") ++ defaultLabel(p.child, item);
                break :blk label ++ (if (value.len > 0) " }" else "}");
            } else "…",
            .@"struct" => ".{}",
            else => "…",
        };
    }
}

const std = @import("std");
const zx = @import("zx");
