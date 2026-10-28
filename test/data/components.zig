pub const components = [_]zx.client.ComponentMeta{
    .{
        .type = .client,
        .id = "c8fee6a",
        .name = "CounterComponent",
        .path = "component/csr_zig.zig",
        .import = zx.client.ComponentMeta.init(@import("component/csr_zig.zig").CounterComponent),
        .route = "",
    },
    .{
        .type = .client,
        .id = "cd02624",
        .name = "Button",
        .path = "component/csr_zig.zig",
        .import = zx.client.ComponentMeta.init(@import("component/csr_zig.zig").Button),
        .route = "",
    },
    .{
        .type = .client,
        .id = "c24eadf",
        .name = "Counter",
        .path = "component/csr_zig_props.zig",
        .import = zx.client.ComponentMeta.init(@import("component/csr_zig_props.zig").Counter),
        .route = "",
    },
    .{
        .type = .client,
        .id = "cd768fc",
        .name = "Counter",
        .path = "component/csr_zig_props.zig",
        .import = zx.client.ComponentMeta.init(@import("component/csr_zig_props.zig").Counter),
        .route = "",
    },
    .{
        .type = .client,
        .id = "c9e599a",
        .name = "Counter",
        .path = "component/csr_zig_props.zig",
        .import = zx.client.ComponentMeta.init(@import("component/csr_zig_props.zig").Counter),
        .route = "",
    },
};

const zx = @import("zx");
