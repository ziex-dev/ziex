pub const Client = @import("websocket/Client.zig");
pub const Socket = @import("websocket/Socket.zig");

pub const Message = Client.Message;
pub const MessageEvent = Client.MessageEvent;
pub const CloseEvent = Client.CloseEvent;
pub const ErrorEvent = Client.ErrorEvent;
pub const CloseOptions = Client.CloseOptions;
pub const ConnectOptions = Client.ConnectOptions;
pub const ReadyState = Client.ReadyState;
pub const Error = Client.Error;
