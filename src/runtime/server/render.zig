const std = @import("std");
const zx = @import("../../root.zig");
const registry = @import("registry.zig");
const html_util = zx.util.html;

/// Set by the server request handler before calling render/stream so that any ActionContext
/// handlers encountered during the render pass are registered for this route.
pub var current_route_path: ?[]const u8 = null;

pub const streaming_bootstrap_script =
    \\<script>window.$ZX=function(id,html){var t=document.getElementById('__ZX_S-'+id);if(t){var d=document.createElement('div');d.innerHTML=html;while(d.firstChild)t.parentNode.insertBefore(d.firstChild,t);t.remove();}}</script>
;

/// Async component collected during streaming
pub const AsyncComponent = struct {
    id: u32,
    component: zx.Component,

    pub fn renderScript(self: AsyncComponent, allocator: std.mem.Allocator) ![]const u8 {
        var aw = std.Io.Writer.Allocating.init(allocator);
        errdefer aw.deinit();

        try self.component.render(&aw.writer, .{});
        const html = aw.written();

        // Build minimal script: <script>$ZX(id,`content`)</script>
        var script_writer = std.Io.Writer.Allocating.init(allocator);
        errdefer script_writer.deinit();

        try script_writer.writer.print("<script>$ZX({d},`", .{self.id});

        // Escape backticks, backslashes, and $ in HTML for template literal
        for (html) |c| {
            switch (c) {
                '`' => try script_writer.writer.writeAll("\\`"),
                '\\' => try script_writer.writer.writeAll("\\\\"),
                '$' => try script_writer.writer.writeAll("\\$"),
                else => try script_writer.writer.writeByte(c),
            }
        }

        try script_writer.writer.writeAll("`)</script>");

        return script_writer.written();
    }
};

/// Stream method that renders HTML while collecting async components
/// Writes placeholders for @async={.stream} components and returns them for parallel rendering
pub fn stream(self: zx.Component, allocator: std.mem.Allocator, writer: *std.Io.Writer, options: RenderOptions) ![]AsyncComponent {
    var async_components = std.array_list.Managed(AsyncComponent).init(allocator);
    errdefer async_components.deinit();

    var counter: u32 = 0;
    try render(self, writer, .{
        .escaping = .html,
        .async_components = &async_components,
        .async_counter = &counter,
        .base_path = options.base_path,
    });
    return async_components.toOwnedSlice();
}

pub const RenderOptions = struct {
    escaping: ?zx.BuiltinAttribute.Escaping = .html,
    async_components: ?*std.array_list.Managed(AsyncComponent) = null,
    async_counter: ?*u32 = null,
    base_path: ?[]const u8 = null,
};

