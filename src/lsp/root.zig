//! LSP package surface used by unit tests.
pub const hover = @import("features/hover.zig");
pub const complete = @import("features/autocomplete.zig");
pub const docs = @import("data/elements.zig");
pub const text = @import("text.zig");

test {
    _ = hover;
    _ = complete;
}
