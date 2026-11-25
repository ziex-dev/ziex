const window = @import("client/window.zig");

pub const Event = @import("client/Event.zig");
pub const Action = @import("client/Action.zig");
pub const events = @import("client/events/generated.zig");
pub const jsx = @import("client/jsx.zig");
/// Typed browser APIs generated from WebIDL (`zig build webgen`).
pub const web = @import("client/web/generated.zig");
pub const Callback = web.Callback;

// Legacy --- may get removed/renamed
const reactivity = @import("client/reactivity.zig");
pub const Document = window.Document;
pub const js = window.js;
pub const clearInterval = window.clearInterval;
pub const setInterval = window.setInterval;
pub const setTimeout = window.setTimeout;
pub const Console = window.Console;
pub const rerender = reactivity.rerender;
pub const eval = window.eval;
// TODO: this should have it's own place, it's not related to client only
pub const ComponentMeta = @import("client/Client.zig").ComponentMeta;
