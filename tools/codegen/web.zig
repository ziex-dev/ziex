//! Generates typed browser bindings from webref WebIDL (`zig build webgen`).
//!
//! Outputs:
//!   src/runtime/client/web/generated.zig  Zig wrappers + `__zx_web` externs
//!   src/runtime/client/web/shims.zig      JS shim per extern, for the per-app glue
const std = @import("std");

// Specs whose interfaces are generated. Types from other specs still resolve,
// but members using them fall back to `js.Value`/`anytype`.
const allowlist = [_][]const u8{
    // DOM, HTML (incl. Canvas 2D, storage, history, workers), events
    "dom",                    "html",                   "uievents",             "pointerevents4",
    "touch-events",           "clipboard-apis",         "selection-api",        "fullscreen",
    "pointerlock-2",          "keyboard-lock",          "html-media-capture",   "input-device-capabilities",
    // Layout, CSS, animation
    "cssom-1",                "cssom-view-1",           "css-typed-om-1",       "css-font-loading-3",
    "css-view-transitions-2", "geometry-1",             "resize-observer-1",    "intersection-observer",
    "web-animations-1",       "web-animations-2",       "scroll-animations-1",  "mediaqueries-5",
    // Graphics, media, audio
    "webgl1",                 "webgl2",                 "webgpu",               "webaudio-1.1",
    "mediacapture-streams",   "mediastream-recording",  "media-source-2",       "mediasession",
    "image-capture",          "webcodecs",              "webrtc",               "speech-api",
    // Data, network, storage
    "fetch",                  "xhr",                    "url",                  "encoding",
    "compression",            "streams",                "FileAPI",              "fs",
    "file-system-access",     "entries-api",            "IndexedDB-3",          "storage",
    "websockets",             "beacon",                 "webcrypto-2",          "web-locks",
    "service-workers",        "push-api",               "notifications",        "permissions",
    // Device and platform
    "geolocation",            "screen-orientation",     "screen-wake-lock",     "vibration",
    "gamepad",                "battery-status",         "web-share",            "eyedropper-api",
    "webusb",                 "webhid",                 "serial",               "web-bluetooth",
    "webxr",                  "credential-management-1", "webauthn-3",          "payment-request",
    // Timing and scheduling
    "hr-time-3",              "performance-timeline",   "user-timing",          "navigation-timing-2",
    "resource-timing",        "paint-timing",           "event-timing",         "largest-contentful-paint",
    "longtasks-1",            "requestidlecallback",    "scheduling-apis",      "console",
    "webidl",                 "trusted-types",
};

const out_zig = "src/runtime/client/web/generated.zig";
const out_shims = "src/runtime/client/web/shims.zig";
const out_smoke = "test/core/web_smoke.zig";
const out_events = "src/runtime/client/event_type.zig";

// Delegated template events that existed before generation; ids stay stable.
const legacy_events = [_][]const u8{
    "click",       "dblclick",     "input",       "change",      "submit",        "focus",
    "blur",        "keydown",      "keyup",       "keypress",    "mouseenter",    "mouseleave",
    "mousedown",   "mouseup",      "mousemove",   "touchstart",  "touchend",      "touchmove",
    "scroll",      "wheel",        "pointerdown", "pointermove", "pointerup",     "pointercancel",
    "pointerenter", "pointerleave", "lostpointercapture",
};
const high_freq_events = [_][]const u8{
    "mousemove", "pointermove", "pointerrawupdate", "touchmove", "wheel", "scroll", "drag",
    "dragover",  "mouseover",   "mouseout",         "pointerover", "pointerout", "timeupdate",
};
const passive_events = [_][]const u8{ "touchstart", "touchmove", "touchend", "touchcancel", "scroll", "scrollend" };

const Json = std.json.Value;

const Def = struct {
    kind: []const u8,
    json: Json,
    allowed: bool,
};

const Kind = enum { void, bool, num, string, iface, @"enum", callback, any, promise, bytes };

const Ty = struct {
    kind: Kind,
    nullable: bool = false,
    // Zig numeric type for `.num`; JS constructor for `.bytes`;
    // interface/enum name otherwise ("" = generic handle).
    name: []const u8 = "",
};

const Source = struct {
    // Interface or mixin that declares the member; names the extern.
    decl: []const u8,
    m: Json,
};

