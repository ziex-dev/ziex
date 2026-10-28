//! Backend interface behind `Request`, `Response` and `Socket`. Server backends implement the vtable.
const Transport = @This();

const std = @import("std");

const CookieOptions = @import("../http.zig").CookieOptions;
const MultiFormValue = @import("MultiFormData.zig").Value;
const WebSocketMessage = @import("../WebSocket.zig").Message;

userdata: ?*anyopaque = null,
vtable: *const VTable = &failing_vtable,

pub const Facade = struct {
    http: Transport = .{},
};

pub const VTable = struct {
    reqText: *const fn (userdata: ?*anyopaque) ?[]const u8,

    reqHeaderGet: *const fn (userdata: ?*anyopaque, name: []const u8) ?[]const u8,
    reqHeaderHas: *const fn (userdata: ?*anyopaque, name: []const u8) bool,

    reqParam: *const fn (userdata: ?*anyopaque, name: []const u8) ?[]const u8,

    reqQueryGet: *const fn (userdata: ?*anyopaque, name: []const u8) ?[]const u8,
    reqQueryHas: *const fn (userdata: ?*anyopaque, name: []const u8) bool,

    reqFormGet: *const fn (userdata: ?*anyopaque, name: []const u8) ?[]const u8,
    reqFormHas: *const fn (userdata: ?*anyopaque, name: []const u8) bool,

    reqMultiGet: *const fn (userdata: ?*anyopaque, name: []const u8) ?MultiFormValue,
    reqMultiHas: *const fn (userdata: ?*anyopaque, name: []const u8) bool,
    reqMultiGetAll: *const fn (userdata: ?*anyopaque, name: []const u8, allocator: std.mem.Allocator) ?[]const MultiFormValue,

    resSetStatus: *const fn (userdata: ?*anyopaque, code: u16) void,
    resSetBody: *const fn (userdata: ?*anyopaque, content: []const u8) void,

    resHeaderGet: *const fn (userdata: ?*anyopaque, name: []const u8) ?[]const u8,
    resHeaderSet: *const fn (userdata: ?*anyopaque, name: []const u8, value: []const u8) void,
    resHeaderAppend: *const fn (userdata: ?*anyopaque, name: []const u8, value: []const u8) void,

    resWriter: *const fn (userdata: ?*anyopaque) ?*std.Io.Writer,
    resWrite: *const fn (userdata: ?*anyopaque, data: []const u8) anyerror!void,
    resClearWriter: *const fn (userdata: ?*anyopaque) void,

    resSetCookie: *const fn (userdata: ?*anyopaque, name: []const u8, value: []const u8, opts: CookieOptions) anyerror!void,

    wsUpgrade: *const fn (userdata: ?*anyopaque, data: ?[]const u8) anyerror!void,
    wsSend: *const fn (userdata: ?*anyopaque, message: WebSocketMessage) anyerror!void,
    wsRead: *const fn (userdata: ?*anyopaque) ?WebSocketMessage,
    wsClose: *const fn (userdata: ?*anyopaque) void,
    wsSubscribe: *const fn (userdata: ?*anyopaque, topic: []const u8) void,
    wsUnsubscribe: *const fn (userdata: ?*anyopaque, topic: []const u8) void,
    wsPublish: *const fn (userdata: ?*anyopaque, topic: []const u8, message: []const u8) usize,
    wsIsSubscribed: *const fn (userdata: ?*anyopaque, topic: []const u8) bool,
    wsSetPublishToSelf: *const fn (userdata: ?*anyopaque, value: bool) void,
};

pub fn reqText(self: Transport) ?[]const u8 {
    return self.vtable.reqText(self.userdata);
}
pub fn reqHeaderGet(self: Transport, name: []const u8) ?[]const u8 {
    return self.vtable.reqHeaderGet(self.userdata, name);
}
pub fn reqHeaderHas(self: Transport, name: []const u8) bool {
    return self.vtable.reqHeaderHas(self.userdata, name);
}
pub fn reqParam(self: Transport, name: []const u8) ?[]const u8 {
    return self.vtable.reqParam(self.userdata, name);
}
pub fn reqQueryGet(self: Transport, name: []const u8) ?[]const u8 {
    return self.vtable.reqQueryGet(self.userdata, name);
}
pub fn reqQueryHas(self: Transport, name: []const u8) bool {
    return self.vtable.reqQueryHas(self.userdata, name);
}
pub fn reqFormGet(self: Transport, name: []const u8) ?[]const u8 {
    return self.vtable.reqFormGet(self.userdata, name);
}
pub fn reqFormHas(self: Transport, name: []const u8) bool {
    return self.vtable.reqFormHas(self.userdata, name);
}
pub fn reqMultiGet(self: Transport, name: []const u8) ?MultiFormValue {
    return self.vtable.reqMultiGet(self.userdata, name);
}
pub fn reqMultiHas(self: Transport, name: []const u8) bool {
    return self.vtable.reqMultiHas(self.userdata, name);
}
pub fn reqMultiGetAll(self: Transport, name: []const u8, allocator: std.mem.Allocator) ?[]const MultiFormValue {
    return self.vtable.reqMultiGetAll(self.userdata, name, allocator);
}

