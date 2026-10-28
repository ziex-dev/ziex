const std = @import("std");
const builtin = @import("builtin");

const zx = @import("root.zig");
const prp = @import("util/props.zig");

const ElementTag = zx.ElementTag;
const Element = zx.Element;
const Allocator = std.mem.Allocator;
const BuiltinAttribute = zx.BuiltinAttribute;
const Component = zx.Component;
const ElementAttribute = zx.Element.Attribute;
const reactivity = zx.client.reactivity;
pub const ComponentClientOptions = struct {
    name: []const u8,
    id: []const u8,
};

const Options = struct {
    children: ?[]const Component = null,
    attributes: ?[]const Element.Attribute = null,
    allocator: ?std.mem.Allocator = null,
    escaping: ?BuiltinAttribute.Escaping = .html,
    async: ?BuiltinAttribute.Async = .sync,
    fallback: ?*const Component = null,
    caching: ?BuiltinAttribute.Caching = null,
    client: ?ComponentClientOptions = null,
    /// Real tag name when `tag == .custom` (web components).
    custom_tag: ?[]const u8 = null,
    /// The component's display name (e.g. "FeatureCard"), emitted by the
    /// transpiler. This is authoritative: `@src().fn_name` cannot be used here
    /// because it resolves to the enclosing function, not the component.
    name: ?[]const u8 = null,
};

pub const ComptimeOptions = struct {
    src: ?std.builtin.SourceLocation = null,
};

pub const InitOptions = struct {
    src: ?std.builtin.SourceLocation = null,
};

fn componentId(comptime options: InitOptions) Id {
    return if (options.src) |src| Id.extendId(null, src, 0) else .undef;
}

/// Initialize a Context without an allocator.
/// The allocator must be provided via `@allocator` on a parent element.
pub fn init(comptime options: InitOptions) Context {
    return .{ .allocator = null, .component_id = componentId(options) };
}

/// Initialize a Context with an allocator (for backward compatibility with direct API usage)
pub fn allocInit(allocator: std.mem.Allocator, comptime options: InitOptions) Context {
    return .{ .allocator = allocator, .component_id = componentId(options) };
}