const Gen = struct {
    a: std.mem.Allocator,
    defs: std.StringHashMap(Def),
    partials: std.StringHashMap(std.ArrayListUnmanaged(Json)),
    includes: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
    // "Decl.name" (static prefixed "static ") -> overloads in declaration order.
    overloads: std.StringHashMap(std.ArrayListUnmanaged(Json)),
    generated: std.StringHashMap(void),
    used_enums: std.StringHashMap(void),
    externs: std.StringHashMap(Extern),
    file_decls: std.StringHashMap(void),
    // `impl_<Decl>` bodies: one wrapper per member, aliased by every interface that has it.
    impls: std.StringHashMap(std.Io.Writer.Allocating),
    // One call per wrapper for the native smoke test.
    smoke: std.ArrayListUnmanaged([]const u8) = .empty,
    decl_names: std.StringHashMap(std.StringHashMap(void)),
    failed: std.StringHashMap(void),

    const Extern = struct { params: []const u8, ret: []const u8, shim: []const u8 };

    fn def(self: *Gen, name: []const u8) ?Def {
        return self.defs.get(name);
    }

    // ---------------------------------------------------------------- types

    fn resolve(self: *Gen, t: Json, depth: u8) Ty {
        if (depth > 8) return .{ .kind = .any };
        const o = t.object;
        const nullable = boolField(o, "nullable");
        const generic = strField(o, "generic");
        if (generic.len > 0) {
            if (eql(generic, "Promise")) return .{ .kind = .promise, .nullable = nullable };
            return .{ .kind = .any, .nullable = nullable };
        }
        const inner = o.get("idlType").?;
        if (boolField(o, "union")) {
            // All-interface unions (e.g. CanvasImageSource) pass as a handle;
            // buffer unions (BufferSource, Float32List) as a memory view.
            var all_iface = true;
            var bytes: ?[]const u8 = null;
            var others = false;
            for (inner.array.items) |member| {
                const r = self.resolve(member, depth + 1);
                switch (r.kind) {
                    .iface => {},
                    .bytes => bytes = bytes orelse r.name,
                    .any => {
                        all_iface = false;
                        // `sequence<GLfloat>` beside a typed array is the same data.
                        if (strField(member.object, "generic").len == 0) others = true;
                    },
                    else => {
                        all_iface = false;
                        others = true;
                    },
                }
                if (r.kind != .iface and r.kind != .bytes) all_iface = false;
            }
            if (bytes) |ctor| if (!others) return .{ .kind = .bytes, .nullable = nullable, .name = ctor };
            if (all_iface and bytes == null) return .{ .kind = .iface, .nullable = nullable };
            return .{ .kind = .any, .nullable = nullable };
        }
        var r = self.named(inner.string, depth);
        r.nullable = r.nullable or nullable;
        return r;
    }

    fn named(self: *Gen, n: []const u8, depth: u8) Ty {
        const prims = [_]struct { []const u8, Kind, []const u8 }{
            .{ "undefined", .void, "" },      .{ "void", .void, "" },
            .{ "boolean", .bool, "" },        .{ "byte", .num, "i8" },
            .{ "octet", .num, "u8" },         .{ "short", .num, "i16" },
            .{ "unsigned short", .num, "u16" }, .{ "long", .num, "i32" },
            .{ "unsigned long", .num, "u32" }, .{ "long long", .num, "f64" },
            .{ "unsigned long long", .num, "f64" }, .{ "float", .num, "f32" },
            .{ "unrestricted float", .num, "f32" }, .{ "double", .num, "f64" },
            .{ "unrestricted double", .num, "f64" }, .{ "DOMString", .string, "" },
            .{ "USVString", .string, "" },    .{ "ByteString", .string, "" },
            .{ "CSSOMString", .string, "" },
        };
        for (prims) |p| if (eql(n, p[0])) return .{ .kind = p[1], .name = p[2] };
        const views = [_][]const u8{
            "Int8Array",    "Uint8Array",    "Uint8ClampedArray", "Int16Array",   "Uint16Array",
            "Int32Array",   "Uint32Array",   "Float16Array",      "Float32Array", "Float64Array",
            "BigInt64Array", "BigUint64Array", "DataView",        "ArrayBuffer",  "SharedArrayBuffer",
        };
        for (views) |v| if (eql(n, v)) return .{ .kind = .bytes, .name = if (eql(v, "SharedArrayBuffer")) "ArrayBuffer" else v };

        const d = self.def(n) orelse return .{ .kind = .any };
        if (eql(d.kind, "typedef")) return self.resolve(d.json.object.get("idlType").?, depth + 1);
        if (eql(d.kind, "enum")) return .{ .kind = .@"enum", .name = n };
        if (eql(d.kind, "callback") or eql(d.kind, "callback interface")) return .{ .kind = .callback };
        if (eql(d.kind, "interface")) return .{ .kind = .iface, .name = if (self.generated.contains(n)) n else "" };
        return .{ .kind = .any };
    }

    // ------------------------------------------------------------ members

    fn ownSources(self: *Gen, name: []const u8, out: *std.ArrayListUnmanaged(Source)) !void {
        const d = self.def(name) orelse return;
        try self.appendMembers(name, d.json, out);
        if (self.partials.get(name)) |ps| for (ps.items) |p| try self.appendMembers(name, p, out);
        if (self.includes.get(name)) |mixins| for (mixins.items) |mixin| {
            const md = self.def(mixin) orelse continue;
            if (!md.allowed) continue;
            try self.appendMembers(mixin, md.json, out);
            if (self.partials.get(mixin)) |ps| for (ps.items) |p| try self.appendMembers(mixin, p, out);
        };
    }

    fn appendMembers(self: *Gen, decl: []const u8, j: Json, out: *std.ArrayListUnmanaged(Source)) !void {
        const members = (j.object.get("members") orelse return).array;
        for (members.items) |m| {
            if (!exposedOnWindow(m)) continue;
            try out.append(self.a, .{ .decl = decl, .m = m });
        }
    }

    fn collectOverloads(self: *Gen) !void {
        var it = self.generated.keyIterator();
        while (it.next()) |k| {
            var srcs: std.ArrayListUnmanaged(Source) = .empty;
            try self.ownSources(k.*, &srcs);
            for (srcs.items) |s| {
                const t = strField(s.m.object, "type");
                const key = if (eql(t, "constructor"))
                    try self.a.print("{s}.new", .{s.decl})
                else if (eql(t, "operation"))
                    try self.a.print("{s}{s}.{s}", .{ if (isStatic(s.m)) "static " else "", s.decl, strField(s.m.object, "name") })
                else
                    continue;
                const gop = try self.overloads.getOrPut(key);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                // Mixins are included by several interfaces; keep one copy.
                for (gop.value_ptr.items) |prev| {
                    if (prev.object.get("href") != null and s.m.object.get("href") != null and
                        eql(strField(prev.object, "href"), strField(s.m.object, "href")) and
                        argCount(prev) == argCount(s.m)) break;
                } else try gop.value_ptr.append(self.a, s.m);
            }
        }
    }

    // ------------------------------------------------------------ emission

    const Member = struct {
        zig: []const u8,
        decl: []const u8,
        m: Json,
        role: enum { op, getter, setter, ctor, constant },
        static: bool,
        extern_name: []const u8,
    };

    fn flatten(self: *Gen, iface: []const u8, out: *std.ArrayListUnmanaged(Member), taken: *std.StringHashMap(void)) !void {
        var cur: ?[]const u8 = iface;
        var guard: u8 = 0;
        while (cur) |name| : (guard += 1) {
            if (guard > 32) break;
            const d = self.def(name) orelse break;
            if (!self.generated.contains(name)) break;
            var srcs: std.ArrayListUnmanaged(Source) = .empty;
            try self.ownSources(name, &srcs);
            for (srcs.items) |s| try self.addMember(s, name, out, taken);
            const inh = d.json.object.get("inheritance") orelse break;
            cur = if (inh == .string) inh.string else null;
        }
    }

    fn addMember(self: *Gen, s: Source, owner: []const u8, out: *std.ArrayListUnmanaged(Member), taken: *std.StringHashMap(void)) !void {
        const o = s.m.object;
        const t = strField(o, "type");
        const static = isStatic(s.m);
        if (eql(t, "const")) {
            const n = strField(o, "name");
            if (taken.contains(n)) return;
            try taken.put(n, {});
            try out.append(self.a, .{ .zig = n, .decl = s.decl, .m = s.m, .role = .constant, .static = true, .extern_name = "" });
        } else if (eql(t, "constructor")) {
            // Constructors are not inherited.
            if (!eql(s.decl, owner) or hasExtAttr(s.m, "HTMLConstructor")) return;
            const key = try self.a.print("{s}.new", .{s.decl});
            const group = self.overloads.get(key) orelse return;
            const idx = indexOf(group.items, s.m) orelse return;
            const zig = try self.overloadName(group.items, idx, "new");
            const ext = if (idx == 0) key else try self.a.print("{s}#{d}", .{ key, idx });
            try self.claim(out, taken, .{ .zig = zig, .decl = s.decl, .m = s.m, .role = .ctor, .static = true, .extern_name = ext });
        } else if (eql(t, "operation")) {
            const n = strField(o, "name");
            if (n.len == 0) return;
            const sp = strField(o, "special");
            if (sp.len > 0 and !eql(sp, "static") and !eql(sp, "getter") and !eql(sp, "setter") and !eql(sp, "deleter")) return;
            const key = try self.a.print("{s}{s}.{s}", .{ if (static) "static " else "", s.decl, n });
            const group = self.overloads.get(key) orelse return;
            const idx = indexOf(group.items, s.m) orelse return;
            const zig = try self.overloadName(group.items, idx, n);
            const base = try self.a.print("{s}.{s}", .{ s.decl, n });
            const ext = if (idx == 0) base else try self.a.print("{s}#{d}", .{ base, idx });
            try self.claim(out, taken, .{ .zig = zig, .decl = s.decl, .m = s.m, .role = .op, .static = static, .extern_name = ext });
        } else if (eql(t, "attribute")) {
            // `on*` handlers: use addEventListener / template handlers instead.
            if (isEventHandler(s.m)) return;
            const n = strField(o, "name");
            const ext = try self.a.print("{s}.{s}", .{ s.decl, n });
            try self.claim(out, taken, .{ .zig = n, .decl = s.decl, .m = s.m, .role = .getter, .static = static, .extern_name = ext });
            const readonly = boolField(o, "readonly");
            if (!readonly) {
                const setter = try self.a.print("set{c}{s}", .{ std.ascii.toUpper(n[0]), n[1..] });
                try self.claim(out, taken, .{ .zig = setter, .decl = s.decl, .m = s.m, .role = .setter, .static = static, .extern_name = try self.a.print("{s}=", .{ext}) });
            }
        }
    }

    // Child members shadow inherited ones with the same Zig name.
    fn claim(self: *Gen, out: *std.ArrayListUnmanaged(Member), taken: *std.StringHashMap(void), m: Member) !void {
        var mm = m;
        if (isReserved(mm.zig)) mm.zig = try self.a.print("{s}_", .{mm.zig});
        if (taken.contains(mm.zig)) {
            // Same member reached twice (diamond mixins): keep the first.
            for (out.items) |prev| if (eql(prev.extern_name, mm.extern_name)) return;
            // A getter colliding with an operation of the same name.
            if (mm.role == .getter) {
                mm.zig = try self.a.print("get{c}{s}", .{ std.ascii.toUpper(mm.zig[0]), mm.zig[1..] });
                if (taken.contains(mm.zig)) return;
            } else return;
        }
        try taken.put(mm.zig, {});
        try out.append(self.a, mm);
    }

    fn overloadName(self: *Gen, group: []const Json, idx: usize, base: []const u8) ![]const u8 {
        if (idx == 0) return base;
        const arity = argCount(group[idx]);
        var same: usize = 0;
        for (group) |g| if (argCount(g) == arity) {
            same += 1;
        };
        if (same == 1) return self.a.print("{s}{d}", .{ base, arity });
        return self.a.print("{s}_{d}", .{ base, idx });
    }

    fn emitInterface(self: *Gen, w: *std.Io.Writer, name: []const u8, namespace: bool) !void {
        var members: std.ArrayListUnmanaged(Member) = .empty;
        var taken = std.StringHashMap(void).init(self.a);
        for ([_][]const u8{ "h", "deinit", "as", "object" }) |r| try taken.put(r, {});
        try self.flatten(name, &members, &taken);

        const d = self.def(name).?;
        try w.print("\n/// {s}\n", .{strField(d.json.object, "href")});
        try w.print("pub const {f} = struct {{\n", .{ident(name)});
        if (!namespace) {
            try w.print(
                \\    h: js.Value,
                \\
                \\    pub fn deinit(this: {0f}) void {{
                \\        this.h.deinit();
                \\    }}
                \\
                \\    /// Unchecked cast to another interface.
                \\    pub fn as(this: {0f}, comptime T: type) T {{
                \\        return .{{ .h = this.h }};
                \\    }}
                \\
                \\    /// Dynamic access for members not covered here.
                \\    pub fn object(this: {0f}) js.Object {{
                \\        return .{{ .value = this.h }};
                \\    }}
                \\
                \\    /// Inside a dictionary argument, stands for this object.
                \\    pub fn jsonStringify(this: {0f}, jw: anytype) !void {{
                \\        try this.h.jsonStringify(jw);
                \\    }}
                \\
            , .{ident(name)});
        }

        for (members.items) |m| {
            switch (m.role) {
                .constant => try self.emitConst(w, m),
                else => {
                    if (!try self.ensureImpl(m)) continue;
                    const rest = m.extern_name[m.decl.len + 1 ..];
                    try w.print("    pub const {f} = impl_{s}.{f};\n", .{ ident(m.zig), m.decl, ident(rest) });
                },
            }
        }
        try w.writeAll("};\n");
    }

    // Emits the member's wrapper into `impl_<Decl>` once; false if unsupported.
    fn ensureImpl(self: *Gen, m: Member) !bool {
        if (self.externs.contains(m.extern_name)) return true;
        if (self.failed.contains(m.extern_name)) return false;
        const gop = try self.impls.getOrPut(m.decl);
        if (!gop.found_existing) gop.value_ptr.* = .init(self.a);
        const names = try self.declNames(m.decl);
        self.emitMember(&gop.value_ptr.writer, m, names) catch |err| switch (err) {
            error.Unsupported => {
                try self.failed.put(m.extern_name, {});
                return false;
            },
            else => return err,
        };
        return true;
    }

    // Decl names in `impl_<Decl>`, which params must not shadow.
    fn declNames(self: *Gen, decl: []const u8) !*const std.StringHashMap(void) {
        const gop = try self.decl_names.getOrPut(decl);
        if (gop.found_existing) return gop.value_ptr;
        gop.value_ptr.* = .init(self.a);
        var srcs: std.ArrayListUnmanaged(Source) = .empty;
        const d = self.def(decl) orelse return gop.value_ptr;
        try self.appendMembers(decl, d.json, &srcs);
        if (self.partials.get(decl)) |ps| for (ps.items) |p| try self.appendMembers(decl, p, &srcs);
        for (srcs.items) |src| {
            const n = strField(src.m.object, "name");
            if (n.len > 0) try gop.value_ptr.put(n, {});
        }
        try gop.value_ptr.put("new", {});
        return gop.value_ptr;
    }

    fn emitConst(self: *Gen, w: *std.Io.Writer, m: Member) !void {
        const o = m.m.object;
        const ty = self.resolve(o.get("idlType").?, 0);
        const v = o.get("value").?.object;
        const val = v.get("value") orelse return;
        const zig_ty = switch (ty.kind) {
            .num => ty.name,
            .bool => "bool",
            else => return,
        };
        const text = switch (val) {
            .string => |s| s,
            .bool => |b| if (b) "true" else "false",
            else => return,
        };
        // IDL hex/negative literals are valid Zig; floats like `Infinity` are not.
        if (std.mem.indexOfAny(u8, text, "IN") != null) return;
        try w.print("    pub const {f}: {s} = {s};\n", .{ ident(m.zig), zig_ty, text });
    }

    const Parts = struct {
        zparams: std.ArrayListUnmanaged(u8) = .empty,
        prelude: std.ArrayListUnmanaged(u8) = .empty,
        cargs: std.ArrayListUnmanaged(u8) = .empty,
        eparams: std.ArrayListUnmanaged(u8) = .empty,
        sparams: std.ArrayListUnmanaged(u8) = .empty,
        sargs: std.ArrayListUnmanaged(u8) = .empty,
        smoke: std.ArrayListUnmanaged(u8) = .empty,
        temps: bool = false,
        n: usize = 0,

        fn sep(list: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator) !void {
            if (list.items.len > 0) try list.appendSlice(a, ", ");
        }

        // JS is shipped, so keep it compact.
        fn sepJs(list: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator) !void {
            if (list.items.len > 0) try list.append(a, ',');
        }
    };

    fn emitMember(self: *Gen, w: *std.Io.Writer, m: Member, members: *const std.StringHashMap(void)) !void {
        const a = self.a;
        const o = m.m.object;
        const iface = m.decl;
        const namespace = eql(self.def(iface).?.kind, "namespace");
        const has_self = !m.static and !namespace;
        var p: Parts = .{};

        if (has_self) {
            try p.cargs.appendSlice(a, "@backingInt(this.h)");
            try p.eparams.appendSlice(a, "u32");
            try p.sparams.appendSlice(a, "h");
        }

        // Return type.
        const ret: Ty = switch (m.role) {
            .getter => self.resolve(o.get("idlType").?, 0),
            .op => self.resolve(o.get("idlType").?, 0),
            .ctor => .{ .kind = .iface, .name = if (self.generated.contains(iface)) iface else "" },
            .setter => .{ .kind = .void },
            .constant => unreachable,
        };

        // Arguments.
        const scope: Scope = .{ .files = &self.file_decls, .members = members };
        switch (m.role) {
            .op, .ctor => for (o.get("arguments").?.array.items) |arg| {
                const ao = arg.object;
                try self.addArg(&p, .{
                    .name = strField(ao, "name"),
                    .ty = ao.get("idlType").?,
                    .optional = boolField(ao, "optional"),
                    .variadic = boolField(ao, "variadic"),
                }, scope);
            },
            .setter => try self.addArg(&p, .{ .name = "value", .ty = o.get("idlType").? }, scope),
            else => {},
        }

        // Receiver + JS expression.
        const js_name = strField(o, "name");
        const recv = if (has_self) "R[h]" else jsGlobal(iface);
        const expr = switch (m.role) {
            .getter => try a.print("{s}.{s}", .{ recv, js_name }),
            .setter => try a.print("{s}.{s}={s}", .{ recv, js_name, p.sargs.items }),
            .op => try a.print("{s}.{s}({s})", .{ recv, js_name, p.sargs.items }),
            .ctor => try a.print("new {s}({s})", .{ iface, p.sargs.items }),
            .constant => unreachable,
        };

        // Zig return type, extern return type, and how the result is converted.
        var zret: []const u8 = undefined;
        var eret: []const u8 = undefined;
        var body: []const u8 = undefined;
        var alloc_param = false;
        switch (ret.kind) {
            .void => {
                zret = "void";
                eret = "void";
                body = try a.print("{{{s}}}", .{expr});
            },
            .bool, .num => if (ret.nullable) {
                zret = "js.Value";
                eret = "u32";
                body = try a.print("H({s})", .{expr});
            } else {
                zret = if (ret.kind == .bool) "bool" else ret.name;
                eret = zret;
                body = expr;
            },
            .string => {
                alloc_param = true;
                zret = if (ret.nullable) "!?[]u8" else "![]u8";
                eret = "void";
                try Parts.sep(&p.eparams, a);
                try p.eparams.appendSlice(a, "*rt.Str");
                try Parts.sepJs(&p.sparams, a);
                try p.sparams.appendSlice(a, "o");
                body = try a.print("W({s},o)", .{expr});
            },
            .@"enum" => {
                try self.used_enums.put(ret.name, {});
                zret = try a.print("{s}{f}", .{ if (ret.nullable) "?" else "", ident(ret.name) });
                eret = "i32";
                body = try a.print("E_{s}.indexOf({s})", .{ ret.name, expr });
            },
            .iface => {
                const t = if (ret.name.len > 0) try a.print("{f}", .{ident(ret.name)}) else "js.Value";
                zret = if (ret.nullable and ret.name.len > 0) try a.print("?{s}", .{t}) else t;
                eret = "u32";
                body = try a.print("H({s})", .{expr});
            },
            .promise => {
                zret = "rt.Promise";
                eret = "u32";
                body = try a.print("H({s})", .{expr});
            },
            .any, .callback, .bytes => {
                zret = "js.Value";
                eret = "u32";
                body = try a.print("H({s})", .{expr});
            },
        }

        // Signature.
        try w.writeAll("\n");
        try w.print("    pub fn {f}(", .{ident(m.extern_name[m.decl.len + 1 ..])});
        var first = true;
        if (has_self) {
            try w.writeAll("this: anytype");
            first = false;
        }
        if (alloc_param) {
            if (!first) try w.writeAll(", ");
            try w.writeAll("allocator: std.mem.Allocator");
            first = false;
        }
        if (p.zparams.items.len > 0) {
            if (!first) try w.writeAll(", ");
            try w.writeAll(p.zparams.items);
        }
        try w.print(") {s} {{\n", .{zret});
        try w.writeAll(p.prelude.items);
        if (p.temps) try w.writeAll("        defer js.freeTemps();\n");

        const ename = m.extern_name;
        switch (ret.kind) {
            .void => try w.print("        ext.@\"{s}\"({s});\n", .{ ename, p.cargs.items }),
            .bool, .num => if (ret.nullable) {
                try w.print("        return @fromBackingInt(ext.@\"{s}\"({s}));\n", .{ ename, p.cargs.items });
            } else {
                try w.print("        return ext.@\"{s}\"({s});\n", .{ ename, p.cargs.items });
            },
            .string => {
                try w.writeAll("        var zx_out: rt.Str = .{};\n");
                try Parts.sep(&p.cargs, a);
                try p.cargs.appendSlice(a, "&zx_out");
                try w.print("        ext.@\"{s}\"({s});\n", .{ ename, p.cargs.items });
                try w.print("        return rt.{s}(allocator, zx_out);\n", .{if (ret.nullable) "strOpt" else "str"});
            },
            .@"enum" => try w.print("        return rt.{s}({f}, ext.@\"{s}\"({s}));\n", .{ if (ret.nullable) "enumOpt" else "enumOf", ident(ret.name), ename, p.cargs.items }),
            .iface => if (ret.name.len > 0) {
                try w.print("        return rt.{s}({f}, ext.@\"{s}\"({s}));\n", .{ if (ret.nullable) "wrapOpt" else "wrap", ident(ret.name), ename, p.cargs.items });
            } else {
                try w.print("        return @fromBackingInt(ext.@\"{s}\"({s}));\n", .{ ename, p.cargs.items });
            },
            .promise => try w.print("        return .{{ .h = @fromBackingInt(ext.@\"{s}\"({s})) }};\n", .{ ename, p.cargs.items }),
            .any, .callback, .bytes => try w.print("        return @fromBackingInt(ext.@\"{s}\"({s}));\n", .{ ename, p.cargs.items }),
        }
        try w.writeAll("    }\n");

        var call: std.Io.Writer.Allocating = .init(a);
        try call.writer.print("web.impl_{s}.{f}(", .{ iface, ident(m.extern_name[m.decl.len + 1 ..]) });
        var sfirst = true;
        if (has_self) {
            try call.writer.writeAll("s");
            sfirst = false;
        }
        if (alloc_param) {
            if (!sfirst) try call.writer.writeAll(", ");
            try call.writer.writeAll("gpa");
            sfirst = false;
        }
        if (p.smoke.items.len > 0) {
            if (!sfirst) try call.writer.writeAll(", ");
            try call.writer.writeAll(p.smoke.items);
        }
        try call.writer.writeAll(")");
        try self.smoke.append(a, if (ret.kind == .string and ret.nullable)
            try a.print("    if ({s}) |v| (if (v) |b| gpa.free(b)) else |_| {{}}", .{call.written()})
        else if (ret.kind == .string)
            try a.print("    if ({s}) |v| gpa.free(v) else |_| {{}}", .{call.written()})
        else if (ret.kind == .void)
            try a.print("    {s};", .{call.written()})
        else
            try a.print("    _ = {s};", .{call.written()}));

        const shim = try a.print("({s})=>{s}", .{ p.sparams.items, body });
        try self.externs.put(ename, .{ .params = try a.dupe(u8, p.eparams.items), .ret = eret, .shim = shim });
    }

    const Scope = struct { files: *const std.StringHashMap(void), members: *const std.StringHashMap(void) };

    const Arg = struct { name: []const u8, ty: Json, optional: bool = false, variadic: bool = false };

    fn addArg(self: *Gen, p: *Parts, arg: Arg, scope: Scope) !void {
        const a = self.a;
        const ty = self.resolve(arg.ty, 0);
        if (ty.kind == .void) return error.Unsupported;
        const optional = arg.optional;
        const variadic = arg.variadic;
        const raw_name = arg.name;
        const pname = try self.paramName(raw_name, scope);
        const i = p.n;
        p.n += 1;

        try Parts.sep(&p.zparams, a);
        try Parts.sep(&p.cargs, a);
        try Parts.sep(&p.eparams, a);
        try Parts.sepJs(&p.sparams, a);
        try Parts.sepJs(&p.sargs, a);
        try Parts.sep(&p.smoke, a);
        try p.smoke.appendSlice(a, if (variadic)
            ".{}"
        else if (optional or ty.nullable or ty.kind == .any or ty.kind == .promise)
            "null"
        else switch (ty.kind) {
            .bool => "false",
            .num => "0",
            .string => "\"\"",
            .@"enum" => "@fromBackingInt(0)",
            .iface => "js.Value.null",
            .callback => "js.Callback{ .id = 0 }",
            else => "null",
        });

        // Slices pass as a zero-copy view of wasm memory; null/undefined when absent.
        if (ty.kind == .bytes and !variadic) {
            try p.zparams.appendSlice(a, try a.print("{f}: anytype", .{ident(pname)}));
            try p.prelude.appendSlice(a, try a.print("        const zx_b{d} = rt.buf({f});\n", .{ i, ident(pname) }));
            try p.cargs.appendSlice(a, try a.print("zx_b{d}.ptr, zx_b{d}.len", .{ i, i }));
            try p.eparams.appendSlice(a, "[*]const u8, usize");
            try p.sparams.appendSlice(a, try a.print("p{d},l{d}", .{ i, i }));
            try p.sargs.appendSlice(a, try a.print("T({s},p{d},l{d})", .{ ty.name, i, i }));
            return;
        }

        if (variadic) {
            try p.zparams.appendSlice(a, try a.print("{f}: anytype", .{ident(pname)}));
            try p.prelude.appendSlice(a, try a.print("        const zx_v{d} = js.argsRaw({f});\n", .{ i, ident(pname) }));
            try p.cargs.appendSlice(a, try a.print("&zx_v{d}, zx_v{d}.len", .{ i, i }));
            try p.eparams.appendSlice(a, "[*]const js.Raw, usize");
            try p.sparams.appendSlice(a, try a.print("p{d},n{d}", .{ i, i }));
            try p.sargs.appendSlice(a, try a.print("...A(p{d},n{d})", .{ i, i }));
            p.temps = true;
            return;
        }

        if (optional or ty.kind == .any or ty.kind == .promise or (ty.kind == .@"enum" and ty.nullable) or
            (ty.nullable and (ty.kind == .bool or ty.kind == .num)))
        {
            const zt = try self.optType(ty, optional);
            try p.zparams.appendSlice(a, try a.print("{f}: {s}", .{ ident(pname), zt }));
            const conv = if (optional) "rt.opt" else "js.toRaw";
            try p.prelude.appendSlice(a, try a.print("        const zx_r{d} = {s}({f});\n", .{ i, conv, ident(pname) }));
            try p.cargs.appendSlice(a, try a.print("&zx_r{d}", .{i}));
            try p.eparams.appendSlice(a, "*const js.Raw");
            try p.sparams.appendSlice(a, try a.print("p{d}", .{i}));
            try p.sargs.appendSlice(a, try a.print("V(p{d})", .{i}));
            if (ty.kind == .@"enum") try self.used_enums.put(ty.name, {});
            p.temps = true;
            return;
        }

        switch (ty.kind) {
            .bool => {
                try p.zparams.appendSlice(a, try a.print("{f}: bool", .{ident(pname)}));
                try p.cargs.appendSlice(a, try a.print("{f}", .{ident(pname)}));
                try p.eparams.appendSlice(a, "bool");
                try p.sparams.appendSlice(a, try a.print("p{d}", .{i}));
                try p.sargs.appendSlice(a, try a.print("p{d}", .{i}));
            },
            .num => {
                try p.zparams.appendSlice(a, try a.print("{f}: {s}", .{ ident(pname), ty.name }));
                try p.cargs.appendSlice(a, try a.print("{f}", .{ident(pname)}));
                try p.eparams.appendSlice(a, ty.name);
                try p.sparams.appendSlice(a, try a.print("p{d}", .{i}));
                try p.sargs.appendSlice(a, try a.print("p{d}", .{i}));
            },
            .string => {
                if (ty.nullable) {
                    try p.zparams.appendSlice(a, try a.print("{f}: ?[]const u8", .{ident(pname)}));
                    try p.cargs.appendSlice(a, try a.print("rt.sp({0f}), rt.sl({0f})", .{ident(pname)}));
                    try p.sargs.appendSlice(a, try a.print("N(p{d},l{d})", .{ i, i }));
                } else {
                    try p.zparams.appendSlice(a, try a.print("{f}: []const u8", .{ident(pname)}));
                    try p.cargs.appendSlice(a, try a.print("{0f}.ptr, {0f}.len", .{ident(pname)}));
                    try p.sargs.appendSlice(a, try a.print("S(p{d},l{d})", .{ i, i }));
                }
                try p.eparams.appendSlice(a, "[*]const u8, usize");
                try p.sparams.appendSlice(a, try a.print("p{d},l{d}", .{ i, i }));
            },
            .@"enum" => {
                try self.used_enums.put(ty.name, {});
                try p.zparams.appendSlice(a, try a.print("{f}: {f}", .{ ident(pname), ident(ty.name) }));
                try p.cargs.appendSlice(a, try a.print("@backingInt({f})", .{ident(pname)}));
                try p.eparams.appendSlice(a, "u32");
                try p.sparams.appendSlice(a, try a.print("p{d}", .{i}));
                try p.sargs.appendSlice(a, try a.print("E_{s}[p{d}]", .{ ty.name, i }));
            },
            .iface => {
                try p.zparams.appendSlice(a, try a.print("{f}: anytype", .{ident(pname)}));
                try p.cargs.appendSlice(a, try a.print("rt.h({f})", .{ident(pname)}));
                try p.eparams.appendSlice(a, "u32");
                try p.sparams.appendSlice(a, try a.print("p{d}", .{i}));
                try p.sargs.appendSlice(a, try a.print("R[p{d}]", .{i}));
            },
            .callback => {
                try p.zparams.appendSlice(a, try a.print("{f}: {s}", .{ ident(pname), if (ty.nullable) "?js.Callback" else "js.Callback" }));
                try p.cargs.appendSlice(a, try a.print("rt.cb({f})", .{ident(pname)}));
                try p.eparams.appendSlice(a, "u32");
                try p.sparams.appendSlice(a, try a.print("p{d}", .{i}));
                try p.sargs.appendSlice(a, try a.print("F(p{d})", .{i}));
            },
            .void, .any, .promise, .bytes => unreachable,
        }
    }

    fn optType(self: *Gen, ty: Ty, optional: bool) ![]const u8 {
        const a = self.a;
        _ = optional;
        return switch (ty.kind) {
            .bool => "?bool",
            .num => try a.print("?{s}", .{ty.name}),
            .string => "?[]const u8",
            .@"enum" => try a.print("?{f}", .{ident(ty.name)}),
            .callback => "?js.Callback",
            else => "anytype",
        };
    }

    // Zig forbids params shadowing decls, so clashes get a `_` suffix.
    fn paramName(self: *Gen, n: []const u8, scope: Scope) ![]const u8 {
        if (scope.files.contains(n) or scope.members.contains(n) or eql(n, "this") or eql(n, "allocator") or eql(n, "ext") or eql(n, "rt") or eql(n, "js") or eql(n, "std"))
            return self.a.print("{s}_", .{n});
        return n;
    }

    fn emitEnum(self: *Gen, w: *std.Io.Writer, name: []const u8) !void {
        const d = self.def(name) orelse return;
        const values = d.json.object.get("values").?.array.items;
        try w.print("\npub const {f} = enum(u32) {{\n", .{ident(name)});
        for (values) |v| {
            const s = strField(v.object, "value");
            if (s.len == 0) try w.writeAll("    empty,\n") else try w.print("    {f},\n", .{ident(s)});
        }
        try w.writeAll("    _,\n\n    const strs = [_][]const u8{ ");
        for (values, 0..) |v, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("\"{s}\"", .{strField(v.object, "value")});
        }
        try w.writeAll(" };\n\n    pub fn str(self: @This()) []const u8 {\n        const i = @backingInt(self);\n        return if (i < strs.len) strs[i] else \"\";\n    }\n};\n");
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var g: Gen = .{
        .a = a,
        .defs = .init(a),
        .partials = .init(a),
        .includes = .init(a),
        .overloads = .init(a),
        .generated = .init(a),
        .used_enums = .init(a),
        .externs = .init(a),
        .file_decls = .init(a),
        .impls = .init(a),
        .decl_names = .init(a),
        .failed = .init(a),
    };

    // Load every spec so types from outside the allowlist still resolve.
    var dir = try std.Io.Dir.cwd().openDir(io, "vendor/webref/ed/idlparsed", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| if (std.mem.endsWith(u8, e.name, ".json")) try names.append(a, try a.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, lessStr);

    for (names.items) |file| {
        const spec = file[0 .. file.len - ".json".len];
        const allowed = for (allowlist) |s| {
            if (eql(s, spec)) break true;
        } else false;
        const content = try dir.readFileAlloc(io, file, a, .unlimited);
        const parsed = std.json.parseFromSliceLeaky(Json, a, content, .{}) catch continue;
        const idlp = parsed.object.get("idlparsed") orelse continue;

        const idl_names = idlp.object.get("idlNames").?.object;
        for (idl_names.keys(), idl_names.values()) |name, d| {
            const kind = strField(d.object, "type");
            const gop = try g.defs.getOrPut(name);
            if (!gop.found_existing or (allowed and !gop.value_ptr.allowed)) {
                gop.value_ptr.* = .{ .kind = kind, .json = d, .allowed = allowed };
            }
        }
        if (!allowed) continue;
        const ext_names = idlp.object.get("idlExtendedNames").?.object;
        for (ext_names.keys(), ext_names.values()) |name, list| {
            for (list.array.items) |x| {
                const kind = strField(x.object, "type");
                if (eql(kind, "includes")) {
                    const gop = try g.includes.getOrPut(name);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(a, strField(x.object, "includes"));
                } else {
                    const gop = try g.partials.getOrPut(name);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(a, x);
                }
            }
        }
    }

    // Interfaces and namespaces defined in allowlisted specs.
    var ifaces: std.ArrayListUnmanaged([]const u8) = .empty;
    var dit = g.defs.iterator();
    while (dit.next()) |e| {
        const d = e.value_ptr.*;
        if (!d.allowed) continue;
        if (!eql(d.kind, "interface") and !eql(d.kind, "namespace")) continue;
        if (!exposedOnWindow(d.json)) continue;
        try g.generated.put(e.key_ptr.*, {});
        try ifaces.append(a, e.key_ptr.*);
    }
    std.mem.sort([]const u8, ifaces.items, {}, lessStr);
    for (ifaces.items) |n| try g.file_decls.put(n, {});
    for ([_][]const u8{ "std", "js", "rt", "ext", "Callback", "Promise", "window", "document", "context", "context2d", "contextWebgl2", "contextWebgpu" }) |n| try g.file_decls.put(n, {});
    try g.collectOverloads();

    // Interfaces.
    var body: std.Io.Writer.Allocating = .init(a);
    for (ifaces.items) |n| try g.emitInterface(&body.writer, n, eql(g.def(n).?.kind, "namespace"));

    // Member wrappers, one struct per declaring interface or mixin.
    var impl_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var iit = g.impls.keyIterator();
    while (iit.next()) |k| try impl_names.append(a, k.*);
    std.mem.sort([]const u8, impl_names.items, {}, lessStr);
    for (impl_names.items) |n| {
        try body.writer.print("\npub const impl_{s} = struct {{", .{n});
        try body.writer.writeAll(g.impls.getPtr(n).?.written());
        try body.writer.writeAll("};\n");
    }

    // Enums referenced by generated members.
    var enum_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var eit = g.used_enums.keyIterator();
    while (eit.next()) |k| try enum_names.append(a, k.*);
    std.mem.sort([]const u8, enum_names.items, {}, lessStr);
    for (enum_names.items) |n| try g.emitEnum(&body.writer, n);

    // Externs (and zero-returning stubs for non-browser builds).
    var ext_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var xit = g.externs.keyIterator();
    while (xit.next()) |k| try ext_names.append(a, k.*);
    std.mem.sort([]const u8, ext_names.items, {}, lessStr);

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(
        \\//! Generated by tools/codegen/web.zig from webref WebIDL - do not edit.
        \\//! Run `zig build webgen` to regenerate.
        \\const std = @import("std");
        \\const js = @import("../js.zig");
        \\const rt = @import("rt.zig");
        \\
        \\pub const Callback = js.Callback;
        \\pub const Promise = rt.Promise;
        \\
        \\/// `globalThis`; never needs `deinit`.
        \\pub fn window() Window {
        \\    return .{ .h = .global };
        \\}
        \\
        \\/// `window.document`; call `deinit` when done.
        \\pub fn document() Document {
        \\    return window().document();
        \\}
        \\
        \\/// `canvas.getContext("2d")`, typed; null if unavailable.
        \\pub fn context2d(canvas: anytype) ?CanvasRenderingContext2D {
        \\    return context(CanvasRenderingContext2D, canvas, "2d", null);
        \\}
        \\
        \\/// `canvas.getContext("webgl2", options)`, typed; null if unavailable.
        \\pub fn contextWebgl2(canvas: anytype, options: anytype) ?WebGL2RenderingContext {
        \\    return context(WebGL2RenderingContext, canvas, "webgl2", options);
        \\}
        \\
        \\/// `canvas.getContext("webgpu")`, typed; null if unavailable.
        \\pub fn contextWebgpu(canvas: anytype) ?GPUCanvasContext {
        \\    return context(GPUCanvasContext, canvas, "webgpu", null);
        \\}
        \\
        \\fn context(comptime T: type, canvas: anytype, id: []const u8, options: anytype) ?T {
        \\    const v = impl_HTMLCanvasElement.getContext(canvas, id, options);
        \\    if (@backingInt(v) <= 1) return null;
        \\    return .{ .h = v };
        \\}
        \\
    );
    try w.writeAll(body.written());
    try w.writeAll("\nconst ext = if (js.enabled) struct {\n");
    for (ext_names.items) |n| {
        const x = g.externs.get(n).?;
        try w.print("    extern \"__zx_web\" fn @\"{s}\"({s}) {s};\n", .{ n, x.params, x.ret });
    }
    try w.writeAll("} else struct {\n");
    for (ext_names.items) |n| {
        const x = g.externs.get(n).?;
        try w.print("    fn @\"{s}\"(", .{n});
        var pit = std.mem.splitSequence(u8, x.params, ", ");
        var first = true;
        while (pit.next()) |pt| {
            if (pt.len == 0) continue;
            if (!first) try w.writeAll(", ");
            try w.print("_: {s}", .{pt});
            first = false;
        }
        if (eql(x.ret, "void")) try w.writeAll(") void {}\n") else try w.print(") {0s} {{\n        return std.mem.zeroes({0s});\n    }}\n", .{x.ret});
    }
    try w.writeAll("};\n");

    // Shims, sorted for binary search.
    var s: std.Io.Writer.Allocating = .init(a);
    const sw = &s.writer;
    try sw.writeAll(
        \\//! Generated by tools/codegen/web.zig - do not edit.
        \\//! JS shim per `__zx_web` import; `zx app asset --wasm` keeps the ones an app uses.
        \\
        \\pub const Entry = struct { []const u8, []const u8 };
        \\
        \\/// Sorted by import name.
        \\pub const shims = [_]Entry{
        \\
    );
    // Hand-written core shims ('$' sorts before letters).
    try sw.writeAll("    .{ \"$.then\", \"(p,a,b)=>{R[p].then(F(a),F(b))}\" },\n");
    for (ext_names.items) |n| try sw.print("    .{{ \"{s}\", \"{f}\" }},\n", .{ n, std.zig.fmtString(g.externs.get(n).?.shim) });
    try sw.writeAll("};\n\n/// Sorted by enum name; JS arrays of IDL enum values.\npub const enums = [_]Entry{\n");
    for (enum_names.items) |n| {
        const values = g.def(n).?.json.object.get("values").?.array.items;
        var arr: std.Io.Writer.Allocating = .init(a);
        try arr.writer.writeAll("[");
        for (values, 0..) |v, i| {
            if (i > 0) try arr.writer.writeAll(",");
            try arr.writer.print("\"{s}\"", .{strField(v.object, "value")});
        }
        try arr.writer.writeAll("]");
        try sw.print("    .{{ \"{s}\", \"{f}\" }},\n", .{ n, std.zig.fmtString(arr.written()) });
    }
    try sw.writeAll("};\n");

    // Native smoke test: every wrapper type-checks and runs against the stubs.
    std.mem.sort([]const u8, g.smoke.items, {}, lessStr);
    var t: std.Io.Writer.Allocating = .init(a);
    try t.writer.writeAll(
        \\//! Generated by tools/codegen/web.zig - do not edit.
        \\//! Calls every browser binding once; natively these hit the zero stubs.
        \\const std = @import("std");
        \\const zx = @import("zx");
        \\const web = zx.client.web;
        \\const js = zx.client.js;
        \\
        \\test "web bindings: interfaces resolve" {
        \\    @setEvalBranchQuota(100_000);
        \\    inline for (comptime std.meta.declarations(web)) |name| {
        \\        const T = @field(web, name);
        \\        if (@TypeOf(T) == type and @typeInfo(T) == .@"struct") std.testing.refAllDecls(T);
        \\    }
        \\}
        \\
        \\test "web bindings: every member compiles" {
        \\    const s: struct { h: js.Value = .null } = .{};
        \\    const gpa = std.testing.allocator;
        \\
    );
    for (g.smoke.items) |line| try t.writer.print("{s}\n", .{line});
    try t.writer.writeAll("}\n");

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = out_smoke, .data = t.written() });
    try cwd.writeFile(io, .{ .sub_path = out_events, .data = try genEventTypes(&g, io) });
    try cwd.createDirPath(io, "src/runtime/client/web");
    try cwd.writeFile(io, .{ .sub_path = out_zig, .data = out.written() });
    try cwd.writeFile(io, .{ .sub_path = out_shims, .data = s.written() });
    std.debug.print("Generated {s} ({d} interfaces, {d} externs, {d} enums) and {s}\n", .{ out_zig, ifaces.items.len, ext_names.items.len, enum_names.items.len, out_shims });
}

// ---------------------------------------------------------- event types

// `EventType` for delegated `on<name>` template handlers.
fn genEventTypes(g: *Gen, io: std.Io) ![]const u8 {
    const a = g.a;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(a);
    for (legacy_events) |n| {
        try names.append(a, n);
        try seen.put(n, {});
    }

    var extra: std.ArrayListUnmanaged([]const u8) = .empty;
    for ([_][]const u8{ "GlobalEventHandlers", "DocumentAndElementEventHandlers" }) |mixin| {
        var srcs: std.ArrayListUnmanaged(Source) = .empty;
        const d = g.def(mixin) orelse continue;
        try g.appendMembers(mixin, d.json, &srcs);
        if (g.partials.get(mixin)) |ps| for (ps.items) |p| try g.appendMembers(mixin, p, &srcs);
        for (srcs.items) |src| {
            const n = strField(src.m.object, "name");
            if (!std.mem.startsWith(u8, n, "on") or !isEventHandler(src.m)) continue;
            const ev = n[2..];
            if (seen.contains(ev)) continue;
            try seen.put(ev, {});
            try extra.append(a, ev);
        }
    }
    std.mem.sort([]const u8, extra.items, {}, lessStr);
    try names.appendSlice(a, extra.items);

    // Bubbling per webref events.json (element targets only).
    const content = try std.Io.Dir.cwd().readFileAlloc(io, "vendor/webref/ed/events.json", a, .unlimited);
    const events = try std.json.parseFromSliceLeaky(Json, a, content, .{});
    var non_bubbling = std.StringHashMap(void).init(a);
    var bubbling = std.StringHashMap(void).init(a);
    for (events.array.items) |e| {
        const ty = strField(e.object, "type");
        const targets = e.object.get("targets") orelse continue;
        for (targets.array.items) |t| {
            const target = strField(t.object, "target");
            if (!std.mem.endsWith(u8, target, "Element") and !eql(target, "Node") and !eql(target, "Document")) continue;
            const b = t.object.get("bubbles") orelse continue;
            if (b != .bool) continue;
            try (if (b.bool) &bubbling else &non_bubbling).put(ty, {});
        }
    }

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(
        \\//! Generated by tools/codegen/web.zig from webref - do not edit.
        \\//! Run `zig build webgen` to regenerate.
        \\const std = @import("std");
        \\
        \\/// DOM events usable as `on<name>` template handlers, delegated from the root.
        \\pub const EventType = enum(u8) {
        \\
    );
    for (names.items) |n| try w.print("    {f},\n", .{ident(n)});
    try w.writeAll(
        \\
        \\    pub fn fromAttributeName(name: []const u8) ?EventType {
        \\        if (name.len < 3 or !std.mem.startsWith(u8, name, "on")) return null;
        \\        return std.meta.stringToEnum(EventType, name[2..]);
        \\    }
        \\
        \\    /// `focus`/`blur` don't bubble, so they delegate as `focusin`/`focusout`.
        \\    pub fn domEventName(self: EventType) []const u8 {
        \\        return switch (self) {
        \\            .focus => "focusin",
        \\            .blur => "focusout",
        \\            else => @tagName(self),
        \\        };
        \\    }
        \\
        \\    /// Listener attached only while some element handles it.
        \\    pub fn isHighFreq(self: EventType) bool {
        \\        return switch (self) {
        \\
    );
    try writeCases(w, names.items, &high_freq_events, null);
    try w.writeAll(
        \\            => true,
        \\            else => false,
        \\        };
        \\    }
        \\
        \\    /// Non-bubbling events use a capture listener and dispatch to the target only.
        \\    pub fn bubbles(self: EventType) bool {
        \\        return switch (self) {
        \\
    );
    var nb: std.ArrayListUnmanaged([]const u8) = .empty;
    for (names.items) |n| {
        if (eql(n, "focus") or eql(n, "blur")) continue;
        // Element scrolls don't bubble; only the document's does.
        const element_only = eql(n, "scroll") or eql(n, "scrollend");
        if (element_only or (non_bubbling.contains(n) and !bubbling.contains(n))) try nb.append(a, n);
    }
    try writeCases(w, names.items, nb.items, null);
    try w.writeAll(
        \\            => false,
        \\            else => true,
        \\        };
        \\    }
        \\
        \\    pub fn isPassive(self: EventType) bool {
        \\        return switch (self) {
        \\
    );
    try writeCases(w, names.items, &passive_events, null);
    try w.writeAll(
        \\            => true,
        \\            else => false,
        \\        };
        \\    }
        \\};
        \\
    );
    return out.written();
}

fn writeCases(w: *std.Io.Writer, all: []const []const u8, pick: []const []const u8, _: ?void) !void {
    try w.writeAll("            ");
    var first = true;
    for (pick) |n| {
        const present = for (all) |x| {
            if (eql(x, n)) break true;
        } else false;
        if (!present) continue;
        if (!first) try w.writeAll(", ");
        try w.print(".{f}", .{ident(n)});
        first = false;
    }
    try w.writeAll("\n");
}

// ---------------------------------------------------------------- helpers

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn strField(o: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

fn boolField(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn isStatic(m: Json) bool {
    return eql(strField(m.object, "special"), "static");
}

fn argCount(m: Json) usize {
    const args = m.object.get("arguments") orelse return 0;
    return args.array.items.len;
}

fn indexOf(items: []const Json, m: Json) ?usize {
    for (items, 0..) |x, i| {
        if (x.object.get("href") != null and m.object.get("href") != null) {
            if (eql(strField(x.object, "href"), strField(m.object, "href")) and argCount(x) == argCount(m)) return i;
        }
        if (x.object.keys().ptr == m.object.keys().ptr) return i;
    }
    return null;
}

fn hasExtAttr(m: Json, name: []const u8) bool {
    const attrs = m.object.get("extAttrs") orelse return false;
    for (attrs.array.items) |x| if (eql(strField(x.object, "name"), name)) return true;
    return false;
}

fn exposedOnWindow(m: Json) bool {
    const attrs = m.object.get("extAttrs") orelse return true;
    for (attrs.array.items) |x| {
        if (!eql(strField(x.object, "name"), "Exposed")) continue;
        const rhs = x.object.get("rhs") orelse return true;
        if (rhs != .object) return true;
        const t = strField(rhs.object, "type");
        if (eql(t, "*")) return true;
        const v = rhs.object.get("value") orelse return true;
        if (v == .string) return eql(v.string, "Window");
        if (v == .array) {
            for (v.array.items) |item| if (eql(strField(item.object, "value"), "Window")) return true;
            return false;
        }
        return true;
    }
    return true;
}

fn isEventHandler(m: Json) bool {
    const t = m.object.get("idlType") orelse return false;
    const inner = t.object.get("idlType") orelse return false;
    if (inner != .string) return false;
    return std.mem.endsWith(u8, inner.string, "EventHandler");
}

fn isReserved(n: []const u8) bool {
    for ([_][]const u8{ "h", "deinit", "as", "object" }) |r| if (eql(n, r)) return true;
    return false;
}

// Namespaces are globals by name; interface statics hang off the constructor.
fn jsGlobal(name: []const u8) []const u8 {
    return name;
}

// Escapes keywords and primitive names (`type`, `u8`) as `@"..."`.
fn ident(name: []const u8) std.zig.FormatId {
    return std.zig.fmtId(name);
}
