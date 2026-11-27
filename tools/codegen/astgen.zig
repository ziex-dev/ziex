const std = @import("std");

pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    indent: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{ .allocator = allocator, .buffer = .empty };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn push(self: *Editor, text: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, text);
    }

    pub fn newline(self: *Editor) !void {
        try self.push("\n");
    }

    pub fn blankLine(self: *Editor) !void {
        try self.newline();
    }

    pub fn writeIndent(self: *Editor) !void {
        try self.buffer.appendNTimes(self.allocator, ' ', self.indent * 4);
    }

    pub fn line(self: *Editor, text: []const u8) !void {
        try self.writeIndent();
        try self.push(text);
        try self.newline();
    }

    pub fn linef(self: *Editor, comptime fmt: []const u8, args: anytype) !void {
        try self.writeIndent();
        try self.buffer.print(self.allocator, fmt, args);
        try self.newline();
    }

    pub fn block(self: *Editor, text: []const u8) !void {
        var it = std.mem.tokenizeAny(u8, text, "\n");
        while (it.next()) |chunk| {
            if (chunk.len == 0) {
                try self.newline();
                continue;
            }
            try self.writeIndent();
            try self.push(chunk);
            try self.newline();
        }
    }

    pub fn emitDoc(self: *Editor, prose: []const u8) !void {
        if (prose.len == 0) return;
        var it = std.mem.tokenizeAny(u8, prose, "\n");
        while (it.next()) |chunk| {
            try self.writeIndent();
            try self.push("/// ");
            try self.push(chunk);
            try self.newline();
        }
    }

    pub fn finish(self: *Editor) ![]const u8 {
        const raw = try self.buffer.toOwnedSlice(self.allocator);
        defer self.allocator.free(raw);

        const sentinel = try self.allocator.alloc(u8, raw.len + 1);
        defer self.allocator.free(sentinel);
        @memcpy(sentinel[0..raw.len], raw);
        sentinel[raw.len] = 0;

        var tree = try std.zig.Ast.parse(self.allocator, sentinel[0..raw.len :0], .{ .mode = .zig });
        defer tree.deinit(self.allocator);
        if (tree.errors.len != 0) return error.InvalidGeneratedSource;

        return try tree.renderAlloc(self.allocator);
    }
};

pub const File = struct {
    arena: std.heap.ArenaAllocator,
    decls: std.ArrayList(*DeclNode),

    pub fn init(child_allocator: std.mem.Allocator) File {
        return .{ .arena = std.heap.ArenaAllocator.init(child_allocator), .decls = .empty };
    }

    pub fn deinit(self: *File) void {
        self.decls.deinit(self.allocator());
        self.arena.deinit();
    }

    fn allocator(self: *File) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn addImport(self: *File, name: []const u8, path: []const u8) !void {
        const node = try self.newNode(.{ .import = .{ .name = try self.dupe(name), .path = try self.dupe(path) } });
        try self.decls.append(self.allocator(), node);
    }

    pub fn addConst(self: *File, name: []const u8, type_expr: []const u8, value_expr: []const u8) !*ConstDecl {
        const node = try self.newNode(.{ .const_decl = .{
            .name = try self.dupe(name),
            .type_expr = try self.dupe(type_expr),
            .value_expr = try self.dupe(value_expr),
        } });
        try self.decls.append(self.allocator(), node);
        return &node.decl.const_decl;
    }

    pub fn addStruct(self: *File, name: []const u8) !*ContainerDecl {
        const node = try self.newNode(.{ .container = try self.newContainer(.struct_decl, name) });
        try self.decls.append(self.allocator(), node);
        return &node.decl.container;
    }

    pub fn addUnion(self: *File, name: []const u8, tag_type: []const u8) !*ContainerDecl {
        const node = try self.newNode(.{ .container = try self.newContainer(.union_decl, name) });
        node.decl.container.tag_type = try self.dupe(tag_type);
        try self.decls.append(self.allocator(), node);
        return &node.decl.container;
    }

    pub fn addFn(self: *File, name: []const u8, signature: []const u8, body: []const u8) !*FnDecl {
        const node = try self.newNode(.{ .func = .{
            .name = try self.dupe(name),
            .signature = try self.dupe(signature),
            .body = try self.dupe(body),
            .doc = "",
        } });
        try self.decls.append(self.allocator(), node);
        return &node.decl.func;
    }

    pub fn addRaw(self: *File, text: []const u8) !void {
        const node = try self.newNode(.{ .raw = try self.dupe(text) });
        try self.decls.append(self.allocator(), node);
    }

    pub fn finish(self: *File) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator());
        defer out.deinit();
        const w = &out.writer;

        for (self.decls.items) |decl| {
            try decl.render(w);
            try w.writeByte('\n');
            try w.writeByte('\n');
        }

        const raw = out.written();
        const final_allocator = self.arena.child_allocator;

        const sentinel = try final_allocator.alloc(u8, raw.len + 1);
        defer final_allocator.free(sentinel);
        @memcpy(sentinel[0..raw.len], raw);
        sentinel[raw.len] = 0;

        var tree = std.zig.Ast.parse(final_allocator, sentinel[0..raw.len :0], .{ .mode = .zig }) catch |err| {
            std.debug.print("AST parse error: {any}\n", .{err});
            return err;
        };
        defer tree.deinit(final_allocator);
        if (tree.errors.len != 0) {
            std.debug.print("Invalid generated source:\n{s}\n", .{raw});
            return error.InvalidGeneratedSource;
        }

        return try tree.renderAlloc(final_allocator);
    }

    fn newNode(self: *File, decl: Decl) !*DeclNode {
        const node = try self.allocator().create(DeclNode);
        node.* = .{ .decl = decl };
        return node;
    }

    fn newContainer(self: *File, kind: ContainerKind, name: []const u8) !ContainerDecl {
        return .{
            .kind = kind,
            .name = try self.dupe(name),
            .doc = "",
            .tag_type = "enum",
            .fields = .empty,
            .methods = .empty,
        };
    }

    fn dupe(self: *File, text: []const u8) ![]const u8 {
        return try self.allocator().dupe(u8, text);
    }
};

