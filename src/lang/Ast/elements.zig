const std = @import("std");

const Set = std.StaticStringMapWithEql(
    void,
    std.static_string_map.eqlAsciiIgnoreCase,
);

/// Every valid, non-deprecated HTML element names
pub const known_elements = Set.initComptime(.{
    .{ "a", {} },           .{ "abbr", {} },            .{ "address", {} },
    .{ "area", {} },        .{ "article", {} },         .{ "aside", {} },
    .{ "audio", {} },       .{ "b", {} },               .{ "base", {} },
    .{ "bdi", {} },         .{ "bdo", {} },             .{ "blockquote", {} },
    .{ "body", {} },        .{ "br", {} },              .{ "button", {} },
    .{ "canvas", {} },      .{ "caption", {} },         .{ "cite", {} },
    .{ "code", {} },        .{ "col", {} },             .{ "colgroup", {} },
    .{ "data", {} },        .{ "datalist", {} },        .{ "dd", {} },
    .{ "del", {} },         .{ "details", {} },         .{ "dfn", {} },
    .{ "dialog", {} },      .{ "div", {} },             .{ "dl", {} },
    .{ "dt", {} },          .{ "em", {} },              .{ "embed", {} },
    .{ "fencedframe", {} }, .{ "fieldset", {} },        .{ "figcaption", {} },
    .{ "figure", {} },      .{ "footer", {} },          .{ "form", {} },
    .{ "h1", {} },          .{ "h2", {} },              .{ "h3", {} },
    .{ "h4", {} },          .{ "h5", {} },              .{ "h6", {} },
    .{ "head", {} },        .{ "header", {} },          .{ "hgroup", {} },
    .{ "hr", {} },          .{ "html", {} },            .{ "i", {} },
    .{ "iframe", {} },      .{ "img", {} },             .{ "input", {} },
    .{ "ins", {} },         .{ "kbd", {} },             .{ "label", {} },
    .{ "legend", {} },      .{ "li", {} },              .{ "link", {} },
    .{ "main", {} },        .{ "map", {} },             .{ "math", {} },
    .{ "mark", {} },        .{ "menu", {} },            .{ "meta", {} },
    .{ "meter", {} },       .{ "nav", {} },             .{ "noscript", {} },
    .{ "object", {} },      .{ "ol", {} },              .{ "optgroup", {} },
    .{ "option", {} },      .{ "output", {} },          .{ "p", {} },
    .{ "picture", {} },     .{ "pre", {} },             .{ "progress", {} },
    .{ "q", {} },           .{ "rp", {} },              .{ "rt", {} },
    .{ "ruby", {} },        .{ "s", {} },               .{ "samp", {} },
    .{ "script", {} },      .{ "search", {} },          .{ "section", {} },
    .{ "select", {} },      .{ "selectedcontent", {} }, .{ "slot", {} },
    .{ "small", {} },       .{ "source", {} },          .{ "span", {} },
    .{ "strong", {} },      .{ "style", {} },           .{ "sub", {} },
    .{ "summary", {} },     .{ "sup", {} },             .{ "svg", {} },
    .{ "table", {} },       .{ "tbody", {} },           .{ "td", {} },
    .{ "template", {} },    .{ "textarea", {} },        .{ "tfoot", {} },
    .{ "th", {} },          .{ "thead", {} },           .{ "time", {} },
    .{ "title", {} },       .{ "tr", {} },              .{ "track", {} },
    .{ "u", {} },           .{ "ul", {} },              .{ "var", {} },
    .{ "video", {} },       .{ "wbr", {} },
});

