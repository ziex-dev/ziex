pub const FormData = @This();

const std = @import("std");
const Transport = @import("Transport.zig");

/// Entry type for iteration
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// Internal backend transport carrier. All reads delegate here.
_internal: Transport.Facade = .{},

/// Returns the first value associated with a given key from within a FormData object.
pub fn get(self: *const FormData, name: []const u8) ?[]const u8 {
    return self._internal.http.reqFormGet(name);
}

/// Returns whether a FormData object contains a certain key.
pub fn has(self: *const FormData, name: []const u8) bool {
    return self._internal.http.reqFormHas(name);
}

/// Iterator for FormData entries backed by parallel key/value arrays.
pub const Iterator = struct {
    pos: usize = 0,
    keys: []const []const u8,
    values: []const []const u8,

    /// Returns the next entry, or null if iteration is complete.
    pub fn next(self: *Iterator) ?Entry {
        if (self.pos >= self.keys.len) {
            return null;
        }
        const entry = Entry{
            .key = self.keys[self.pos],
            .value = self.values[self.pos],
        };
        self.pos += 1;
        return entry;
    }

    /// Resets the iterator to the beginning.
    pub fn reset(self: *Iterator) void {
        self.pos = 0;
    }
};