const DeclNode = struct {
    decl: Decl,

    pub fn render(self: *const DeclNode, w: anytype) !void {
        switch (self.decl) {
            .import => |v| try v.render(w),
            .const_decl => |v| try v.render(w),
            .container => |v| try v.render(w),
            .func => |v| try v.render(w),
            .raw => |s| try w.writeAll(s),
        }
    }
};

const Decl = union(enum) {
    import: ImportDecl,
    const_decl: ConstDecl,
    container: ContainerDecl,
    func: FnDecl,
    raw: []const u8,
};

const ImportDecl = struct {
    name: []const u8,
    path: []const u8,

    pub fn render(self: ImportDecl, w: anytype) !void {
        try w.print("const {s} = @import(\"{s}\");", .{ self.name, self.path });
    }
};

const ConstDecl = struct {
    name: []const u8,
    type_expr: []const u8,
    value_expr: []const u8,

    pub fn render(self: ConstDecl, w: anytype) !void {
        if (self.type_expr.len > 0) {
            try w.print("pub const {s}: {s} = {s};", .{ self.name, self.type_expr, self.value_expr });
        } else {
            try w.print("pub const {s} = {s};", .{ self.name, self.value_expr });
        }
    }
};

const ContainerKind = enum { struct_decl, union_decl };

pub const Field = struct {
    doc: []const u8 = "",
    name: []const u8,
    type_expr: []const u8,
    default_expr: ?[]const u8 = null,
};

pub const ContainerDecl = struct {
    kind: ContainerKind,
    name: []const u8,
    doc: []const u8,
    tag_type: []const u8,
    fields: std.ArrayList(Field),
    methods: std.ArrayList(*FnDecl),

    pub fn addField(self: *ContainerDecl, allocator: std.mem.Allocator, doc: []const u8, name: []const u8, type_expr: []const u8, default_expr: ?[]const u8) !void {
        try self.fields.append(allocator, .{
            .doc = try allocator.dupe(u8, doc),
            .name = try allocator.dupe(u8, name),
            .type_expr = try allocator.dupe(u8, type_expr),
            .default_expr = if (default_expr) |v| try allocator.dupe(u8, v) else null,
        });
    }

    pub fn setDoc(self: *ContainerDecl, allocator: std.mem.Allocator, doc: []const u8) !void {
        self.doc = try allocator.dupe(u8, doc);
    }

    pub fn addMethod(self: *ContainerDecl, allocator: std.mem.Allocator, doc: []const u8, name: []const u8, signature: []const u8, body: []const u8) !*FnDecl {
        const fn_decl = try allocator.create(FnDecl);
        fn_decl.* = .{
            .name = try allocator.dupe(u8, name),
            .signature = try allocator.dupe(u8, signature),
            .body = try allocator.dupe(u8, body),
            .doc = try allocator.dupe(u8, doc),
        };
        try self.methods.append(allocator, fn_decl);
        return fn_decl;
    }

    pub fn render(self: ContainerDecl, w: anytype) !void {
        if (self.doc.len > 0) try emitDoc(w, self.doc, "");
        switch (self.kind) {
            .struct_decl => try w.print("pub const {s} = struct {{", .{self.name}),
            .union_decl => try w.print("pub const {s} = union({s}) {{", .{ self.name, self.tag_type }),
        }
        try w.writeByte('\n');
        for (self.fields.items) |field| {
            if (field.doc.len > 0) try emitDoc(w, field.doc, "    ");
            if (self.kind == .union_decl and field.type_expr.len == 0) {
                try w.print("    {s},\n", .{field.name});
                continue;
            }
            try w.print("    {s}: {s}", .{ field.name, field.type_expr });
            if (field.default_expr) |d| try w.print(" = {s}", .{d});
            try w.writeAll(",\n");
        }
        if (self.methods.items.len > 0 and self.fields.items.len > 0) try w.writeByte('\n');
        for (self.methods.items) |method| {
            try method.renderIndented(w, "    ");
            try w.writeByte('\n');
        }
        try w.writeAll("};");
    }
};

pub const FnDecl = struct {
    name: []const u8,
    signature: []const u8,
    body: []const u8,
    doc: []const u8 = "",

    pub fn render(self: FnDecl, w: anytype) !void {
        try self.renderIndented(w, "");
    }

    pub fn renderIndented(self: FnDecl, w: anytype, indent: []const u8) !void {
        if (self.doc.len > 0) try emitDoc(w, self.doc, indent);
        try w.print("{s}pub fn {s}{s} {{\n", .{ indent, self.name, self.signature });
        var it = std.mem.tokenizeAny(u8, self.body, "\n");
        while (it.next()) |line| {
            if (line.len == 0) {
                try w.writeByte('\n');
                continue;
            }
            try w.print("{s}    {s}\n", .{ indent, line });
        }
        try w.print("{s}}}", .{indent});
    }
};

fn emitDoc(w: anytype, prose: []const u8, indent: []const u8) !void {
    if (prose.len == 0) return;
    var it = std.mem.tokenizeAny(u8, prose, "\n");
    while (it.next()) |line| {
        try w.print("{s}/// {s}\n", .{ indent, line });
    }
}
