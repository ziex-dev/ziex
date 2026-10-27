pub fn Page(allocator: zx.Allocator) zx.Component {
    if (pick(false)) return _zx_ele_blk_0: {
        var _zx = @import("zx").x.allocInit(allocator, .{ .src = @src() });
        break :_zx_ele_blk_0 _zx.ele(
            .p,
            .{
                .allocator = allocator,
                .children = _zx.chs(.{
                    _zx.txt("Early"),
                }),
            },
        );
    };
    const label = name(true) catch return _zx_ele_blk_1: {
        var _zx = @import("zx").x.allocInit(allocator, .{ .src = @src() });
        break :_zx_ele_blk_1 _zx.ele(
            .p,
            .{
                .allocator = allocator,
                .children = _zx.chs(.{
                    _zx.txt("Failed"),
                }),
            },
        );
    };
    var _zx = @import("zx").x.allocInit(allocator, .{ .src = @src() });
    return _zx.ele(
        .main,
        .{
            .allocator = allocator,
            .children = _zx.chs(.{
                _zx.ele(
                    .p,
                    .{
                        .children = _zx.chs(.{
                            _zx.expr(label),
                        }),
                    },
                ),
            }),
        },
    );
}

fn pick(v: bool) bool {
    return v;
}

fn name(ok: bool) ![]const u8 {
    return if (ok) "Loaded" else error.Missing;
}

const zx = @import("zx");
