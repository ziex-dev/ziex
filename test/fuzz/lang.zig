// The transpiler links tree-sitter (C), so this runs only under `zig build test`,
// not coverage-guided `zig build fuzz --fuzz`.
const std = @import("std");
const lang = @import("lang");
const Smith = std.testing.Smith;
const util = @import("util.zig");

test "fuzz: zx transpile" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, s: *Smith) !void {
            var buf: [4096]u8 = undefined;
            const n = s.slice(buf[0 .. buf.len - 1]);
            buf[n] = 0;
            const source = buf[0..n :0];
            const gpa = std.testing.allocator;

            var zx_result = lang.Ast.parse(gpa, source, .{ .map = .inlined, .path = "page.zx" }) catch return;
            zx_result.deinit(gpa);
            var md_result = lang.Ast.parse(gpa, source, .{ .lang = .mdzx, .path = "page.mdzx" }) catch return;
            md_result.deinit(gpa);
        }
    }.run, .{ .corpus = util.seeds(&.{
        @embedFile("../data/control_flow/if.zx"),
        @embedFile("../data/control_flow/if_capture.zx"),
        @embedFile("../data/control_flow/for_switch.zx"),
        @embedFile("../data/element/fragment.zx"),
        @embedFile("../data/element/void.zx"),
        @embedFile("../data/attribute/dynamic.zx"),
        @embedFile("../data/attribute/spread.zx"),
        @embedFile("../data/attribute/builtin_escaping.zx"),
        "# Title\n\nSome *text* with <Button>{x}</Button>\n",
    }) });
}