pub fn render(self: zx.Component, writer: *std.Io.Writer, options: RenderOptions) !void {
    switch (self) {
        .none => {
            // Render nothing
        },
        .text => |text| {
            if (options.escaping == .none) {
                try writer.writeAll(text);
            } else {
                try html_util.escapeText(writer, text);
            }
        },
        .component_fn => |func| {
            // Client island: emit hydration markers + SSR children
            if (func.island) |island| {
                try writer.writeAll("<!--$");
                try writer.writeAll(island.id);
                if (island.props) |hp| {
                    try writer.writeAll(" ");
                    try writer.writeAll(hp);
                }
                try writer.writeAll("-->");

                try render(island.children.*, writer, options);

                try writer.writeAll("<!--/$");
                try writer.writeAll(island.id);
                try writer.writeAll("-->");
                return;
            }

            // Check for component-level caching
            if (func.caching) |caching| {
                const cmp_cache = zx.cache.scoped(.cmp);

                if (caching.ttl.nanoseconds > 0) {
                    // Generate cache key from function pointer + props pointer + optional custom key
                    var key_buf: [128]u8 = undefined;
                    const generated_key = key_blk: {
                        if (caching.key) |custom_key| {
                            // TODO: figure out a better way generate unique stable component id
                            // for now we will just use the custom key directly as the cache key
                            break :key_blk try std.fmt.bufPrint(&key_buf, "cmp:{s}", .{custom_key});
                        } else {
                            break :key_blk try std.fmt.bufPrint(&key_buf, "cmp:{x}:{x}", .{
                                @intFromPtr(func.vtable.call),
                                @intFromPtr(func.data),
                            });
                        }
                    };

                    // Try to get from cache
                    const cached = cmp_cache.get(func.allocator, generated_key) catch |err| switch (err) {
                        error.Unavailable => null,
                        else => return err,
                    };
                    if (cached) |cached_html| {
                        defer func.allocator.free(cached_html);
                        try writer.writeAll(cached_html);
                        return;
                    }

                    // Render to buffer for caching
                    var buf_writer = std.Io.Writer.Allocating.init(func.allocator);
                    const component = try func.call();
                    try render(component, &buf_writer.writer, options);

                    const rendered = buf_writer.written();
                    cmp_cache.put(generated_key, rendered, .{ .ttl = caching.ttl }) catch |err| switch (err) {
                        error.Unavailable => {},
                        else => return err,
                    };

                    try writer.writeAll(rendered);
                    return;
                }
            }

            // No caching or cache miss - render directly
            const component = try func.call();
            try render(component, writer, options);
        },
        .element => |elem| {
            // Check if this element is async and we're collecting async components
            if (options.async_components != null and elem.async == .stream) {
                const async_id = options.async_counter.?.*;
                options.async_counter.?.* += 1;

                // Write placeholder div with fallback content
                try writer.writeAll("<div id=\"__ZX_S-");
                try writer.print("{d}", .{async_id});
                try writer.writeAll("\">");

                // Render fallback content if provided
                if (elem.fallback) |fallback| {
                    try render(fallback.*, writer, .{
                        .escaping = options.escaping,
                    });
                }

                try writer.writeAll("</div>");

                // Collect for async rendering
                try options.async_components.?.append(.{
                    .id = async_id,
                    .component = self,
                });
                return;
            }

            // <><div>...</div></> => <div>...</div>
            if (elem.tag == .fragment) {
                if (elem.children) |children| {
                    const child_options = RenderOptions{
                        .escaping = elem.escaping orelse options.escaping,
                        .async_components = options.async_components,
                        .async_counter = options.async_counter,
                        .base_path = options.base_path,
                    };
                    for (children) |child| {
                        try render(child, writer, child_options);
                    }
                }
                return;
            }

            // Otherwise, render normally
            // Opening tag
            try writer.writeAll("<");
            try writer.writeAll(elem.htmlTagName());

            const is_self_closing = elem.tag.isSelf();
            const is_no_closing = elem.tag.isVoid();

            // Handle attributes
            var has_action_handler = false;
            var action_id: u32 = 1;
            const base_path_normalized = if (options.base_path) |bp|
                html_util.normalizeBasePathForPrefixing(bp)
            else
                null;
            if (elem.attributes) |attributes| {
                var has_method = false;

                for (attributes) |attribute| {
                    if (attribute.handler) |handler| {
                        // Register ActionContext handlers so the server can dispatch them.
                        if (handler.action_fn) |action_fn| {
                            if (current_route_path) |rp| {
                                action_id = registry.register(rp, handler.handler_id, action_fn);
                            }
                            has_action_handler = true;
                        }

                        if (handler.server_event_fn) |action_fn| {
                            if (current_route_path) |rp| {
                                registry.registerEvent(rp, handler.handler_id, action_fn);
                            }
                        }
                    } else {
                        if (std.mem.eql(u8, attribute.name, "method")) {
                            has_method = true;
                        }
                        // defaultValue is a DOM property; the HTML attribute equivalent is "value"
                        const attr_name = if (std.mem.eql(u8, attribute.name, "defaultValue")) "value" else attribute.name;
                        try writer.writeAll(" ");
                        try writer.writeAll(attr_name);
                    }
                    if (attribute.value) |value| {
                        try writer.writeAll("=\"");
                        // Prefix href/src/action attributes with base_path when applicable
                        if (base_path_normalized) |nb| {
                            const name = attribute.name;
                            const is_prefixable = std.mem.eql(u8, name, "href") or
                                std.mem.eql(u8, name, "src") or
                                std.mem.eql(u8, name, "action");
                            if (is_prefixable and html_util.shouldPrefixPathWithBasePath(nb, value)) {
                                try writer.writeAll(nb);
                            }
                        }
                        try html_util.escapeAttr(writer, value);
                        try writer.writeAll("\"");
                    }
                }

                // Auto-inject method="post" enctype="multipart/form-data"
                // on form elements with an action handler
                if (elem.tag == .form and has_action_handler and !has_method) {
                    try writer.writeAll(" method=\"post\" enctype=\"multipart/form-data\"");
                }
            }

            // Closing bracket
            if (!is_self_closing or is_no_closing) {
                try writer.writeAll(">");
            } else {
                try writer.writeAll(" />");
            }

            // Inject hidden field so no-JS form submissions can be identified as action requests
            if (elem.tag == .form and has_action_handler) {
                try writer.writeAll("<input type=\"hidden\" name=\"__$action\" value=\"");
                try writer.print("{d}", .{action_id});
                try writer.writeAll("\">");
            }

            // Render children
            if (elem.children) |children| {
                const child_options = RenderOptions{
                    .escaping = elem.escaping orelse options.escaping,
                    .async_components = options.async_components,
                    .async_counter = options.async_counter,
                    .base_path = options.base_path,
                };
                for (children) |child| {
                    try render(child, writer, child_options);
                }
            }

            // Closing tag
            if (!is_self_closing and !is_no_closing) {
                try writer.writeAll("</");
                try writer.writeAll(elem.htmlTagName());
                try writer.writeAll(">");
            }
        },
    }
}
