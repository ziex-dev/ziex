pub fn Page(allocator: zx.Allocator) zx.Component {
    const bank = "Tada Bank TTC";
    const kind = "Cash";
    var _zx = @import("zx").x.allocInit(allocator, .{ .src = @src() });
    return _zx.ele(
        .div,
        .{
            .allocator = allocator,
            .children = _zx.chs(.{
                _zx.ele(
                    .span,
                    .{
                        .children = _zx.chs(.{
                            _zx.expr(bank),
                            _zx.txt(" · "),
                            _zx.expr(kind),
                            _zx.txt(" · "),
                            _zx.expr(kind),
                        }),
                    },
                ),
                _zx.ele(
                    .span,
                    .{
                        .children = _zx.chs(.{
                            _zx.expr(bank),
                            _zx.txt(" · "),
                            _zx.expr(kind),
                        }),
                    },
                ),
                _zx.ele(
                    .span,
                    .{
                        .children = _zx.chs(.{
                            _zx.expr(bank),
                            _zx.expr(kind),
                        }),
                    },
                ),
                _zx.ele(
                    .span,
                    .{
                        .children = _zx.chs(.{
                            _zx.ele(
                                .b,
                                .{
                                    .children = _zx.chs(.{
                                        _zx.expr(bank),
                                    }),
                                },
                            ),
                            _zx.txt(" · "),
                            _zx.expr(kind),
                        }),
                    },
                ),
                _zx.ele(
                    .span,
                    .{
                        .children = _zx.chs(.{
                            _zx.expr(bank),
                            _zx.expr(" "),
                            _zx.expr(kind),
                        }),
                    },
                ),
                _zx.ele(
                    .span,
                    .{
                        .children = _zx.chs(.{
                            _zx.txt("Try"),
                            _zx.ele(
                                .a,
                                .{
                                    .attributes = _zx.attrs(.{
                                        _zx.attr(@src(), "href", "/x"),
                                    }),
                                    .children = _zx.chs(.{
                                        _zx.expr(kind),
                                    }),
                                },
                            ),
                        }),
                    },
                ),
            }),
        },
    );
}

const zx = @import("zx");
