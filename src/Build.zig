const Build = @This();

const std = @import("std");

const element = @import("element.zig");

pub const Manifest = @import("build/Manifest.zig");
pub const BuildConfig = @import("build/init/BuildConfig.zig");
pub const Testing = @import("build/testing.zig");
pub const webglue = @import("build/webglue.zig");

pub const AddElementOptions = struct {
    id: ?[]const u8 = null,
    parent: Parent,
    position: Position,
    element: ElementDef,
    priority: u8 = 128,
    pathname: Pathname = .{},

    pub const Id = struct {
        pub const jsglue = "jsglue";
        pub const wasmlink = "wasmlink";
    };

    pub const ElementDef = struct {
        tag: element.Tag,
        children: ?[]const Child = null,
        attributes: []const Attribute = &.{},

        pub const Attribute = struct {
            name: []const u8,
            value: ?[]const u8 = null,
        };
        pub const Child = union(enum) {
            text: []const u8,
            element: ElementDef,
        };
    };

    pub const Parent = enum { body, head };
    pub const Position = enum { starting, ending };

    /// Pathname filter for when this injection should apply.
    /// - `excludes` win: any match skips the injection
    /// - empty `includes` means all pathnames
    /// - non-empty `includes` requires at least one match
    /// Patterns ending in `*` are prefix matches; otherwise exact.
    pub const Pathname = struct {
        includes: []const []const u8 = &.{},
        excludes: []const []const u8 = &.{},

        pub fn matches(self: Pathname, pathname: []const u8) bool {
            for (self.excludes) |pattern| {
                if (matchPattern(pattern, pathname)) return false;
            }
            if (self.includes.len == 0) return true;
            for (self.includes) |pattern| {
                if (matchPattern(pattern, pathname)) return true;
            }
            return false;
        }

        fn matchPattern(pattern: []const u8, pathname: []const u8) bool {
            if (pattern.len > 0 and pattern[pattern.len - 1] == '*') {
                return std.mem.startsWith(u8, pathname, pattern[0 .. pattern.len - 1]);
            }
            return std.mem.eql(u8, pattern, pathname);
        }
    };
};