/// SVG elements (mirrors `element.Tag` from `svg_start` through `view`).
/// Lookups are ASCII case-insensitive, so `clipPath` / `clippath` both match.
pub const svg_elements = Set.initComptime(.{
    .{ "animate", {} },          .{ "animateMotion", {} },       .{ "animateTransform", {} },
    .{ "circle", {} },           .{ "clipPath", {} },            .{ "defs", {} },
    .{ "desc", {} },             .{ "ellipse", {} },             .{ "feBlend", {} },
    .{ "feColorMatrix", {} },    .{ "feComponentTransfer", {} }, .{ "feComposite", {} },
    .{ "feConvolveMatrix", {} }, .{ "feDiffuseLighting", {} },   .{ "feDisplacementMap", {} },
    .{ "feDistantLight", {} },   .{ "feDropShadow", {} },        .{ "feFlood", {} },
    .{ "feFuncA", {} },          .{ "feFuncB", {} },             .{ "feFuncG", {} },
    .{ "feFuncR", {} },          .{ "feGaussianBlur", {} },      .{ "feImage", {} },
    .{ "feMerge", {} },          .{ "feMergeNode", {} },         .{ "feMorphology", {} },
    .{ "feOffset", {} },         .{ "fePointLight", {} },        .{ "feSpecularLighting", {} },
    .{ "feSpotLight", {} },      .{ "feTile", {} },              .{ "feTurbulence", {} },
    .{ "filter", {} },           .{ "foreignObject", {} },       .{ "g", {} },
    .{ "image", {} },            .{ "line", {} },                .{ "linearGradient", {} },
    .{ "marker", {} },           .{ "mask", {} },                .{ "metadata", {} },
    .{ "mpath", {} },            .{ "path", {} },                .{ "pattern", {} },
    .{ "polygon", {} },          .{ "polyline", {} },            .{ "radialGradient", {} },
    .{ "rect", {} },             .{ "set", {} },                 .{ "stop", {} },
    .{ "svg", {} },              .{ "switch", {} },              .{ "symbol", {} },
    .{ "text", {} },             .{ "textPath", {} },            .{ "tspan", {} },
    .{ "use", {} },              .{ "view", {} },
});

/// Void elements: they have no content and no end tag. Ported from
/// `Kind.isVoid` in `fmt/html/Ast.zig`.
pub const void_elements = Set.initComptime(.{
    .{ "area", {} },  .{ "base", {} }, .{ "br", {} },     .{ "col", {} },
    .{ "embed", {} }, .{ "hr", {} },   .{ "img", {} },    .{ "input", {} },
    .{ "link", {} },  .{ "meta", {} }, .{ "source", {} }, .{ "track", {} },
    .{ "wbr", {} },
});

/// Deprecated/obsolete elements
pub const deprecated_elements = Set.initComptime(.{
    .{ "applet", {} },   .{ "acronym", {} },  .{ "bgsound", {} },
    .{ "dir", {} },      .{ "frame", {} },    .{ "frameset", {} },
    .{ "noframes", {} }, .{ "isindex", {} },  .{ "keygen", {} },
    .{ "listing", {} },  .{ "menuitem", {} }, .{ "nextid", {} },
    .{ "noembed", {} },  .{ "param", {} },    .{ "plaintext", {} },
    .{ "rb", {} },       .{ "rtc", {} },      .{ "strike", {} },
    .{ "xmp", {} },      .{ "basefont", {} }, .{ "big", {} },
    .{ "blink", {} },    .{ "center", {} },   .{ "font", {} },
    .{ "marquee", {} },  .{ "multicol", {} }, .{ "nobr", {} },
    .{ "spacer", {} },   .{ "tt", {} },
});

pub fn isKnown(name: []const u8) bool {
    return known_elements.has(name) or svg_elements.has(name);
}

pub fn isSvg(name: []const u8) bool {
    return svg_elements.has(name);
}

pub fn isVoid(name: []const u8) bool {
    return void_elements.has(name);
}

pub fn isDeprecated(name: []const u8) bool {
    return deprecated_elements.has(name);
}

/// `<fragment>` -> `<>...</>`)
pub fn isFragment(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "fragment");
}

/// HTML treats tag names that contain a hyphen as custom elements (web
/// components) which are always valid. Likewise, names starting with an
/// uppercase letter are ZX components, dotted names (`ns.Component`) are
/// namespaced components, and `<fragment>` is a ZX built-in. None of these
/// should be validated against the known HTML-element set.
pub fn isCustomOrComponent(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.isUpper(name[0])) return true; // ZX component
    if (std.mem.indexOfScalar(u8, name, '-') != null) return true; // custom element
    if (std.mem.indexOfScalar(u8, name, '.') != null) return true; // namespaced component
    if (isFragment(name)) return true; // ZX fragment built-in
    return false;
}
