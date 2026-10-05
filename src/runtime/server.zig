const server = @import("server/Server.zig");

pub const Event = @import("server/Event.zig");
pub const Action = @import("server/Action.zig");
pub const render = @import("server/render.zig");

// Legacy --- will be renamed
pub const SerilizableAppMeta = server.SerilizableAppMeta;
pub const App = server.ServerApp;
pub const server_app = server.server_app;

// Legacy -- may be kept
pub const Request = @import("core/Http/Request.zig");
pub const Response = @import("core/Http/Response.zig");
