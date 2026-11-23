const std = @import("std");
const Flag = @import("../Flag.zig");
const http = @import("../http.zig");

const log = std.log.scoped(.zx_flag);

// OpenFeature evaluation details, as sent by OFREP and Flagship.
pub const Reply = struct {
    value: ?std.json.Value = null,
    variant: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    errorCode: ?[]const u8 = null,
    errorDetails: ?[]const u8 = null,
    errorMessage: ?[]const u8 = null,
    metadata: ?std.json.Value = null,

    pub fn resolution(r: Reply) Flag.Error!Flag.Resolution {
        if (r.errorCode) |code| return errorCode(code);
        return .{
            .value = if (r.value) |v| try Flag.Value.fromJson(v) else null,
            .variant = r.variant,
            .reason = reason(r.reason orelse ""),
            .metadata = r.metadata,
        };
    }
};

pub fn reason(s: []const u8) Flag.Reason {
    const map = std.StaticStringMap(Flag.Reason).initComptime(.{
        .{ "STATIC", .static },
        .{ "DEFAULT", .default },
        .{ "TARGETING_MATCH", .targeting_match },
        .{ "SPLIT", .split },
        .{ "CACHED", .cached },
        .{ "DISABLED", .disabled },
        .{ "STALE", .stale },
        .{ "ERROR", .@"error" },
    });
    return map.get(s) orelse .unknown;
}

pub fn errorCode(s: []const u8) Flag.Error {
    const map = std.StaticStringMap(Flag.Error).initComptime(.{
        .{ "PROVIDER_NOT_READY", error.ProviderNotReady },
        .{ "FLAG_NOT_FOUND", error.FlagNotFound },
        .{ "PARSE_ERROR", error.ParseError },
        .{ "TYPE_MISMATCH", error.TypeMismatch },
        .{ "TARGETING_KEY_MISSING", error.TargetingKeyMissing },
        .{ "INVALID_CONTEXT", error.InvalidContext },
        .{ "PROVIDER_FATAL", error.ProviderFatal },
    });
    return map.get(s) orelse error.General;
}

pub fn parse(comptime T: type, arena: std.mem.Allocator, body: []const u8) Flag.Error!T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{ .ignore_unknown_fields = true }) catch error.ParseError;
}

pub fn json(arena: std.mem.Allocator, payload: anytype) Flag.Error![]u8 {
    return std.json.Stringify.valueAlloc(arena, payload, .{ .emit_null_optional_fields = false }) catch error.General;
}

// Transport failures become `error.General`; the response is returned whatever its status.
pub fn post(io: std.Io, arena: std.mem.Allocator, url: []const u8, headers: []const http.Header, payload: anytype) Flag.Error!http.Client.Result {
    var client: http.Client = .{ .io = io, .allocator = arena };
    defer client.deinit();

    const res = client.fetch(.{ .url = url, .method = .POST, .headers = headers, .payload = try json(arena, payload) }) catch |err| {
        log.warn("{s}: {t}", .{ url, err });
        return error.General;
    };
    // 400 and 404 carry flag errors, not transport ones.
    if (res.status.class() != .success and res.status != .bad_request and res.status != .not_found) log.warn("{d} {s}: {s}", .{ @backingInt(res.status), url, res.body });
    return res;
}