pub fn resSetStatus(self: Transport, code: u16) void {
    self.vtable.resSetStatus(self.userdata, code);
}
pub fn resSetBody(self: Transport, content: []const u8) void {
    self.vtable.resSetBody(self.userdata, content);
}
pub fn resHeaderGet(self: Transport, name: []const u8) ?[]const u8 {
    return self.vtable.resHeaderGet(self.userdata, name);
}
pub fn resHeaderSet(self: Transport, name: []const u8, value: []const u8) void {
    self.vtable.resHeaderSet(self.userdata, name, value);
}
pub fn resHeaderAppend(self: Transport, name: []const u8, value: []const u8) void {
    self.vtable.resHeaderAppend(self.userdata, name, value);
}
pub fn resWriter(self: Transport) ?*std.Io.Writer {
    return self.vtable.resWriter(self.userdata);
}
pub fn resWrite(self: Transport, data: []const u8) anyerror!void {
    return self.vtable.resWrite(self.userdata, data);
}
pub fn resClearWriter(self: Transport) void {
    self.vtable.resClearWriter(self.userdata);
}
pub fn resSetCookie(self: Transport, name: []const u8, value: []const u8, opts: CookieOptions) anyerror!void {
    return self.vtable.resSetCookie(self.userdata, name, value, opts);
}

pub fn wsUpgrade(self: Transport, data: ?[]const u8) anyerror!void {
    return self.vtable.wsUpgrade(self.userdata, data);
}
pub fn wsSend(self: Transport, message: WebSocketMessage) anyerror!void {
    return self.vtable.wsSend(self.userdata, message);
}
pub fn wsRead(self: Transport) ?WebSocketMessage {
    return self.vtable.wsRead(self.userdata);
}
pub fn wsClose(self: Transport) void {
    self.vtable.wsClose(self.userdata);
}
pub fn wsSubscribe(self: Transport, topic: []const u8) void {
    self.vtable.wsSubscribe(self.userdata, topic);
}
pub fn wsUnsubscribe(self: Transport, topic: []const u8) void {
    self.vtable.wsUnsubscribe(self.userdata, topic);
}
pub fn wsPublish(self: Transport, topic: []const u8, message: []const u8) usize {
    return self.vtable.wsPublish(self.userdata, topic, message);
}
pub fn wsIsSubscribed(self: Transport, topic: []const u8) bool {
    return self.vtable.wsIsSubscribed(self.userdata, topic);
}
pub fn wsSetPublishToSelf(self: Transport, value: bool) void {
    self.vtable.wsSetPublishToSelf(self.userdata, value);
}

fn failNullStr(_: ?*anyopaque) ?[]const u8 {
    return null;
}
fn failNamedStr(_: ?*anyopaque, _: []const u8) ?[]const u8 {
    return null;
}
fn failNamedBool(_: ?*anyopaque, _: []const u8) bool {
    return false;
}
fn failMultiGet(_: ?*anyopaque, _: []const u8) ?MultiFormValue {
    return null;
}
fn failMultiGetAll(_: ?*anyopaque, _: []const u8, _: std.mem.Allocator) ?[]const MultiFormValue {
    return null;
}
fn failSetStatus(_: ?*anyopaque, _: u16) void {}
fn failSetBody(_: ?*anyopaque, _: []const u8) void {}
fn failHeaderSet(_: ?*anyopaque, _: []const u8, _: []const u8) void {}
fn failWriter(_: ?*anyopaque) ?*std.Io.Writer {
    return null;
}
fn failWrite(_: ?*anyopaque, _: []const u8) anyerror!void {}
fn failClearWriter(_: ?*anyopaque) void {}
fn failSetCookie(_: ?*anyopaque, _: []const u8, _: []const u8, _: CookieOptions) anyerror!void {}
fn failWsUpgrade(_: ?*anyopaque, _: ?[]const u8) anyerror!void {
    return error.WebSocketNotConnected;
}
fn failWsSend(_: ?*anyopaque, _: WebSocketMessage) anyerror!void {
    return error.WebSocketNotConnected;
}
fn failWsRead(_: ?*anyopaque) ?WebSocketMessage {
    return null;
}
fn failWsClose(_: ?*anyopaque) void {}
fn failWsSubscribe(_: ?*anyopaque, _: []const u8) void {}
fn failWsPublish(_: ?*anyopaque, _: []const u8, _: []const u8) usize {
    return 0;
}
fn failWsIsSubscribed(_: ?*anyopaque, _: []const u8) bool {
    return false;
}
fn failWsSetPublishToSelf(_: ?*anyopaque, _: bool) void {}

pub const failing_vtable = VTable{
    .reqText = &failNullStr,
    .reqHeaderGet = &failNamedStr,
    .reqHeaderHas = &failNamedBool,
    .reqParam = &failNamedStr,
    .reqQueryGet = &failNamedStr,
    .reqQueryHas = &failNamedBool,
    .reqFormGet = &failNamedStr,
    .reqFormHas = &failNamedBool,
    .reqMultiGet = &failMultiGet,
    .reqMultiHas = &failNamedBool,
    .reqMultiGetAll = &failMultiGetAll,
    .resSetStatus = &failSetStatus,
    .resSetBody = &failSetBody,
    .resHeaderGet = &failNamedStr,
    .resHeaderSet = &failHeaderSet,
    .resHeaderAppend = &failHeaderSet,
    .resWriter = &failWriter,
    .resWrite = &failWrite,
    .resClearWriter = &failClearWriter,
    .resSetCookie = &failSetCookie,
    .wsUpgrade = &failWsUpgrade,
    .wsSend = &failWsSend,
    .wsRead = &failWsRead,
    .wsClose = &failWsClose,
    .wsSubscribe = &failWsSubscribe,
    .wsUnsubscribe = &failWsSubscribe,
    .wsPublish = &failWsPublish,
    .wsIsSubscribed = &failWsIsSubscribed,
    .wsSetPublishToSelf = &failWsSetPublishToSelf,
};

pub const failing = Transport{ .vtable = &failing_vtable };
