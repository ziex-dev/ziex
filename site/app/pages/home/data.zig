//! Content for the home page feature canvases (drawn by canvas.zig).
const std = @import("std");
const zx = @import("zx");

pub const PerfBar = struct { label: []const u8, value: f64, display: []const u8, self: bool = false };
pub const RoutingScene = struct { file: []const u8, kind: []const u8, url: []const u8, note: []const u8 };
pub const ApiMethod = struct { method: []const u8, path: []const u8, status: []const u8, body: []const u8 };
pub const ControlScene = struct { id: []const u8, snippet: []const u8 };
pub const DeployTarget = struct { name: []const u8, artifact: []const u8 };
pub const DeployArtifact = struct { id: []const u8, label: []const u8, command: []const u8, flag: []const u8, caption: []const u8 };
pub const Allocation = struct { label: []const u8, size: u32 };

/// SSR requests/second, top 5 frameworks, highest first.
pub const performance: []const PerfBar = &perfBars();

fn perfBars() [@min(5, bench_len)]PerfBar {
    @setEvalBranchQuota(20000);
    const results = bench.results;
    var all: [bench_len]PerfBar = undefined;
    for (@typeInfo(@TypeOf(results)).@"struct".field_names, 0..) |name, i| {
        const d = @field(results, name);
        all[i] = .{ .label = d.label, .value = d.requests_per_sec, .display = formatLargeNumber(d.requests_per_sec), .self = std.mem.eql(u8, d.id, "ziex") };
    }
    std.sort.insertion(PerfBar, &all, {}, struct {
        fn more(_: void, a: PerfBar, b: PerfBar) bool {
            return a.value > b.value;
        }
    }.more);
    return all[0..@min(5, bench_len)].*;
}

const bench = @import("../bench.zon");
const bench_len = @typeInfo(@TypeOf(bench.results)).@"struct".field_types.len;

fn formatLargeNumber(n: f64) []const u8 {
    if (n >= 1000) {
        const k = n / 1000;
        if (k >= 10) return std.fmt.comptimePrint("{d}k", .{@as(u32, @intFromFloat(k))});
        return std.fmt.comptimePrint("{d:.1}k", .{k});
    }
    return std.fmt.comptimePrint("{d}", .{@as(u32, @intFromFloat(n))});
}

pub const routing = [_]RoutingScene{
    .{ .file = "page.zx", .kind = "page", .url = "/", .note = "Page route" },
    .{ .file = "layout.zx", .kind = "layout", .url = "/*", .note = "Wraps children" },
    .{ .file = "about/page.zx", .kind = "page", .url = "/about", .note = "Nested page" },
    .{ .file = "api/route.zig", .kind = "route", .url = "/api", .note = "API handler" },
    .{ .file = "error.zx", .kind = "error", .url = "error", .note = "Error boundary" },
    .{ .file = "notfound.zx", .kind = "notfound", .url = "404", .note = "Not found" },
};

pub const api = struct {
    pub const file = "pages/api/users/route.zig";
    pub const signature = "(ctx: zx.RouteContext) !void";
    pub const methods = [_]ApiMethod{
        .{ .method = "GET", .path = "/api/users", .status = "200 OK", .body = "[{ \"id\": 1, \"name\": \"Zig\" }]" },
        .{ .method = "POST", .path = "/api/users", .status = "201 Created", .body = "{ \"id\": 2, \"created\": true }" },
        .{ .method = "DELETE", .path = "/api/users/1", .status = "204 No Content", .body = "" },
    };
};

pub const control_flow = struct {
    pub const scenes = [_]ControlScene{
        .{ .id = "if", .snippet = "{if (ok) ( <Ok/> ) else ( <Err/> )}" },
        .{ .id = "for", .snippet = "{for (items) |item| ( <Row/> )}" },
        .{ .id = "switch", .snippet = "{switch (role) { .admin => ... }}" },
    };
    pub const if_arms = [_][]const u8{ "<Ok/>", "<Err/>" };
    pub const for_item = "<Row/>";
    pub const for_count = 3;
    pub const switch_title = "switch (role)";
    pub const switch_arms = [_][]const u8{ ".admin", ".member", "else" };
};

pub const hybrid = struct {
    pub const server_steps = [_][]const u8{ "render <Page/>", "stream HTML" };
    pub const hint = "<Counter @client />";
    pub const button = "Click Me";
    pub const captions = [_][]const u8{
        "Start on the server, send HTML",
        "Hydrate only the islands that need it",
        "Interactive where it matters",
    };
};

pub const tooling = struct {
    pub const file = "pages/page.zx";
    pub const code = [_][]const u8{
        "pub fn Page(ctx: zx.PageContext) zx.Component {",
        "    return (",
        "        <main @allocator={ctx.arena}>",
        "            <h1>Hello, Ziex</h1>",
        "            <Counter @client />",
        "        </main>",
        "    );",
        "}",
    };
    pub const completions = [_][]const u8{ "@client", "@caching", "@allocator", "class" };
    pub const command = "zig build dev";
    pub const version = zx.info.version;
    pub const url = "http://localhost:3000";
    pub const restart_time = "0.38s";
};

pub const deploy = [_]DeployTarget{
    .{ .name = "Linux / macOS", .artifact = "binary" },
    .{ .name = "Docker", .artifact = "binary" },
    .{ .name = "Railway", .artifact = "binary" },
    .{ .name = "Cloudflare", .artifact = "wasi" },
    .{ .name = "Vercel", .artifact = "wasi" },
    .{ .name = "GitHub Pages", .artifact = "static" },
    .{ .name = "Netlify / S3", .artifact = "static" },
};

pub const deploy_artifacts = [_]DeployArtifact{
    .{ .id = "binary", .label = "native binary", .command = "zig build", .flag = "--release=fast", .caption = "Single static binary for any server" },
    .{ .id = "wasi", .label = "wasm32-wasi", .command = "zig build", .flag = "-Dtarget=wasm32-wasi", .caption = "WASI module for edge runtimes" },
    .{ .id = "static", .label = "static html", .command = "zx build", .flag = "--static", .caption = "Pre-rendered pages for any CDN" },
};

pub const memory = struct {
    pub const file = "pages/feed/page.zx";
    pub const code = [_][]const u8{
        "pub fn Page(ctx: zx.PageContext) !zx.Component {",
        "    const user = try ctx.arena.create(User);",
        "    const posts = try ctx.arena.alloc(Post, 32);",
        "    return (<Feed @allocator={ctx.arena} posts={posts} />);",
        "}",
    };
    pub const allocs = [_]Allocation{
        .{ .label = "User", .size = 48 },
        .{ .label = "[32]Post", .size = 160 },
        .{ .label = "<Feed/>", .size = 112 },
    };
    pub const capacity = 384;
};
