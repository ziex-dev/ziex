// Empty app for the standalone fuzz build (`zig build fuzz`).
const zx = @import("zx");

pub const routes = [_]zx.App.Route{};
