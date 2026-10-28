const std = @import("std");
const astgen = @import("astgen.zig");

// WebIDL primitive -> Zig type mapping.
// Returns null to signal "skip this field" for unsupported types.
fn idlToZig(idl_type: []const u8, nullable: bool) ?[]const u8 {
    const inner: []const u8 = blk: {
        if (eql(idl_type, "boolean")) break :blk "bool";
        if (eql(idl_type, "long") or eql(idl_type, "signed long")) break :blk "i32";
        if (eql(idl_type, "unsigned long")) break :blk "u32";
        if (eql(idl_type, "short")) break :blk "i16";
        if (eql(idl_type, "unsigned short")) break :blk "u16";
        if (eql(idl_type, "long long")) break :blk "i64";
        if (eql(idl_type, "unsigned long long")) break :blk "u64";
        if (eql(idl_type, "octet") or eql(idl_type, "byte")) break :blk "u8";
        if (eql(idl_type, "double") or
            eql(idl_type, "float") or
            eql(idl_type, "DOMHighResTimeStamp") or
            eql(idl_type, "CSSNumberish")) break :blk "f64";
        if (eql(idl_type, "DOMString") or
            eql(idl_type, "USVString") or
            eql(idl_type, "CSSOMString")) break :blk "[]const u8";
        // EventTarget gets a common-fields sub-struct (see EventTarget decl below)
        if (eql(idl_type, "EventTarget") or
            eql(idl_type, "Element") or
            eql(idl_type, "HTMLElement") or
            eql(idl_type, "Node")) break :blk "EventTarget";
        // Anything else (exotic interface, union, array, promise, …) is skipped
        return null;
    };

    if (nullable) {
        const buf = std.heap.page_allocator.alloc(u8, inner.len + 1) catch return null;
        buf[0] = '?';
        @memcpy(buf[1..], inner);
        return buf;
    }
    return inner;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isZigKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "addrspace", "align",  "allowzero",   "and",            "anyframe", "anytype",
        "asm",       "async",  "await",       "break",          "callconv", "catch",
        "comptime",  "const",  "continue",    "defer",          "else",     "enum",
        "errdefer",  "error",  "export",      "extern",         "fn",       "for",
        "if",        "inline", "linksection", "noalias",        "noinline", "nosuspend",
        "opaque",    "or",     "orelse",      "packed",         "pub",      "resume",
        "return",    "struct", "suspend",     "switch",         "test",     "threadlocal",
        "try",       "union",  "unreachable", "usingnamespace", "var",      "volatile",
        "while",
    };
    for (keywords) |keyword| {
        if (eql(name, keyword)) return true;
    }
    return false;
}

fn zigIdent(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (isValidIdent(name) and !isZigKeyword(name)) return name;
    return try allocator.print("@\"{s}\"", .{name});
}

