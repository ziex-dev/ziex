const std = @import("std");
const builtin = @import("builtin");

const zx = @import("root.zig");
const prp = @import("util/props.zig");

const ElementTag = zx.ElementTag;
const Allocator = std.mem.Allocator;
const BuiltinAttribute = zx.BuiltinAttribute;

const is_debug = builtin.optimize == .debug;

pub const Component = union(enum) {
    none,
    text: []const u8,
    element: Element,
    component_fn: ComponentFn,

    pub const ComponentFn = struct {
        pub const Caller = *const fn (data: ?*const anyopaque, allocator: Allocator, owner_id: ?[]const u8) anyerror!Component;
        pub const Destroyer = *const fn (data: ?*const anyopaque, allocator: Allocator) void;

        pub const VTable = struct {
            call: Caller,
            destroy: Destroyer,
        };

        /// DevTool related debug information
        pub const Dev = struct {
            dump_props: *const fn (allocator: Allocator, data: ?*const anyopaque) ?[]const u8 = undefined,
            source_file: ?[]const u8 = null,
            source_line: u32 = 0,
        };

        /// Client-island hydration boundary (null = plain server/client component).
        pub const Island = struct {
            id: []const u8,
            /// Pre-serialized ZXON props for the hydration marker.
            props: ?[]const u8 = null,
            /// SSR-rendered content for hydration.
            children: *const Component,
        };

        vtable: *const VTable,
        data: ?*const anyopaque,

        dev: if (is_debug) Dev else void = if (is_debug) .{} else {},

        id: zx.x.Id = .undef,
        allocator: Allocator,
        island: ?Island = null,
        caching: ?BuiltinAttribute.Caching = null,

        name: []const u8,
        key: ?[]const u8 = null,

        // TODO: get the name from inside the InitOptions @src() passed to x.init
        pub fn init(comptime func: anytype, name: []const u8, allocator: Allocator, props: anytype) ComponentFn {
            const FuncInfo = @typeInfo(@TypeOf(func));
            const param_count = FuncInfo.@"fn".param_types.len;
            const fn_name = @typeName(@TypeOf(func));

            const fn_signature = std.fmt.comptimePrint("fn {s} {s}", .{ "", fn_name["fn ".len..] });

            // Validation of parameters
            if (param_count != 1 and param_count != 2)
                @compileError(std.fmt.comptimePrint("{s} must have 1 or 2 parameters found {d} parameters", .{ fn_name, param_count }));

            const FirstPropType = FuncInfo.@"fn".param_types[0].?;
            const first_is_allocator = FirstPropType == std.mem.Allocator;
            const first_is_ctx_ptr = @typeInfo(FirstPropType) == .pointer and
                @hasField(@typeInfo(FirstPropType).pointer.child, "allocator") and
                @hasField(@typeInfo(FirstPropType).pointer.child, "children");

            if (!first_is_allocator and !first_is_ctx_ptr)
                @compileError("Component " ++ fn_signature ++ " must have allocator or *ComponentCtx as the first parameter");

            // If two parameters are passed with allocator first, the props type must be a struct
            if (first_is_allocator and param_count == 2) {
                const SecondPropType = FuncInfo.@"fn".param_types[1].?;
                if (@typeInfo(SecondPropType) != .@"struct")
                    @compileError("Component " ++ fn_name ++ " must have a struct as the second parameter, found " ++ @typeName(SecondPropType));
            }

            // Context-based components should only have 1 parameter
            if (first_is_ctx_ptr and param_count != 1)
                @compileError("Component " ++ fn_signature ++ " with *ComponentCtx must have exactly 1 parameter");

            // Allocate props on heap to persist
            const data = if (first_is_allocator and param_count == 2) blk: {
                const SecondPropType = FuncInfo.@"fn".param_types[1].?;
                const coerced = prp.coerce(SecondPropType, props);
                const p = allocator.create(SecondPropType) catch @panic("OOM");
                p.* = coerced;
                break :blk p;
            } else if (first_is_ctx_ptr) blk: {
                // Contexted components
                const CtxType = @typeInfo(FirstPropType).pointer.child;
                const ctx = allocator.create(CtxType) catch @panic("OOM");
                // allocator.create() does NOT run field default initializers, so explicitly
                // set all fields that ComponentCtx defines with defaults.
                ctx.allocator = allocator;
                ctx.io = zx.Io.default();
                if (@hasField(CtxType, "_internal")) ctx._internal = .{};
                ctx.children = if (@hasField(@TypeOf(props), "children")) props.children else null;
                if (@hasField(CtxType, "props")) {
                    const PropsFieldType = @FieldType(CtxType, "props");
                    if (PropsFieldType != void) {
                        ctx.props = prp.coerce(PropsFieldType, props);
                    }
                }
                break :blk ctx;
            } else null;

            const Wrapper = struct {
                /// Normalize any return type (Component, ?Component, !Component, !?Component) to anyerror!Component
                fn normalize(result: anytype) anyerror!Component {
                    const T = @TypeOf(result);
                    if (T == Component) {
                        return result;
                    }
                    // ?Component -> return .none if null
                    if (@typeInfo(T) == .optional) {
                        return result orelse .none;
                    }
                    // !Component or !?Component
                    if (@typeInfo(T) == .error_union) {
                        const payload = try result;
                        // Check if payload is optional
                        if (@typeInfo(@TypeOf(payload)) == .optional) {
                            return payload orelse .none;
                        }
                        return payload;
                    }
                    return result;
                }

                fn callImpl(erased: ?*const anyopaque, alloc: Allocator, owner_id: ?[]const u8) anyerror!Component {
                    if (first_is_ctx_ptr) {
                        const CtxType = @typeInfo(FirstPropType).pointer.child;
                        const ctx_ptr: *CtxType = @ptrCast(@alignCast(@constCast(erased orelse @panic("ctx is null"))));
                        // Reset slot counters on every call so hooks run in stable order.
                        if (@hasField(CtxType, "_internal")) {
                            ctx_ptr._internal.state_idx = 0;
                            if (owner_id) |oid| ctx_ptr._internal.component_id = oid;
                        }
                        return normalize(func(ctx_ptr));
                    }
                    if (first_is_allocator and param_count == 1) {
                        return normalize(func(alloc));
                    }
                    if (first_is_allocator and param_count == 2) {
                        const SecondPropType = FuncInfo.@"fn".param_types[1].?;
                        const p = erased orelse @panic("props data is null for function with props");
                        const typed_p: *const SecondPropType = @ptrCast(@alignCast(p));
                        return normalize(func(alloc, typed_p.*));
                    }
                    unreachable;
                }

                fn destroyImpl(erased: ?*const anyopaque, alloc: Allocator) void {
                    if (first_is_ctx_ptr) {
                        const CtxType = @typeInfo(FirstPropType).pointer.child;
                        const ctx_ptr: *CtxType = @ptrCast(@alignCast(@constCast(erased orelse return)));
                        alloc.destroy(ctx_ptr);
                        return;
                    }
                    if (first_is_allocator and param_count == 2) {
                        const SecondPropType = FuncInfo.@"fn".param_types[1].?;
                        const p = erased orelse @panic("props data is null for function with props");
                        const typed_p: *const SecondPropType = @ptrCast(@alignCast(p));
                        alloc.destroy(typed_p);
                    }
                }

                fn dumpPropsImpl(alloc: Allocator, erased: ?*const anyopaque) ?[]const u8 {
                    const ptr = erased orelse return null;
                    if (first_is_allocator and param_count == 2) {
                        const SecondPropType = FuncInfo.@"fn".param_types[1].?;
                        const typed_p: *const SecondPropType = @ptrCast(@alignCast(ptr));
                        return prp.jsonDevtool(alloc, typed_p.*);
                    }
                    if (first_is_ctx_ptr) {
                        const CtxType = @typeInfo(FirstPropType).pointer.child;
                        const ctx_ptr: *const CtxType = @ptrCast(@alignCast(ptr));
                        if (@hasField(CtxType, "props")) {
                            const PropsT = @FieldType(CtxType, "props");
                            if (PropsT != void) return prp.jsonDevtool(alloc, ctx_ptr.props);
                        }
                    }
                    return null;
                }

                const vtable: VTable = .{
                    .call = callImpl,
                    .destroy = destroyImpl,
                };
            };

            return .{
                .data = data,
                .vtable = &Wrapper.vtable,
                .allocator = allocator,
                .name = name,
                .key = keyFromProps(allocator, props),
                .dev = if (comptime is_debug) .{ .dump_props = Wrapper.dumpPropsImpl } else {},
            };
        }

        pub fn call(self: ComponentFn) anyerror!Component {
            return self.vtable.call(self.data, self.allocator, null);
        }

        pub fn callOwned(self: ComponentFn, owner_id: []const u8) anyerror!Component {
            return self.vtable.call(self.data, self.allocator, owner_id);
        }

        pub fn isIsland(self: ComponentFn) bool {
            return self.island != null;
        }

        pub fn deinit(self: ComponentFn) void {
            if (self.island) |island| {
                self.allocator.free(island.id);
                self.allocator.free(self.name);
                if (island.props) |hp| self.allocator.free(hp);
            }
            if (self.key) |key| self.allocator.free(key);
            self.vtable.destroy(self.data, self.allocator);
        }
    };

    pub fn deinit(self: Component, allocator: std.mem.Allocator) void {
        switch (self) {
            .element => |elem| {
                if (elem.children) |children| {
                    for (children) |child| {
                        child.deinit(allocator);
                    }
                    allocator.free(children);
                }
                if (elem.attributes) |attributes| {
                    allocator.free(attributes);
                }
            },
            .component_fn => |func| {
                func.deinit();
            },
            .none => {},
            .text => {},
        }
    }

    //TODO: Move these to runtime/server
    pub const render = @import("runtime/server/render.zig").render;
    pub const stream = @import("runtime/server/render.zig").stream;
};

fn keyFromProps(allocator: Allocator, props: anytype) ?[]const u8 {
    if (!@hasField(@TypeOf(props), "key")) return null;
    return allocator.print("{any}", .{@field(props, "key")}) catch null;
}

pub const Element = struct {
    pub const Attribute = struct {
        name: []const u8,
        value: ?[]const u8 = null,
        handler: ?zx.EventHandler = null,
    };

    tag: ElementTag,
    /// Set when `tag == .custom` (hyphenated web component name).
    custom_tag: ?[]const u8 = null,
    children: ?[]const Component = null,
    attributes: ?[]const Element.Attribute = null,

    escaping: ?BuiltinAttribute.Escaping = .html,
    async: ?BuiltinAttribute.Async = .sync,
    fallback: ?*const Component = null,

    /// HTML/DOM tag name used for createElement / SSR.
    pub fn htmlTagName(self: Element) []const u8 {
        if (self.tag == .custom) return self.custom_tag orelse "div";
        return @tagName(self.tag);
    }
};
