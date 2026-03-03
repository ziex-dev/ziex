pub fn Page(allocator: zx.Allocator) zx.Component {
    var _zx = @import("zx").allocInit(allocator);
    return _zx.ele(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                _zx.cmp(
                    components.Button,
                    .{ .name = "Button" },
                    .{ .title = "Custom Button" },
                ),
            },
        },
    );
}

const components = struct {
    const ButtonProps = struct { title: []const u8 };
    pub fn Button(allocator: zx.Allocator, props: ButtonProps) zx.Component {
        var _zx = @import("zx").allocInit(allocator);
        return _zx.ele(
            .button,
            .{
                .allocator = allocator,
                .children = &.{
                    _zx.expr(props.title),
                },
            },
        );
    }
};

const zx = @import("zx");
