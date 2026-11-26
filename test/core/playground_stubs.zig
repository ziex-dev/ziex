const std = @import("std");

// The playground compiles apps in-browser without build.zig, so app_opts comes
// from a hand-written stub. Fail here instead of at playground compile time.
test "playground app_opts stub matches build options" {
    const real = @import("app_opts");
    const stub = @import("playground_app_opts");

    comptime var missing: []const u8 = "";
    inline for (comptime std.meta.declarations(real)) |name| {
        if (!@hasDecl(stub, name)) {
            missing = missing ++ " " ++ name;
        } else if (@TypeOf(@field(real, name)) != @TypeOf(@field(stub, name))) {
            missing = missing ++ " " ++ name ++ "(type)";
        }
    }
    if (missing.len != 0) {
        std.debug.print("site/app/playground/template/stubs/app_opts.zig is out of date:{s}\n", .{missing});
        return error.PlaygroundStubOutOfDate;
    }
}