/// Context for creating components with allocator support
const Context = struct {
    allocator: ?std.mem.Allocator = null,
    component_id: Id = .undef,

    pub fn getAlloc(self: *Context) std.mem.Allocator {
        return self.allocator orelse {
            std.log.err(
                \\No allocator set for ZX element construction.
                \\Pass an allocator with `@allocator={{...}}` (or shorthand `@{{allocator}}`) on this element or a parent.
            ,
                .{},
            );
            @panic("Allocator not set. Provide @allocator on the parent element.");
        };
    }

    pub fn ele(self: *Context, tag: ElementTag, options: Options) Component {
        // Set allocator from @allocator option if provided
        if (options.allocator) |allocator| {
            self.allocator = allocator;
        }
        _ = self.getAlloc();
        return .{ .element = .{
            .tag = tag,
            .custom_tag = options.custom_tag,
            .children = options.children,
            .attributes = options.attributes,
            .escaping = options.escaping,
            .async = options.async,
            .fallback = options.fallback,
        } };
    }

    /// Create a text node by borrowing `text` (no copy).
    ///
    /// Escaping happens at render time into the output writer.
    ///
    /// Lifetime: `text` must outlive the component tree
    pub fn txt(_: *Context, text: anytype) Component {
        return .{ .text = textSlice(text) };
    }

    pub fn expr(self: *Context, val: anytype) Component {
        const T = @TypeOf(val);

        if (T == Component) return val;

        if (comptime isStatePointer(T)) return self.expr(val.get());

        const Cmp = switch (@typeInfo(T)) {
            .comptime_int, .comptime_float, .float => self.fmt("{d}", .{val}),
            .int => if (T == u8 and std.ascii.isPrint(val))
                self.fmt("{c}", .{val})
            else
                self.fmt("{d}", .{val}),
            .bool => self.fmt("{s}", .{if (val) "true" else "false"}),
            .null => self.ele(.fragment, .{}), // Render nothing for null
            .optional => if (val) |inner| self.expr(inner) else self.ele(.fragment, .{}),
            .@"enum", .enum_literal => self.txt(@tagName(val)),
            .pointer => |ptr_info| switch (ptr_info.size) {
                .one => switch (@typeInfo(ptr_info.child)) {
                    .array => {
                        // Coerce `*[N]T` to `[]const T`.
                        const Slice = []const std.meta.Elem(ptr_info.child);
                        return self.expr(@as(Slice, val));
                    },
                    else => {
                        return self.expr(val.*);
                    },
                },
                .many, .slice => {
                    if (ptr_info.size == .many and ptr_info.sentinel() == null)
                        @compileError("unable to stringify type '" ++ @typeName(T) ++ "' without sentinel");
                    const slice = if (ptr_info.size == .many) std.mem.span(val) else val;

                    if (ptr_info.child == u8) {
                        // This is a []const u8, or some similar Zig string.
                        if (std.unicode.utf8ValidateSlice(slice)) {
                            return self.txt(slice);
                        }
                    }

                    // Handle slices of Components
                    if (ptr_info.child == Component) {
                        return .{ .element = .{
                            .tag = .fragment,
                            .children = val,
                        } };
                    }

                    return self.txt(slice);
                },

                else => @compileError("Unable to render type '" ++ @typeName(T) ++ "', supported types are: int, float, bool, string, enum, optional"),
            },
            .@"struct" => |struct_info| {
                var aw = std.Io.Writer.Allocating.init(self.getAlloc());
                errdefer aw.deinit();

                // aw.writer.print("{s} ", .{@tagName(struct_info)}) catch @panic("OOM");
                _ = struct_info;
                std.zon.stringify.serializeMaxDepth(val, .{ .whitespace = true }, &aw.writer, 100) catch |err| {
                    aw.deinit();
                    return self.fmt("{s}", .{@errorName(err)});
                };

                // Buffer is temporary - take ownership before Allocating is dropped.
                const owned = aw.toOwnedSlice() catch @panic("OOM");
                return .{ .text = owned };
            },
            .array => |arr_info| {
                // Handle arrays of Components - copy onto the allocator; `&val`
                // would dangle after this function returns.
                if (arr_info.child == Component) {
                    const allocator = self.getAlloc();
                    const copy = allocator.alloc(Component, val.len) catch @panic("OOM");
                    @memcpy(copy, &val);
                    return .{ .element = .{
                        .tag = .fragment,
                        .children = copy,
                    } };
                }
                @compileError("Unable to render array of type '" ++ @typeName(arr_info.child) ++ "', only Component arrays are supported");
            },
            else => @compileError("Unable to render type '" ++ @typeName(T) ++ "', supported types are: int, float, bool, string, enum, optional"),
        };

        return Cmp;
    }

    pub fn fmt(self: *Context, comptime format: []const u8, args: anytype) Component {
        const allocator = self.getAlloc();
        const text = allocator.print(format, args) catch @panic("OOM");
        return .{ .text = text };
    }

    pub fn printf(self: *Context, comptime format: []const u8, args: anytype) []const u8 {
        const allocator = self.getAlloc();
        const text = allocator.print(format, args) catch @panic("OOM");
        return text;
    }

    /// Create an attribute with type-aware value handling
    /// Returns null for values that should omit the attribute (false booleans, null optionals)
    ///
    /// `src` is the attribute's call-site `@src()` (emitted by the transpiler).
    pub fn attr(self: *Context, comptime src: ?std.builtin.SourceLocation, comptime name: []const u8, val: anytype) ?Element.Attribute {
        const T = @TypeOf(val);

        if (comptime isStatePointer(T)) {
            return self.attr(src, name, val.get());
        }

        return switch (@typeInfo(T)) {
            // Strings and function pointers
            .pointer => |ptr_info| blk: {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    break :blk .{ .name = name, .value = val };
                }
                if (ptr_info.size == .one) {
                    if (@typeInfo(ptr_info.child) == .array) {
                        const Slice = []const std.meta.Elem(ptr_info.child);
                        return self.attr(src, name, @as(Slice, val));
                    }
                    // Function pointer - treat as event handler
                    if (@typeInfo(ptr_info.child) == .@"fn") {
                        const fn_params = @typeInfo(ptr_info.child).@"fn".param_types;
                        const takes_ptr = fn_params.len == 1 and
                            @typeInfo(fn_params[0].?) == .pointer;
                        var handler = if (takes_ptr)
                            zx.EventHandler.runtimePtr(val)
                        else
                            zx.EventHandler.runtime(val);
                        if (src) |s| {
                            handler.stampId(self.getAlloc(), comptime Id.extendId(null, s, 0));
                        }
                        break :blk .{ .name = name, .handler = handler };
                    }
                }
                @compileError("Unsupported pointer type for attribute: " ++ @typeName(T));
            },

            // Integers - format to string
            .int, .comptime_int => .{
                .name = name,
                .value = self.printf("{d}", .{val}),
            },

            // Floats - format with default precision
            .float, .comptime_float => .{
                .name = name,
                .value = self.printf("{d}", .{val}),
            },

            // Booleans - presence-only attribute (true) or omit (false)
            .bool => if (val) .{ .name = name, .value = null } else null,

            // Optionals - recurse if non-null, omit if null
            .optional => if (val) |inner| self.attr(src, name, inner) else null,

            // Enums - convert tag name to string
            .@"enum", .enum_literal => .{
                .name = name,
                .value = @tagName(val),
            },

            // Event handlers - store as function pointer
            .@"fn" => blk: {
                var handler = if (comptime std.mem.eql(u8, name, "action"))
                    zx.EventHandler.action(val)
                else
                    zx.EventHandler.wrap(val);
                if (src) |s| {
                    handler.stampId(self.getAlloc(), comptime Id.extendId(null, s, 0));
                }
                break :blk .{ .name = name, .handler = handler };
            },
            // Pre-built event handlers (e.g. from ctx.bind(...)) and ctx.action handles
            .@"struct" => if (T == zx.EventHandler) blk: {
                var handler = val;
                if (src) |s| {
                    handler.stampId(self.getAlloc(), comptime Id.extendId(null, s, 0));
                }
                break :blk .{ .name = name, .handler = handler };
            } else if (T == zx.ActionHandle) blk: {
                var handler = val.handler;
                if (src) |s| {
                    handler.stampId(self.getAlloc(), comptime Id.extendId(null, s, 0));
                }
                break :blk .{ .name = name, .handler = handler };
            } else if (comptime @hasDecl(T, "format")) blk: {
                const allocator = self.getAlloc();
                const str = allocator.print("{f}", .{val}) catch @panic("OOM");
                break :blk .{
                    .name = name,
                    .value = str,
                };
            } else @compileError("Unsupported struct type for attribute: " ++ @typeName(T)),

            .@"union" => if (comptime @hasDecl(T, "format")) blk: {
                const allocator = self.getAlloc();
                const str = allocator.print("{f}", .{val}) catch @panic("OOM");
                break :blk .{
                    .name = name,
                    .value = str,
                };
            } else @compileError("Unsupported union type for attribute: " ++ @typeName(T)),

            else => @compileError("Unsupported type for attribute value: " ++ @typeName(T)),
        };
    }

    pub fn attrf(self: *Context, comptime name: []const u8, comptime format: []const u8, args: anytype) ?Element.Attribute {
        const allocator = self.getAlloc();
        const text = allocator.print(format, args) catch @panic("OOM");
        return self.attr(@src(), name, text);
    }

    pub fn attrv(self: *Context, val: anytype) []const u8 {
        const attrkv = self.attr(@src(), "f", val);
        if (attrkv) |a| {
            return a.value orelse "";
        }
        return "";
    }

    pub fn propf(self: *Context, comptime format: []const u8, args: anytype) []const u8 {
        const allocator = self.getAlloc();
        return allocator.print(format, args) catch @panic("OOM");
    }
    pub const propv = attrv;

    /// Filter and collect non-null attributes into a slice
    pub fn attrs(self: *Context, inputs: anytype) []const Element.Attribute {
        const allocator = self.getAlloc();
        const InputType = @TypeOf(inputs);
        const input_info = @typeInfo(InputType);

        // Handle tuple/struct (comptime known)
        if (input_info == .@"struct" and input_info.@"struct".is_tuple) {
            // Count non-null attributes at runtime
            var count: usize = 0;
            inline for (inputs) |input| {
                if (@TypeOf(input) == ?Element.Attribute) {
                    if (input != null) count += 1;
                } else {
                    count += 1;
                }
            }

            // Always allocator-owned (including len 0) so Component.deinit can free.
            const result = allocator.alloc(Element.Attribute, count) catch @panic("OOM");
            var idx: usize = 0;
            inline for (inputs) |input| {
                if (@TypeOf(input) == ?Element.Attribute) {
                    if (input) |a| {
                        result[idx] = a;
                        idx += 1;
                    }
                } else {
                    result[idx] = input;
                    idx += 1;
                }
            }

            return result;
        }

        @compileError("attrs() expects a tuple of attributes");
    }

    /// Allocate an owned children slice from a tuple of `Component`s.
    /// Prefer this over `&.{...}` so `ele` can store the pointer without copying
    /// (anonymous `&.{}` arrays are temporaries and would dangle after return).
    pub fn chs(self: *Context, inputs: anytype) []const Component {
        const allocator = self.getAlloc();
        const InputType = @TypeOf(inputs);
        const input_info = @typeInfo(InputType);

        if (input_info == .@"struct" and input_info.@"struct".is_tuple) {
            const count = input_info.@"struct".field_names.len;
            // Always allocator-owned (including len 0) so Component.deinit can free.
            const result = allocator.alloc(Component, count) catch @panic("OOM");
            inline for (inputs, 0..) |input, i| {
                result[i] = input;
            }
            return result;
        }

        @compileError("chs() expects a tuple of Components");
    }

    /// Spread a struct's fields as attributes
    /// Takes a struct and returns a slice of attributes for each field
    pub fn attrSpr(self: *Context, props: anytype) []const ?Element.Attribute {
        const allocator = self.getAlloc();
        const T = @TypeOf(props);
        const type_info = @typeInfo(T);

        if (type_info != .@"struct") {
            @compileError("attrSpr() expects a struct, got " ++ @typeName(T));
        }

        const field_names = type_info.@"struct".field_names;
        const result = allocator.alloc(?Element.Attribute, field_names.len) catch @panic("OOM");

        inline for (field_names, 0..) |field_name, i| {
            const val = @field(props, field_name);
            result[i] = self.attr(@src(), field_name, val);
        }

        return result;
    }

    /// Merge two structs for component props spreading
    /// Later fields override earlier ones
    pub fn propsM(_: *Context, base: anytype, overrides: anytype) prp.Merged(@TypeOf(base), @TypeOf(overrides)) {
        const BaseType = @TypeOf(base);
        const OverrideType = @TypeOf(overrides);
        const ResultType = prp.Merged(BaseType, OverrideType);

        var result: ResultType = undefined;

        // Copy all fields from base
        const base_info = @typeInfo(BaseType);
        if (base_info == .@"struct") {
            inline for (base_info.@"struct".field_names) |field_name| {
                if (@hasField(ResultType, field_name)) {
                    @field(result, field_name) = @field(base, field_name);
                }
            }
        }

        // Apply overrides (these take precedence)
        const override_info = @typeInfo(OverrideType);
        if (override_info == .@"struct") {
            inline for (override_info.@"struct".field_names) |field_name| {
                @field(result, field_name) = @field(overrides, field_name);
            }
        }

        return result;
    }

    /// Merge multiple attribute sources (including spread results) into a single slice
    /// Accepts a tuple where each element can be:
    /// - ?Element.Attribute (single attribute from attr())
    /// - []const ?Element.Attribute (slice from attrSpr())
    /// Later attributes with the same name override earlier ones (like JSX)
    pub fn attrsM(self: *Context, inputs: anytype) []const Element.Attribute {
        const allocator = self.getAlloc();
        const InputType = @TypeOf(inputs);
        const input_info = @typeInfo(InputType);

        if (input_info != .@"struct" or !input_info.@"struct".is_tuple) {
            @compileError("attrsM() expects a tuple of attributes or attribute slices");
        }

        // First pass: collect all attributes in order
        var count: usize = 0;
        inline for (inputs) |input| {
            const T = @TypeOf(input);
            if (T == ?Element.Attribute) {
                if (input != null) count += 1;
            } else if (T == []const ?Element.Attribute) {
                for (input) |maybe_attr| {
                    if (maybe_attr != null) count += 1;
                }
            } else {
                @compileError("attrsM() element must be ?Element.Attribute or []const ?Element.Attribute, got " ++ @typeName(T));
            }
        }

        if (count == 0) return &.{};

        // Collect all attributes in order (later ones override earlier)
        const temp = allocator.alloc(Element.Attribute, count) catch @panic("OOM");
        var idx: usize = 0;

        inline for (inputs) |input| {
            const T = @TypeOf(input);
            if (T == ?Element.Attribute) {
                if (input) |a| {
                    temp[idx] = a;
                    idx += 1;
                }
            } else if (T == []const ?Element.Attribute) {
                for (input) |maybe_attr| {
                    if (maybe_attr) |a| {
                        temp[idx] = a;
                        idx += 1;
                    }
                }
            }
        }

        // Deduplicate atrrs, keep last occurrence
        var unique_count: usize = 0;
        var i: usize = temp.len;
        while (i > 0) {
            i -= 1;
            const current = temp[i];
            var found_later = false;
            for (temp[i + 1 ..]) |later| {
                if (std.mem.eql(u8, current.name, later.name)) {
                    found_later = true;
                    break;
                }
            }
            if (!found_later) {
                unique_count += 1;
            }
        }

        const result = allocator.alloc(Element.Attribute, unique_count) catch @panic("OOM");
        var result_idx: usize = 0;

        for (temp, 0..) |current_attr, j| {
            var found_later = false;
            for (temp[j + 1 ..]) |later| {
                if (std.mem.eql(u8, current_attr.name, later.name)) {
                    found_later = true;
                    break;
                }
            }
            if (!found_later) {
                result[result_idx] = current_attr;
                result_idx += 1;
            }
        }

        allocator.free(temp);
        return result;
    }

    pub fn cmp(self: *Context, comptime func: anytype, comptime copts: ComptimeOptions, options: Options, props: anytype) Component {
        const allocator = self.getAlloc();

        const FuncInfo = @typeInfo(@TypeOf(func));
        const param_count = FuncInfo.@"fn".param_types.len;
        const FirstPropType = FuncInfo.@"fn".param_types[0].?;
        const first_is_ctx_ptr = @typeInfo(FirstPropType) == .pointer and
            @hasField(@typeInfo(FirstPropType).pointer.child, "allocator") and
            @hasField(@typeInfo(FirstPropType).pointer.child, "children");

        // TODO: use the name from the InitOptions @src() passed to x.init
        const name = options.name orelse "";
        // Context-based component or function with props parameter
        var comp_fn = if (first_is_ctx_ptr or param_count == 2) blk: {
            const PropsType = if (first_is_ctx_ptr) @TypeOf(props) else FuncInfo.@"fn".param_types[1].?;
            const coerced_props = prp.coerce(PropsType, props);
            break :blk Component.ComponentFn.init(func, name, allocator, coerced_props);
        } else blk: {
            break :blk Component.ComponentFn.init(func, name, allocator, props);
        };

        // Apply builtin attributes from options
        comp_fn.caching = options.caching;

        // Derive a stable, unique instance id entirely at comptime from this
        // `cmp` call site's source location. `@src()` already encodes file +
        // line + column, so the id is globally unique per instance site.
        if (copts.src) |src| {
            comp_fn.id = comptime Id.extendId(null, src, 0);
            if (comptime builtin.optimize == .debug) {
                comp_fn.dev.source_file = src.file;
                comp_fn.dev.source_line = src.line;
            }
        }

        // If client option is set, return a client component (for @client)
        // Render the component on the server for SSR, then hydrate on client.
        // On Browser (already on the client), skip the island wrapper - just render
        // the component directly as a component_fn.
        if (options.client != null and zx.platform.role == .client) {
            return .{ .component_fn = comp_fn };
        }
        if (options.client) |client_opts| {
            const name_copy = allocator.alloc(u8, client_opts.name.len) catch @panic("OOM");
            @memcpy(name_copy, client_opts.name);
            const id_copy = allocator.alloc(u8, client_opts.id.len) catch @panic("OOM");
            @memcpy(id_copy, client_opts.id);

            // Call the component function to get SSR content
            const rendered = comp_fn.call() catch @panic("Component call failed");
            const children_ptr = allocator.create(Component) catch @panic("OOM");
            children_ptr.* = rendered;

            // Serialize full props (with defaults) to ZXON for the hydration marker
            const hydrate_props = blk: {
                if (first_is_ctx_ptr) {
                    const CtxType = @typeInfo(FirstPropType).pointer.child;
                    if (@hasField(CtxType, "props")) {
                        const FullPropsType = @FieldType(CtxType, "props");
                        if (@typeInfo(FullPropsType) == .@"struct") {
                            break :blk prp.zxon(allocator, prp.coerce(FullPropsType, props));
                        }
                    }
                } else if (param_count == 2) {
                    const FullPropsType = FuncInfo.@"fn".param_types[1].?;
                    if (@typeInfo(FullPropsType) == .@"struct") {
                        break :blk prp.zxon(allocator, prp.coerce(FullPropsType, props));
                    }
                }
                break :blk prp.zxon(allocator, props);
            };

            comp_fn.name = name_copy;
            comp_fn.island = .{
                .id = id_copy,
                .props = hydrate_props,
                .children = children_ptr,
            };
            return .{ .component_fn = comp_fn };
        }

        return .{ .component_fn = comp_fn };
    }

    /// Allocates a Component and returns a pointer to it (used for @fallback)
    pub fn ptr(self: *Context, component: Component) *const Component {
        const allocator = self.getAlloc();
        const allocated = allocator.create(Component) catch @panic("OOM");
        allocated.* = component;
        return allocated;
    }
};

