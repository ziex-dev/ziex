const std = @import("std");
const zx = @import("zx");
const webglue = zx.Build.webglue;

// (module (import "__zx_web" "Node.appendChild" (func)) (import "env" "x" (func)))
const wasm = "\x00asm\x01\x00\x00\x00" ++
    "\x01\x04\x01\x60\x00\x00" ++
    "\x02\x25\x02" ++
    "\x08__zx_web\x10Node.appendChild\x00\x00" ++
    "\x03env\x01x\x00\x00";

test "webglue reads only __zx_web imports" {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(std.testing.allocator);
    try webglue.importNames(std.testing.allocator, wasm, webglue.module_name, &names);
    try std.testing.expectEqual(@as(usize, 1), names.items.len);
    try std.testing.expectEqualStrings("Node.appendChild", names.items[0]);
}

test "webglue emits only used shims" {
    const glue = try webglue.generate(std.testing.allocator, wasm);
    defer std.testing.allocator.free(glue);
    try std.testing.expectEqualStrings(
        "globalThis.__zx_web=({R,S,N,H,W,F,V,A,T})=>{return{\"Node.appendChild\":(h,p0)=>H(R[h].appendChild(R[p0]))}};\n",
        glue,
    );
}

test "webglue marks wasm without web imports" {
    const glue = try webglue.generate(std.testing.allocator, "\x00asm\x01\x00\x00\x00");
    defer std.testing.allocator.free(glue);
    try std.testing.expectEqualStrings("globalThis.__zx_web=false;\n", glue);
}

test "webglue rejects non-wasm" {
    try std.testing.expectError(error.InvalidWasm, webglue.generate(std.testing.allocator, "nope"));
}
