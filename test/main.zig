const std = @import("std");

test {
    _ = @import("core/ast.zig");
    _ = @import("core/chk.zig");
    _ = @import("core/build.zig");
    _ = @import("cli/fmt.zig");
    _ = @import("cli/cli.zig");
    _ = @import("core/net.zig");
    _ = @import("core/zxon.zig");
    _ = @import("core/html.zig");
    _ = @import("core/props.zig");
    _ = @import("core/component.zig");
    _ = @import("core/routing.zig");
    _ = @import("core/export.zig");
    _ = @import("core/vdom.zig");
    _ = @import("core/csr.zig");
    _ = @import("core/dx.zig");
    _ = @import("core/db.zig");
    _ = @import("core/cache.zig");
    _ = @import("core/kv.zig");
    _ = @import("core/style.zig");
    _ = @import("core/mdzx.zig");
    _ = @import("cli/lsp.zig");
    _ = @import("cli/dev.zig");
    _ = @import("util/sig.zig");
}

pub const std_options = std.Options{
    .log_level = .info,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .zx_transpiler, .level = .info },
    },
};
