const std = @import("std");
const zx = @import("../../../../root.zig");
const Build = @import("../../../../Build.zig");
const tree = @import("../../tree.zig");

const Allocator = std.mem.Allocator;
const Component = zx.Component;

const manifest: Build.Manifest.App = @import("manifest");

const SlotPiece = struct {
    html: []const u8,
    pathname: Build.AddElementOptions.Pathname,
};

pub fn inject(allocator: Allocator, io: std.Io, page: *Component, pathname: []const u8) void {
    const pieces = comptime .{
        .head_starting = collectSlot(.head, .starting),
        .head_ending = collectSlot(.head, .ending),
        .body_starting = collectSlot(.body, .starting),
        .body_ending = collectSlot(.body, .ending),
    };

    if (joinMatching(allocator, pieces.head_starting, pathname)) |html| {
        if (tree.getElementByName(page, allocator, io, .head)) |el|
            tree.prependChild(el, allocator, unescapedHtml(allocator, html)) catch {};
    }
    if (joinMatching(allocator, pieces.head_ending, pathname)) |html| {
        if (tree.getElementByName(page, allocator, io, .head)) |el|
            tree.appendChild(el, allocator, unescapedHtml(allocator, html)) catch {};
    }
    if (joinMatching(allocator, pieces.body_starting, pathname)) |html| {
        if (tree.getElementByName(page, allocator, io, .body)) |el|
            tree.prependChild(el, allocator, unescapedHtml(allocator, html)) catch {};
    }
    if (joinMatching(allocator, pieces.body_ending, pathname)) |html| {
        if (tree.getElementByName(page, allocator, io, .body)) |el|
            tree.appendChild(el, allocator, unescapedHtml(allocator, html)) catch {};
    }
}

/// Wrap pre-rendered HTML so it is written verbatim (`@escaping={.none}`).
fn unescapedHtml(allocator: Allocator, html: []const u8) Component {
    const children = allocator.alloc(Component, 1) catch return .{ .text = html };
    children[0] = .{ .text = html };
    return .{ .element = .{
        .tag = .fragment,
        .escaping = .none,
        .children = children,
    } };
}

fn collectSlot(comptime parent: Build.AddElementOptions.Parent, comptime position: Build.AddElementOptions.Position) []const SlotPiece {
    comptime var sorted_indices: [manifest.injections.len]usize = undefined;
    comptime var match_count: usize = 0;
    inline for (manifest.injections, 0..) |inj, i| {
        if (inj.parent == parent and inj.position == position) {
            sorted_indices[match_count] = i;
            match_count += 1;
        }
    }

    comptime var sorted: [match_count]usize = sorted_indices[0..match_count].*;
    if (sorted.len > 1) {
        inline for (1..sorted.len) |i| {
            const key = sorted[i];
            comptime var j = i;
            inline while (j > 0 and manifest.injections[sorted[j - 1]].priority > manifest.injections[key].priority) : (j -= 1) {
                sorted[j] = sorted[j - 1];
            }
            sorted[j] = key;
        }
    }

    comptime var pieces: [match_count]SlotPiece = undefined;
    inline for (sorted, 0..) |idx, i| {
        const inj = manifest.injections[idx];
        const comp = comptime toComponent(inj.element);
        pieces[i] = .{
            .html = renderComponent(comp),
            .pathname = inj.pathname,
        };
    }
    const final: [match_count]SlotPiece = pieces;
    return &final;
}

fn joinMatching(allocator: Allocator, pieces: []const SlotPiece, pathname: []const u8) ?[]const u8 {
    var total: usize = 0;
    for (pieces) |piece| {
        if (piece.pathname.matches(pathname)) total += piece.html.len;
    }
    if (total == 0) return null;

    const buf = allocator.alloc(u8, total) catch return null;
    var offset: usize = 0;
    for (pieces) |piece| {
        if (!piece.pathname.matches(pathname)) continue;
        @memcpy(buf[offset .. offset + piece.html.len], piece.html);
        offset += piece.html.len;
    }
    return buf;
}

fn renderComponent(comptime comp: Component) []const u8 {
    comptime {
        var buf: [1 << 16]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        comp.render(&writer, .{}) catch |err| @compileError(
            "failed to render zx injection: " ++ @errorName(err),
        );
        const len = writer.buffered().len;
        const final: [len]u8 = buf[0..len].*;
        return &final;
    }
}

fn toComponent(comptime elem: Build.AddElementOptions.ElementDef) Component {
    comptime {
        var attrs: [elem.attributes.len]zx.Element.Attribute = undefined;
        for (elem.attributes, 0..) |attr, i| {
            attrs[i] = .{ .name = attr.name, .value = attr.value };
        }
        const attrs_final = attrs;

        var children: ?[]const Component = null;
        if (elem.children) |defs| {
            var kids: [defs.len]Component = undefined;
            for (defs, 0..) |child, i| {
                kids[i] = toChildComponent(child);
            }
            const kids_final = kids;
            children = &kids_final;
        }

        return .{ .element = .{
            .tag = elem.tag,
            .attributes = &attrs_final,
            .children = children,
        } };
    }
}

fn toChildComponent(comptime child: Build.AddElementOptions.ElementDef.Child) Component {
    comptime {
        return switch (child) {
            .text => |t| .{ .text = t },
            .element => |e| toComponent(e),
        };
    }
}
