const std = @import("std");

pub const Fingerprint = packed struct(u64) {
    id: u32,
    checksum: u32,

    pub fn generate(name: []const u8) Fingerprint {
        var source: std.Random.IoSource = .{ .io = std.testing.io };
        return .{
            .id = source.interface().intRangeLessThan(u32, 1, 0xffffffff),
            .checksum = std.hash.Crc32.hash(name),
        };
    }

    pub fn validate(n: Fingerprint, name: []const u8) bool {
        switch (n.id) {
            0x00000000, 0xffffffff => return false,
            else => return std.hash.Crc32.hash(name) == n.checksum,
        }
    }

    pub fn int(n: Fingerprint) u64 {
        return @bitCast(n);
    }
};

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    const stderr = std.fs.File.stderr();
    const stdout = std.fs.File.stdout();

    if (args.len < 3) {
        try stderr.writeAll("Usage: fingerprint <generate|validate> <name> [hex]\n");
        std.process.exit(1);
    }

    const cmd = args[1];
    const name = args[2];

    if (std.mem.eql(u8, cmd, "generate")) {
        const fp = Fingerprint.generate(name);
        var buf: [20]u8 = undefined;
        const out = std.mem.print(&buf, "0x{x:0>16}\n", .{fp.int()}) catch unreachable;
        try stdout.writeAll(out);
    } else if (std.mem.eql(u8, cmd, "validate")) {
        if (args.len < 4) {
            try stderr.writeAll("Usage: fingerprint validate <name> <hex>\n");
            std.process.exit(1);
        }
        const hex = args[3];
        const raw = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;
        const value = std.fmt.parseInt(u64, raw, 16) catch {
            try stderr.writeAll("Invalid hex value\n");
            std.process.exit(1);
        };
        const fp: Fingerprint = @bitCast(value);
        const valid = fp.validate(name);
        try stdout.writeAll(if (valid) "true\n" else "false\n");
    } else {
        try stderr.writeAll("Unknown command. Use 'generate' or 'validate'.\n");
        std.process.exit(1);
    }
}
