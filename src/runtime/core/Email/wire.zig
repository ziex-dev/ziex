// JSON pieces shared by the HTTP and host-binding providers.
const std = @import("std");
const http = @import("../http.zig");

// Bytes as a base64 JSON string.
pub const Base64 = struct {
    bytes: []const u8,

    pub fn jsonStringify(self: Base64, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.beginWriteRaw();
        defer jw.endWriteRaw();
        try jw.writer.writeByte('"');
        std.base64.standard.Encoder.encodeWriter(jw.writer, self.bytes) catch return error.WriteFailed;
        try jw.writer.writeByte('"');
    }
};

// Headers as a `{ name: value }` object.
pub const Headers = struct {
    list: []const http.Header,

    pub fn jsonStringify(self: Headers, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.beginObject();
        for (self.list) |h| {
            try jw.objectField(h.name);
            try jw.write(h.value);
        }
        try jw.endObject();
    }
};
