const std = @import("std");

const LookaheadIterator = @import("lookahead_iterator.zig").LookaheadIterator;

/// The type of a grammar symbol.
const SymbolType = enum(c_uint) {
    regular,
    anonymous,
    supertype,
    auxiliary,
};

/// The metadata associated with a language.
///
/// Currently, this metadata can be used to check the [Semantic Version](https://semver.org/)
/// of the language. This version information should be used to signal if a given parser might
/// be incompatible with existing queries when upgrading between major versions, or minor versions
/// if it's in zerover.
const LanguageMetadata = extern struct {
    major_version: u8,
    minor_version: u8,
    patch_version: u8,
};

const LanguageFn = *const fn () callconv(.c) *const Language;

/// An opaque object that defines how to parse a particular language.
pub const Language = opaque {
    /// Cast a raw pointer to a Language pointer.
    pub fn fromRaw(ptr: *const anyopaque) *const Language {
        return @ptrCast(ptr);
    }

    /// Free any dynamically-allocated resources for this language, if this is the last reference.
    pub fn destroy(self: *const Language) void {
        ts_language_delete(self);
    }

    /// Get another reference to the given language.
    pub fn dupe(self: *const Language) *const Language {
        return ts_language_copy(self);
    }

    /// Get the name of the language, if available.
    pub fn name(self: *const Language) ?[]const u8 {
        return if (ts_language_name(self)) |n| std.mem.span(n) else null;
    }

    /// Get the ABI version number that indicates which version of the
    /// Tree-sitter CLI that was used to generate this language.
    pub fn abiVersion(self: *const Language) u32 {
        return ts_language_abi_version(self);
    }

    /// Get the semantic version for this language.
    pub fn semanticVersion(self: *const Language) ?std.SemanticVersion {
        const metadata = ts_language_metadata(self) orelse return null;
        return .{
            .major = @intCast(metadata.major_version),
            .minor = @intCast(metadata.minor_version),
            .patch = @intCast(metadata.patch_version),
        };
    }

    /// Check if the language came from a Wasm module.
    ///
    /// If so, then in order to use this language with a `Parser`,
    /// that parser must have a `WasmStore` assigned.
    pub inline fn isWasm(self: *const Language) bool {
        return ts_language_is_wasm(self);
    }

    /// Get the number of distinct node types in this language.
    pub fn nodeKindCount(self: *const Language) u32 {
        return ts_language_symbol_count(self);
    }

    /// Get the number of valid states in this language.
    pub fn parseStateCount(self: *const Language) u32 {
        return ts_language_state_count(self);
    }

    /// Get a list of all supertype symbols for the language.
    pub fn supertypes(self: *const Language) []const u16 {
        var length: u32 = 0;
        const results = ts_language_supertypes(self, &length);
        return if (length > 0) results[0..length] else &.{};
    }

    /// Get a list of all subtype symbols for a given supertype symbol.
    pub fn subtypesForSupertype(self: *const Language, supertype: u16) []const u16 {
        var length: u32 = 0;
        const results = ts_language_subtypes(self, supertype, &length);
        return if (length > 0) results[0..length] else &.{};
    }

    /// Get the name of the node kind for the given numerical id.
    pub fn nodeKindForId(self: *const Language, symbol: u16) ?[]const u8 {
        return if (ts_language_symbol_name(self, symbol)) |n| std.mem.span(n) else null;
    }

    /// Get the numeric id for the given node kind.
    pub fn idForNodeKind(self: *const Language, string: []const u8, is_named: bool) u16 {
        return ts_language_symbol_for_name(self, string.ptr, @intCast(string.len), is_named);
    }

    /// Check if the node type for the given numerical id is named (as opposed to an anonymous node type).
    pub fn nodeKindIsNamed(self: *const Language, symbol: u16) bool {
        return ts_language_symbol_type(self, symbol) == .regular;
    }

    /// Check if the node type for the given numerical id is visible (as opposed to a hidden node type).
    pub fn nodeKindIsVisible(self: *const Language, symbol: u16) bool {
        const symbol_type = ts_language_symbol_type(self, symbol);
        return @backingInt(symbol_type) <= @backingInt(SymbolType.anonymous);
    }

    /// Check if the node for the given numerical ID is a supertype.
    pub fn nodeKindIsSupertype(self: *const Language, symbol: u16) bool {
        return ts_language_symbol_type(self, symbol) == .supertype;
    }

    /// Get the number of distinct field names in this language.
    pub fn fieldCount(self: *const Language) u32 {
        return ts_language_field_count(self);
    }

    /// Get the field name for the given numerical id.
    pub fn fieldNameForId(self: *const Language, field_id: u16) ?[]const u8 {
        return if (ts_language_field_name_for_id(self, field_id)) |n| std.mem.span(n) else null;
    }

    /// Get the numerical id for the given field name.
    pub fn fieldIdForName(self: *const Language, field_name: []const u8) u16 {
        return ts_language_field_id_for_name(self, field_name.ptr, @intCast(field_name.len));
    }

    /// Get the next parse state.
    ///
    /// Combine this with a `LookaheadIterator` to generate
    /// completion suggestions or valid symbols in error nodes.
    ///
    /// Example:
    ///
    /// ```zig
    /// language.nextState(node.parseState(), node.grammarSymbol());
    /// ```
    pub fn nextState(self: *const Language, state: u16, symbol: u16) u16 {
        return ts_language_next_state(self, state, symbol);
    }

    /// Create a new lookahead iterator for this language and parse state.
    ///
    /// This returns `null` if `state` is invalid for this language.
    ///
    /// Iterating `LookaheadIterator` will yield valid symbols in the given
    /// parse state. Newly created lookahead iterators will return the `ERROR`
    /// symbol from `LookaheadIterator.current_symbol()`.
    ///
    /// Lookahead iterators can be useful to generate suggestions and improve
    /// syntax error diagnostics. To get symbols valid in an `ERROR` node, use the
    /// lookahead iterator on its first leaf node state. For `MISSING` nodes, a
    /// lookahead iterator created on the previous non-extra leaf node may be
    /// appropriate.
    pub fn lookaheadIterator(self: *const Language, state: u16) ?*LookaheadIterator {
        return ts_lookahead_iterator_new(self, state);
    }

    /// Format the language as a string.
    pub fn format(self: Language, writer: *std.Io.Writer) !void {
        return try writer.print(
            "Language(id=0x{*}, version={d}, name={?s})",
            .{ self, self.abi_version(), self.name() },
        );
    }
};