// Converts a camelCase WebIDL identifier to snake_case for Zig field naming.
// Runs of uppercase letters are treated as acronyms, so `blockedURI` → `blocked_uri`
// and `newURL` → `new_url`. The original camelCase is preserved separately as the
// JS property name to read from the underlying DOM event object.
fn camelToSnake(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (name, 0..) |c, i| {
        const is_upper = c >= 'A' and c <= 'Z';
        if (is_upper and i > 0) {
            const prev = name[i - 1];
            const prev_is_lower = prev >= 'a' and prev <= 'z';
            const next_is_lower = (i + 1 < name.len) and name[i + 1] >= 'a' and name[i + 1] <= 'z';
            const prev_is_upper = prev >= 'A' and prev <= 'Z';
            if (prev_is_lower or (prev_is_upper and next_is_lower)) {
                try out.append(allocator, '_');
            }
        }
        if (is_upper) {
            try out.append(allocator, c - 'A' + 'a');
        } else {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

// A parsed interface: flat list of (name, zig_type) after resolving inheritance.
const Interface = struct {
    name: []const u8,
    fields: std.ArrayListUnmanaged(Field),
    href: []const u8 = "",

    const Field = struct {
        name: []const u8,
        js_name: []const u8,
        zig_type: []const u8,
    };
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const source = try generate(io, allocator);
    defer allocator.free(source);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "src/runtime/client/events/generated.zig",
        .data = source,
    });
    std.debug.print("Generated src/runtime/client/events/generated.zig\n", .{});
}

pub fn generate(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // -------------------------------------------------------------------------
    // Step 1: build a global name->members map by scanning all idlparsed specs.
    // Key: interface name, Value: array of raw member JSON objects.
    // -------------------------------------------------------------------------
    var raw_members = std.StringHashMap(
        std.ArrayListUnmanaged(std.json.Value),
    ).init(a);
    var raw_inheritance = std.StringHashMap([]const u8).init(a);

    var spec_dir = try std.Io.Dir.cwd().openDir(io, "vendor/webref/ed/idlparsed", .{ .iterate = true });
    defer spec_dir.close(io);
    var it = spec_dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const content = try spec_dir.readFileAlloc(io, entry.name, a, .unlimited);
        const parsed = std.json.parseFromSlice(std.json.Value, a, content, .{}) catch continue;
        const idlp = parsed.value.object.get("idlparsed") orelse continue;
        const idl_names = (idlp.object.get("idlNames") orelse continue).object;

        for (idl_names.keys(), idl_names.values()) |name, def| {
            const def_type = (def.object.get("type") orelse continue).string;
            if (!eql(def_type, "interface")) continue;
            if (!std.mem.endsWith(u8, name, "Event")) continue;
            if (std.mem.indexOf(u8, name, "Init") != null) continue;

            // Record inheritance
            if (def.object.get("inheritance")) |inh| {
                if (inh != .null and inh != .string) {} else if (inh == .string) {
                    try raw_inheritance.put(name, inh.string);
                }
            }

            const members_json = (def.object.get("members") orelse continue).array;
            const entry2 = try raw_members.getOrPut(name);
            if (!entry2.found_existing) {
                entry2.value_ptr.* = .empty;
            }
            for (members_json.items) |m| {
                const mtype = (m.object.get("type") orelse continue).string;
                if (!eql(mtype, "attribute")) continue;
                try entry2.value_ptr.append(a, m);
            }
        }

        // Also handle idlExtendedNames (partials)
        const idl_ext = (idlp.object.get("idlExtendedNames") orelse continue).object;
        for (idl_ext.keys(), idl_ext.values()) |name, partials| {
            if (!std.mem.endsWith(u8, name, "Event")) continue;
            if (std.mem.indexOf(u8, name, "Init") != null) continue;
            for (partials.array.items) |partial| {
                const members_json = (partial.object.get("members") orelse continue).array;
                const entry2 = try raw_members.getOrPut(name);
                if (!entry2.found_existing) {
                    entry2.value_ptr.* = .empty;
                }
                for (members_json.items) |m| {
                    const mtype = (m.object.get("type") orelse continue).string;
                    if (!eql(mtype, "attribute")) continue;
                    try entry2.value_ptr.append(a, m);
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Step 2: flatten inheritance chains into resolved Interface structs.
    // -------------------------------------------------------------------------
    var interfaces = std.StringHashMap(Interface).init(a);

    var key_it = raw_members.keyIterator();
    while (key_it.next()) |key| {
        const name = key.*;
        if (interfaces.contains(name)) continue;
        try resolveInterface(name, a, &raw_members, &raw_inheritance, &interfaces);
    }

    // -------------------------------------------------------------------------
    // Step 3: load events.json → event-name to interface map
    // -------------------------------------------------------------------------
    const events_content = try std.Io.Dir.cwd().readFileAlloc(io, "vendor/webref/ed/events.json", a, .unlimited);
    const events_parsed = try std.json.parseFromSlice(std.json.Value, a, events_content, .{});
    const events_array = events_parsed.value.array;

    // Deduplicate: one canonical event name -> interface name
    var event_map = std.StringHashMap([]const u8).init(a);
    for (events_array.items) |ev| {
        const ev_type = (ev.object.get("type") orelse continue).string;
        const iface = (ev.object.get("interface") orelse continue).string;
        if (!event_map.contains(ev_type)) {
            try event_map.put(ev_type, iface);
        }
    }

    const interface_overrides = [_]struct { ev: []const u8, iface: []const u8 }{
        .{ .ev = "click", .iface = "PointerEvent" },
        .{ .ev = "auxclick", .iface = "PointerEvent" },
        .{ .ev = "contextmenu", .iface = "PointerEvent" },
        .{ .ev = "dblclick", .iface = "MouseEvent" },
        .{ .ev = "focus", .iface = "FocusEvent" },
        .{ .ev = "blur", .iface = "FocusEvent" },
    };
    for (interface_overrides) |o| {
        if (interfaces.get(o.iface)) |iface| {
            if (iface.fields.items.len > 0) {
                try event_map.put(o.ev, o.iface);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Step 4: emit Zig source via astgen
    // -------------------------------------------------------------------------
    var file = astgen.File.init(allocator);
    defer file.deinit();

    try file.addRaw(
        \\//! Generated by tools/codegen/events.zig - do not edit manually.
        \\//! Run `zig build eventsgen` to regenerate.
        \\//!
        \\//! Provides typed Zig structs for all browser DOM events.
        \\//! Use with `event.as(events.MouseEvent, allocator)`.
        \\const std = @import("std");
    );

    // Emit EventTarget helper struct first. Field names are snake_case; the
    // original camelCase DOM property names are resolved via `jsName` below.
    try file.addRaw(
        \\/// Minimal representation of EventTarget/Element for use as a nested field.
        \\/// Contains the most commonly accessed DOM element properties.
        \\pub const EventTarget = struct {
        \\    tag_name: []const u8 = "",
        \\    id: []const u8 = "",
        \\    name: []const u8 = "",
        \\    value: []const u8 = "",
        \\    @"type": []const u8 = "",
        \\    checked: bool = false,
        \\    disabled: bool = false,
        \\};
    );

    // Track snake_case → camelCase for every field whose names differ, so that
    // `Event.as(T, …)` can translate Zig field names back to the JS property
    // name when reading from the native DOM event object.
    var js_name_pairs = std.StringHashMap([]const u8).init(a);
    try js_name_pairs.put("tag_name", "tagName");

    // Emit each interface struct
    var iface_it = interfaces.iterator();
    while (iface_it.next()) |iface_entry| {
        const iface = iface_entry.value_ptr.*;
        if (iface.fields.items.len == 0) continue;
        const container = try file.addStruct(iface.name);
        for (iface.fields.items) |field| {
            // For string types we need a default of "" so zero-init works
            const default: ?[]const u8 = blk: {
                if (eql(field.zig_type, "[]const u8")) break :blk "\"\"";
                if (eql(field.zig_type, "bool")) break :blk "false";
                if (std.mem.startsWith(u8, field.zig_type, "?")) break :blk "null";
                if (eql(field.zig_type, "EventTarget")) break :blk ".{}";
                break :blk "0";
            };
            try container.addField(file.arena.allocator(), "", try zigIdent(file.arena.allocator(), field.name), field.zig_type, default);
            if (!eql(field.name, field.js_name)) {
                _ = try js_name_pairs.getOrPutValue(field.name, field.js_name);
            }
        }
    }

    // Collect (event_name, iface_name) pairs that have a backing struct so we can
    // emit the aliases, the `Kind` enum, and the `Data` switch in one pass.
    const Pair = struct { ev: []const u8, iface: []const u8 };
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    var ev_it = event_map.iterator();
    while (ev_it.next()) |entry| {
        const ev_name = entry.key_ptr.*;
        const iface_name = entry.value_ptr.*;
        if (!interfaces.contains(iface_name)) continue;
        if (interfaces.get(iface_name).?.fields.items.len == 0) continue;
        try pairs.append(a, .{ .ev = ev_name, .iface = iface_name });
    }

    // Emit event name -> struct alias namespace
    var aliases: std.Io.Writer.Allocating = .init(a);
    const w = &aliases.writer;
    try w.writeAll("/// Maps browser event names to their typed structs.\n");
    try w.writeAll("/// Example: `event.as(events.click, allocator)` or `event.as(events.MouseEvent, allocator)`.\n");
    try w.writeAll("pub const events = struct {\n");
    for (pairs.items) |p| {
        const safe = isValidIdent(p.ev) and !isZigKeyword(p.ev);
        if (safe) {
            try w.print("    pub const {s} = {s};\n", .{ p.ev, p.iface });
        } else {
            try w.print("    pub const @\"{s}\" = {s};\n", .{ p.ev, p.iface });
        }
    }
    try w.writeAll("};\n\n");

    // Emit an explicit `Kind` enum. This is what gives editors like ZLS proper
    // dot-completion on `event.data(.…)` - an enum derived via
    // `std.meta.DeclEnum` at comptime does not currently surface its tags to
    // the language server, so we declare the tags literally.
    try w.writeAll("/// Enum of all supported DOM event names. Use with `event.data(.kind, …)`.\n");
    try w.writeAll("pub const Kind = enum {\n");
    for (pairs.items) |p| {
        const safe = isValidIdent(p.ev) and !isZigKeyword(p.ev);
        if (safe) {
            try w.print("    {s},\n", .{p.ev});
        } else {
            try w.print("    @\"{s}\",\n", .{p.ev});
        }
    }
    try w.writeAll("};\n\n");

    // Emit a `Data` function mapping each `Kind` tag to its typed struct.
    // This mirrors `@field(events, @tagName(kind))` but keeps the mapping in
    // one generated place so consumers can `const T = generated.Data(.click);`.
    try w.writeAll("/// Returns the typed struct corresponding to a given event `Kind`.\n");
    try w.writeAll("pub fn Data(comptime kind: Kind) type {\n");
    try w.writeAll("    return switch (kind) {\n");
    for (pairs.items) |p| {
        const safe = isValidIdent(p.ev) and !isZigKeyword(p.ev);
        if (safe) {
            try w.print("        .{s} => {s},\n", .{ p.ev, p.iface });
        } else {
            try w.print("        .@\"{s}\" => {s},\n", .{ p.ev, p.iface });
        }
    }
    try w.writeAll("    };\n");
    try w.writeAll("}\n\n");

    try w.writeAll("/// Resolves an event `type` string to its `Kind`, or null if unknown.\n");
    try w.writeAll("pub fn kindForType(type_str: []const u8) ?Kind {\n");
    try w.writeAll("    return kind_for_type.get(type_str);\n");
    try w.writeAll("}\n");
    try w.writeAll("const kind_for_type = std.StaticStringMap(Kind).initComptime(.{\n");
    for (pairs.items) |p| {
        const safe = isValidIdent(p.ev) and !isZigKeyword(p.ev);
        if (safe) {
            try w.print("    .{{ \"{s}\", .{s} }},\n", .{ p.ev, p.ev });
        } else {
            try w.print("    .{{ \"{s}\", .@\"{s}\" }},\n", .{ p.ev, p.ev });
        }
    }
    try w.writeAll("});\n\n");

    // Emit the snake_case → camelCase map used by `Event.as` at runtime to
    // translate Zig field names back to the original DOM property names.
    try w.writeAll("/// Maps snake_case Zig field names to their camelCase DOM property names.\n");
    try w.writeAll("/// Fields whose snake_case equals the DOM name are omitted; callers should\n");
    try w.writeAll("/// fall back to the original identifier when no mapping is present.\n");
    try w.writeAll("pub const js_field_names = std.StaticStringMap([]const u8).initComptime(.{\n");
    var pair_it = js_name_pairs.iterator();
    // Sort entries for deterministic output.
    var sorted_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    while (pair_it.next()) |e| try sorted_keys.append(a, e.key_ptr.*);
    std.mem.sort([]const u8, sorted_keys.items, {}, struct {
        fn lt(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lt);
    for (sorted_keys.items) |k| {
        const v = js_name_pairs.get(k).?;
        try w.print("    .{{ \"{s}\", \"{s}\" }},\n", .{ k, v });
    }
    try w.writeAll("});\n\n");
    try w.writeAll("/// Resolves the DOM property name for a given Zig field name.\n");
    try w.writeAll("/// Returns the mapped camelCase identifier, or the input unchanged when none exists.\n");
    try w.writeAll("pub fn jsName(name: []const u8) []const u8 {\n");
    try w.writeAll("    return js_field_names.get(name) orelse name;\n");
    try w.writeAll("}");

    try file.addRaw(aliases.written());

    return try file.finish();
}

fn isValidIdent(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            c == '_' or
            (i > 0 and c >= '0' and c <= '9');
        if (!ok) return false;
    }
    return true;
}

fn resolveInterface(
    name: []const u8,
    a: std.mem.Allocator,
    raw_members: *std.StringHashMap(std.ArrayListUnmanaged(std.json.Value)),
    raw_inheritance: *std.StringHashMap([]const u8),
    out: *std.StringHashMap(Interface),
) !void {
    if (out.contains(name)) return;

    var fields: std.ArrayListUnmanaged(Interface.Field) = .empty;
    var seen_names = std.StringHashMap(void).init(a);

    // Walk inheritance chain depth-first: child fields first, then parent
    var current: ?[]const u8 = name;
    while (current) |iname| {
        if (raw_members.get(iname)) |members| {
            for (members.items) |m| {
                const field_name = (m.object.get("name") orelse continue).string;
                if (seen_names.contains(field_name)) continue;

                const idt = m.object.get("idlType") orelse continue;
                const generic = (idt.object.get("generic") orelse continue).string;
                // Skip arrays/promises/sequences
                if (generic.len > 0) continue;
                const is_union = (idt.object.get("union") orelse continue).bool;
                if (is_union) continue;
                const nullable = (idt.object.get("nullable") orelse continue).bool;
                const raw_type = idt.object.get("idlType") orelse continue;
                if (raw_type != .string) continue;

                const zig_type = idlToZig(raw_type.string, nullable) orelse continue;

                try seen_names.put(field_name, {});
                const snake = try camelToSnake(a, field_name);
                try fields.append(a, .{ .name = snake, .js_name = field_name, .zig_type = zig_type });
            }
        }
        current = raw_inheritance.get(iname);
        // Break cycles
        if (current != null and std.mem.eql(u8, current.?, name)) break;
    }

    try out.put(name, .{
        .name = try a.dupe(u8, name),
        .fields = fields,
    });
}
