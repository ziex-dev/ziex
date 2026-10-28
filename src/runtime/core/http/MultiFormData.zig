pub const MultiFormData = @This();

const std = @import("std");
const Transport = @import("Transport.zig");

pub const File = @import("File.zig");

/// A single form data entry value, which can be a string or a file.
pub const Value = struct {
    /// The value content as bytes
    data: []const u8,
    /// Optional filename for file uploads (null for regular fields)
    filename: ?[]const u8 = null,

    /// Returns true if this entry represents a file upload
    pub fn isFile(self: Value) bool {
        return self.filename != null;
    }
};

/// Entry type for iteration
pub const Entry = struct {
    key: []const u8,
    value: Value,
};

/// Internal backend transport carrier. All reads delegate here.
_internal: Transport.Facade = .{},

/// Returns the first value associated with a given key from within a MultiFormData object.
pub fn get(self: *const MultiFormData, name: []const u8) ?Value {
    return self._internal.http.reqMultiGet(name);
}

/// Returns the first string value associated with a given key.
pub fn getValue(self: *const MultiFormData, name: []const u8) ?[]const u8 {
    if (self.get(name)) |v| {
        return v.data;
    }
    return null;
}

/// Returns an array of all the values associated with a given key from within a MultiFormData.
pub fn getAll(self: *const MultiFormData, name: []const u8, allocator: std.mem.Allocator) ?[]const Value {
    return self._internal.http.reqMultiGetAll(name, allocator);
}

/// Returns whether a MultiFormData object contains a certain key.
pub fn has(self: *const MultiFormData, name: []const u8) bool {
    return self._internal.http.reqMultiHas(name);
}

/// Iterator for MultiFormData entries backed by parallel key/value arrays.
pub const Iterator = struct {
    pos: usize = 0,
    keys: []const []const u8,
    values: []const Value,

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