fn textSlice(text: anytype) []const u8 {
    const T = @TypeOf(text);
    return switch (@typeInfo(T)) {
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8)
                text
            else
                @compileError("txt expects a string slice, found " ++ @typeName(T)),
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| if (arr.child == u8)
                    @as([]const u8, text)
                else
                    @compileError("txt expects a string, found " ++ @typeName(T)),
                else => @compileError("txt expects a string, found " ++ @typeName(T)),
            },
            .many => if (ptr.child == u8 and ptr.sentinel() != null)
                std.mem.span(text)
            else
                @compileError("txt expects a sentinel-terminated string, found " ++ @typeName(T)),
            .c => @compileError("txt does not accept C pointers"),
        },
        .array => |arr| if (arr.child == u8)
            &text
        else
            @compileError("txt expects a string, found " ++ @typeName(T)),
        else => @compileError("txt expects a string, found " ++ @typeName(T)),
    };
}

fn isStatePointer(comptime PT: type) bool {
    const type_info = @typeInfo(PT);

    if (type_info != .pointer) return false;
    if (type_info.pointer.size != .one) return false;

    const CT = type_info.pointer.child;

    if (@typeInfo(CT) != .@"struct") return false;

    return @hasField(CT, "value") and
        @hasField(CT, "component_id") and
        @hasDecl(CT, "get") and
        @hasDecl(CT, "set") and
        @hasDecl(CT, "update");
}

