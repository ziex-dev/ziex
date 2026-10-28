const std = @import("std");
const zx = @import("zx");

/// Exercises text node memory lifetimes after `txt` stopped always-duping:
/// static borrows, arena-owned slices, fmt-owned text, enum tags, struct
/// stringify ownership, props, attributes, and `@escaping={.none}`.
pub fn Page(allocator: zx.Allocator) zx.Component {
    // Static / literal slices - borrowed by txt/expr (must remain valid).
    const literal = "literal & <chars>";
    const static_slice: []const u8 = "static-slice";
    const empty: []const u8 = "";
    const unicode = "こんにちは 🎉";

    // Arena-owned dynamic strings - borrowed, live as long as the request arena.
    const arena_str = allocator.print("arena-{d}", .{42}) catch unreachable;
    const arena_prefix = arena_str[0..5]; // subslice into arena allocation
    const duped = allocator.dupe(u8, "duped-into-arena") catch unreachable;

    // Enum tags are static in the binary.
    const status = Status.active;

    // Struct stringify takes ownership via toOwnedSlice (includes escaping chars).
    const person: Person = .{
        .name = "Tom & Jerry",
        .age = 10,
    };

    // Optionals: present borrows the payload; null renders nothing.
    const maybe: ?[]const u8 = "optional-value";
    const missing: ?[]const u8 = null;

    // Trusted HTML for @escaping={.none} - must be arena-owned (not stack).
    const trusted_html = allocator.print("<em>trusted-{s}</em>", .{"ok"}) catch unreachable;

    var _zx = @import("zx").x.allocInit(allocator, .{ .src = @src() });
    return _zx.ele(
        .main,
        .{
            .allocator = allocator,
            .children = _zx.chs(.{
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "literal"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(literal),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "static"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(static_slice),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "empty"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(empty),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "unicode"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(unicode),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "arena"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(arena_str),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "prefix"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(arena_prefix),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "duped"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(duped),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "enum"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(status),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "struct"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(person),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "optional"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(maybe),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "missing"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(missing),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "inline"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr("inline-literal & x"),
                        }),
                    },
                ),
                _zx.ele(
                    .div,
                    .{
                        .escaping = .none,
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "trusted"),
                        }),
                        .children = _zx.chs(.{
                            _zx.expr(trusted_html),
                        }),
                    },
                ),
                _zx.ele(
                    .p,
                    .{
                        .attributes = _zx.attrs(.{
                            _zx.attr(@src(), "id", "attr"),
                            _zx.attr(@src(), "title", literal),
                            _zx.attr(@src(), "data-arena", arena_str),
                        }),
                        .children = _zx.chs(.{
                            _zx.txt("attrs"),
                        }),
                    },
                ),
                _zx.cmp(
                    Label,
                    .{ .src = @src() },
                    .{ .name = "Label" },
                    .{ .text = "prop-literal" },
                ),
                _zx.cmp(
                    Label,
                    .{ .src = @src() },
                    .{ .name = "Label" },
                    .{ .text = arena_str },
                ),
                _zx.cmp(
                    Label,
                    .{ .src = @src() },
                    .{ .name = "Label" },
                    .{ .text = duped },
                ),
                _zx.ele(
                    .span,
                    .{
                        .children = _zx.chs(.{
                            _zx.expr("&<>\"'"),
                        }),
                    },
                ),
            }),
        },
    );
}

const Status = enum { idle, active, done };

const Person = struct {
    name: []const u8,
    age: u32,
};

const LabelProps = struct { text: []const u8 };
pub fn Label(allocator: zx.Allocator, props: LabelProps) zx.Component {
    var _zx = @import("zx").x.allocInit(allocator, .{ .src = @src() });
    return _zx.ele(
        .label,
        .{
            .allocator = allocator,
            .children = _zx.chs(.{
                _zx.expr(props.text),
            }),
        },
    );
}
