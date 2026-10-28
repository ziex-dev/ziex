const base = "_base/";
const docker = "_docker/";

pub const TemplateFile = struct {
    pub const Name = enum { starter, docker };

    name: ?Name = null,
    path: []const u8,
    content: []const u8,
};

pub const files = [_]TemplateFile{
    // Shared
    .{ .path = "build.zig.zon", .content = @embedFile(base ++ "build.zig.zon") },
    .{ .path = "build.zig", .content = @embedFile(base ++ "build.zig") },
    .{ .path = "app/main.zig", .content = @embedFile(base ++ "app/main.zig") },
    .{ .path = "README.md", .content = @embedFile(base ++ "README.md") },
    .{ .path = "app/assets/style.css", .content = @embedFile(base ++ "app/assets/style.css") },
    .{ .path = "app/public/favicon.ico", .content = @embedFile(base ++ "app/public/favicon.ico") },
    .{ .path = "app/pages/layout.zx", .content = @embedFile(base ++ "app/pages/layout.zx") },
    .{ .path = "app/pages/page.zx", .content = @embedFile(base ++ "app/pages/page.zx") },
    .{ .path = "app/pages/client.zx", .content = @embedFile(base ++ "app/pages/client.zx") },
    .{ .path = "app/pages/form/page.zx", .content = @embedFile(base ++ "app/pages/form/page.zx") },
    .{ .path = "app/pages/actions/page.zx", .content = @embedFile(base ++ "app/pages/actions/page.zx") },
    .{ .path = "app/pages/events/page.zx", .content = @embedFile(base ++ "app/pages/events/page.zx") },
    .{ .path = "app/pages/db/page.zx", .content = @embedFile(base ++ "app/pages/db/page.zx") },
    .{ .path = "app/pages/kv/page.zx", .content = @embedFile(base ++ "app/pages/kv/page.zx") },
    .{ .path = ".gitignore", .content = @embedFile(base ++ ".gitignore") },
    .{ .path = ".gitattributes", .content = @embedFile(base ++ ".gitattributes") },

    // Docker
    .{ .name = .docker, .path = "Dockerfile", .content = @embedFile(docker ++ "Dockerfile") },
    .{ .name = .docker, .path = "compose.yml", .content = @embedFile(docker ++ "compose.yml") },
    .{ .name = .docker, .path = ".dockerignore", .content = @embedFile(docker ++ ".dockerignore") },
};
