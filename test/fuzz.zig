// Fuzz tests: `zig build test` runs each corpus once; `zig build test --fuzz[=limit]`
// fuzzes them coverage-guided.
test {
    _ = @import("fuzz/wire.zig");
    _ = @import("fuzz/text.zig");
    _ = @import("fuzz/data.zig");
}