extern fn ts_language_abi_version(self: *const Language) u32;
extern fn ts_language_copy(self: *const Language) *const Language;
extern fn ts_language_delete(self: *const Language) void;
extern fn ts_language_field_count(self: *const Language) u32;
extern fn ts_language_field_id_for_name(self: *const Language, name: [*]const u8, name_length: u32) u16;
extern fn ts_language_field_name_for_id(self: *const Language, id: u16) ?[*:0]const u8;
extern fn ts_language_is_wasm(language: *const Language) bool;
extern fn ts_language_metadata(self: *const Language) ?*const LanguageMetadata;
extern fn ts_language_name(self: *const Language) ?[*:0]const u8;
extern fn ts_language_next_state(self: *const Language, state: u16, symbol: u16) u16;
extern fn ts_language_state_count(self: *const Language) u32;
extern fn ts_language_subtypes(self: *const Language, supertype: u16, length: *u32) [*c]const u16;
extern fn ts_language_supertypes(self: *const Language, length: *u32) [*c]const u16;
extern fn ts_language_symbol_count(self: *const Language) u32;
extern fn ts_language_symbol_for_name(self: *const Language, string: [*]const u8, length: u32, is_named: bool) u16;
extern fn ts_language_symbol_name(self: *const Language, symbol: u16) ?[*:0]const u8;
extern fn ts_language_symbol_type(self: *const Language, symbol: u16) SymbolType;
extern fn ts_lookahead_iterator_new(self: *const Language, state: u16) ?*LookaheadIterator;
