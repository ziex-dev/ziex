pub const Preset = struct {
    label: []const u8,
    slug: []const u8,
};

// Served at /branding/banner-<slug>.svg, slug derived from the label
pub const presets = blk: {
    const labels = [_][]const u8{
        "Starter",
        "Cloudflare",
        "Vercel",
        "Railway",
        "Render",
        "Node",
        "Tailwind CSS",
        "esbuild",
        "TypeScript",
        "Plugin System",
    };
    var list: [labels.len]Preset = undefined;
    for (labels, 0..) |label, i| list[i] = .{ .label = label, .slug = slugify(label) };
    break :blk list;
};

pub fn presetLabel(slug: []const u8) ?[]const u8 {
    for (presets) |preset| {
        if (std.mem.eql(u8, preset.slug, slug)) return preset.label;
    }
    return null;
}

const max_label_len = 40;
const tag_height = 52;
const tag_radius = 20;
const tag_pad_x = 26;
const font_size = 22;

/// Writes the animated brand banner, with a label tag in the top left when `label` is non-empty.
pub fn render(w: *std.Io.Writer, label: ?[]const u8) !void {
    const src = branding.banner_animated;
    const text = truncate(std.mem.trim(u8, label orelse "", " \t\r\n"));
    if (text.len == 0) return w.writeAll(src);

    const end = std.mem.lastIndexOf(u8, src, "</svg>") orelse return error.InvalidBanner;
    try w.writeAll(src[0..end]);
    try writeTag(w, text);
    try w.writeAll(src[end..]);
}

fn writeTag(w: *std.Io.Writer, text: []const u8) !void {
    const width: u32 = @intFromFloat(@round(textWidth(text) + tag_pad_x * 2));

    // Same font as the "Ziex" title; text is centered so width estimate errors only shift padding
    try w.print(
        \\  <g id="Label">
        \\    <path fill="#4ade80" d="M0 0h{d}v{d}a{d} {d} 0 0 1-{d} {d}H0z"/>
        \\    <text xml:space="preserve" fill="#0c1117" font-family="Inter, sans-serif" font-size="{d}" font-weight="bold" letter-spacing="0" text-anchor="middle" style="white-space:pre"><tspan x="{d}" y="{d}">
    , .{ width, tag_height - tag_radius, tag_radius, tag_radius, tag_radius, tag_radius, font_size, width / 2, tag_height / 2 + font_size * 4 / 10 });
    try writeEscaped(w, text);
    try w.writeAll(
        \\</tspan></text>
        \\  </g>
        \\
    );
}

// Rough Inter Bold advance widths, in px at `font_size`
fn textWidth(text: []const u8) f64 {
    var em: f64 = 0;
    var it = (std.unicode.Utf8View.init(text) catch return @as(f64, @floatFromInt(text.len)) * 0.62 * font_size).iterator();
    while (it.nextCodepoint()) |c| {
        em += switch (c) {
            'i', 'j', 'l', 'I', '.', ',', ':', ';', '\'', '!', '|' => 0.28,
            ' ', 'f', 't', 'r', '-', '(', ')', '[', ']' => 0.38,
            'm', 'w', 'M', 'W' => 0.9,
            'A'...'H', 'J'...'L', 'N'...'V', 'X'...'Z', '0'...'9' => 0.68,
            else => 0.6,
        };
    }
    return em * font_size;
}

fn truncate(text: []const u8) []const u8 {
    var it = (std.unicode.Utf8View.init(text) catch return text[0..@min(text.len, max_label_len)]).iterator();
    var count: usize = 0;
    while (it.nextCodepointSlice()) |_| {
        count += 1;
        if (count == max_label_len) return text[0..it.i];
    }
    return text;
}

fn writeEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {},
        else => try w.writeByte(c),
    };
}

fn slugify(comptime label: []const u8) []const u8 {
    comptime {
        var buf: [label.len]u8 = undefined;
        for (label, 0..) |c, i| buf[i] = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '-';
        const out = buf;
        return &out;
    }
}

const branding = @import("branding");
const std = @import("std");
