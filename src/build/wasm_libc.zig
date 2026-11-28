//! What Zig's own libc (zigc, `lib/c.zig`) doesn't yet provide for C code in the client or
//! worker wasm. `Platform.linkLibc` links this with zigc built for wasm32-wasi, which
//! supplies malloc, `<string.h>` and `<ctype.h>`; compiler-rt supplies memcpy/memcmp/strlen.
//! There is no host libc in the browser, so stdio and printf are no-ops (C libraries like
//! tree-sitter only use them for debug logging). Symbols are weak and hidden, like zigc's,
//! so zigc or the app can still define them and they are not exported to the host.
const std = @import("std");

/// zigc's malloc sets it through `std.c._errno`, which wasi-libc would otherwise define.
export threadlocal var errno: c_int = 0;

fn abort() callconv(.c) noreturn {
    @trap();
}

// C `assert` in debug builds.
fn __assert_fail(_: [*:0]const u8, _: [*:0]const u8, _: c_uint, _: [*:0]const u8) callconv(.c) noreturn {
    @trap();
}

// Wide-char classes: ASCII exactly; beyond it, letters are assumed (identifiers) and the
// Unicode space separators are spaces.
fn iswalpha(c: u32) callconv(.c) c_int {
    return @intFromBool(if (c < 0x80) std.ascii.isAlphabetic(@intCast(c)) else !isUnicodeSpace(c));
}

fn iswalnum(c: u32) callconv(.c) c_int {
    return @intFromBool(iswdigit(c) != 0 or iswalpha(c) != 0);
}

fn iswdigit(c: u32) callconv(.c) c_int {
    return @intFromBool(c >= '0' and c <= '9');
}

fn iswspace(c: u32) callconv(.c) c_int {
    return @intFromBool(if (c < 0x80) std.ascii.isWhitespace(@intCast(c)) else isUnicodeSpace(c));
}

fn isUnicodeSpace(c: u32) bool {
    return switch (c) {
        0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

// In the wasm C ABI, variadic arguments arrive as one pointer, so `...` and `va_list`
// both lower to a trailing pointer parameter.
fn snprintf(buf: ?[*]u8, n: usize, _: [*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
    if (n > 0) buf.?[0] = 0;
    return 0;
}

fn fprintf(_: ?*anyopaque, _: [*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

fn fputc(c: c_int, _: ?*anyopaque) callconv(.c) c_int {
    return c;
}

fn fputs(_: [*:0]const u8, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

fn fwrite(_: ?*const anyopaque, _: usize, n: usize, _: ?*anyopaque) callconv(.c) usize {
    return n;
}

fn fclose(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

fn fdopen(_: c_int, _: [*:0]const u8) callconv(.c) ?*anyopaque {
    return null;
}

fn dup(_: c_int) callconv(.c) c_int {
    return -1;
}

var stderr: ?*anyopaque = null;

comptime {
    for (.{
        .{ "abort", &abort },       .{ "__assert_fail", &__assert_fail },
        .{ "iswalpha", &iswalpha }, .{ "iswalnum", &iswalnum },
        .{ "iswdigit", &iswdigit }, .{ "iswspace", &iswspace },
        .{ "snprintf", &snprintf }, .{ "vsnprintf", &snprintf },
        .{ "fprintf", &fprintf },   .{ "fputc", &fputc },
        .{ "fputs", &fputs },       .{ "fwrite", &fwrite },
        .{ "fclose", &fclose },     .{ "fdopen", &fdopen },
        .{ "dup", &dup },           .{ "stderr", &stderr },
    }) |entry| @export(entry[1], .{ .name = entry[0], .linkage = .weak, .visibility = .hidden });
}