pub const fnv = std.hash.Fnv1a_64;

/// This was taken from DVUI and modified to make the ID stable across builds
/// A generic id created by hashing `std.builting.SourceLocation`'s (from `@src()`)
pub const Id = enum(u64) {
    zero = 0,
    // This may not work in future and is illegal behaviour / arch specific to compare to undefined.
    undef = 0xAAAAAAAAAAAAAAAA,
    _,

    /// Make a unique id from `src` and `id_extra`, possibly starting with start
    /// (usually a parent widget id).  This is how the initial parent widget id is
    /// created, and also toasts and dialogs from other threads.
    ///
    /// See `Widget.extendId` which calls this with the widget id as start.
    ///
    /// ```zig
    /// dvui.parentGet().extendId(@src(), id_extra)
    /// ```
    /// is how new widgets get their id, and can be used to make a unique id without
    /// making a widget.
    pub fn extendId(start: ?Id, comptime src: std.builtin.SourceLocation, id_extra: usize) Id {
        const cp = std.fmt.comptimePrint;
        var hash = fnv.init();
        if (start) |s| hash.value = s.asU64();
        hash.update(cp("{s}", .{src.file}));
        hash.update(cp("{d}", .{src.line}));
        hash.update(cp("{d}", .{src.column}));
        var buf: [40]u8 = undefined;
        hash.update(std.fmt.bufPrint(&buf, "{d}", .{id_extra}) catch unreachable);
        return @fromBackingInt(@intCast(hash.final()));
    }

    /// Runtime variant of `extendId` that hashes a runtime `std.builtin.SourceLocation`.
    /// Produces the same id as `extendId` for an equivalent `src`/`id_extra`, so a
    /// component-block id (built at comptime) and an instance id derived from a
    /// runtime `@src()` value hash consistently.
    pub fn extend(start: ?Id, src: std.builtin.SourceLocation, id_extra: usize) Id {
        var hash = fnv.init();
        if (start) |s| {
            hash.value = s.asU64();
        }
        hash.update(src.file);
        var buf: [40]u8 = undefined;
        hash.update(std.fmt.bufPrint(&buf, "{d}", .{src.line}) catch unreachable);
        hash.update(std.fmt.bufPrint(&buf, "{d}", .{src.column}) catch unreachable);
        hash.update(std.fmt.bufPrint(&buf, "{d}", .{id_extra}) catch unreachable);
        return @fromBackingInt(@intCast(hash.final()));
    }

    /// Make a new id by combining id with a name, commonly a string key like `"__value"`.
    /// This is how dvui tracks things in `dataGet`/`dataSet`, `animation`, and `timer`.
    pub fn update(id: Id, name: []const u8) Id {
        var h = fnv.init();
        h.value = id.asU64();
        h.update(name);
        return @fromBackingInt(@intCast(h.final()));
    }

    pub fn asU64(self: Id) u64 {
        return @backingInt(self);
    }

    /// Shortened, stable 32-bit form of the id (the low 32 bits of the hash).
    /// Used for compact, human-readable string keys (see `fmtShort`). Collision
    /// risk within a single page is negligible.
    pub fn short(self: Id) u32 {
        return @truncate(@backingInt(self));
    }

    /// Format the id as a short, prefixed, stable string (e.g. `c1a2b3c4` for a
    /// component instance, `a9f8e7d6` for an action handler). The result is
    /// allocated with `allocator`.
    pub fn fmtShort(self: Id, allocator: std.mem.Allocator, comptime prefix: []const u8) []const u8 {
        return allocator.print(prefix ++ "{x:0>8}", .{self.short()}) catch @panic("OOM");
    }

    /// ALWAYS prefer using `asU64` unless a `usize` is required as it could
    /// loose precision and uniqueness on non-64bit platforms (like wasm32).
    ///
    /// Using an `Id` as `Options.id_extra` would be a valid use of this function
    pub fn asUsize(self: Id) usize {
        // usize might be u32 (like on wasm32)
        return @truncate(@backingInt(self));
    }

    pub fn format(self: *const Id, writer: *std.Io.Writer) !void {
        try writer.print("{x}", .{self.asU64()});
    }
};
