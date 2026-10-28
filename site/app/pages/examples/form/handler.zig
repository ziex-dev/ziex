const std = @import("std");
const zx = @import("zx");

const User = struct { id: u32, name: []const u8 };

const RequestInfo = struct {
    is_reset: bool,
    is_delete: bool,
    is_add: bool,
    users: std.ArrayList(User),
    filtered_users: std.ArrayList(User),
};

pub fn handleRequest(ctx: zx.PageContext) RequestInfo {
    var users = std.ArrayList(User).empty;

    // Load from KV synchronously
    syncFromKv(ctx, &users);

    const qs = ctx.request.query;

    const is_reset = qs.get("reset") != null;
    const is_delete = qs.get("delete") != null;
    const is_add = qs.get("name") != null;

    if (is_reset) {
        handleReset(&users);
    }

    if (is_delete) {
        if (qs.get("delete")) |delete_id| {
            handleDeleteUser(&users, delete_id);
        }
    }

    if (is_add) {
        if (qs.get("name")) |name| {
            handleAddUser(ctx.arena, &users, name);
        }
    }

    const search_opt = qs.get("search");
    const filtered_users = filterUsers(ctx.arena, &users, search_opt);

    if (is_delete or is_add or is_reset) {
        // Save back to KV before redirecting
        syncToKv(ctx, &users);
        ctx.response.headers.set("Location", "/examples/form");
        ctx.response.setStatus(.found);
    }

    return RequestInfo{
        .is_reset = is_reset,
        .is_delete = is_delete,
        .is_add = is_add,
        .users = users,
        .filtered_users = filtered_users,
    };
}

fn handleReset(users: *std.ArrayList(User)) void {
    users.clearRetainingCapacity();
}

fn handleDeleteUser(users: *std.ArrayList(User), delete_id_str: []const u8) void {
    const delete_id = std.fmt.parseInt(u32, delete_id_str, 10) catch return;

    for (users.items, 0..) |user, i| {
        if (user.id == delete_id) {
            _ = users.orderedRemove(i);
            break;
        }
    }
}

fn handleAddUser(allocator: std.mem.Allocator, users: *std.ArrayList(User), name: []const u8) void {
    if (name.len == 0) return;

    var max_id: u32 = 0;
    for (users.items) |user| {
        if (user.id > max_id) max_id = user.id;
    }
    const new_id = max_id + 1;
    const name_copy = allocator.dupe(u8, name) catch @panic("OOM");
    users.append(allocator, User{ .id = new_id, .name = name_copy }) catch @panic("OOM");
}

fn filterUsers(allocator: std.mem.Allocator, users: *std.ArrayList(User), search_opt: ?[]const u8) std.ArrayList(User) {
    var filtered = std.ArrayList(User).empty;

    for (users.items) |user| {
        if (search_opt) |search| {
            if (std.mem.indexOf(u8, user.name, search) == null) {
                continue;
            }
        }
        filtered.append(allocator, user) catch @panic("OOM");
    }

    return filtered;
}

fn kv() zx.Kv {
    return zx.kv.scoped(.@"examples/form");
}

fn syncFromKv(ctx: zx.PageContext, users: *std.ArrayList(User)) void {
    const v = kv().get(ctx.arena, "users") catch return;
    const ul = zx.util.zxon.parse([]User, ctx.arena, v orelse return, .{}) catch return;
    users.appendSlice(ctx.arena, ul) catch return;
}

fn syncToKv(ctx: zx.PageContext, users: *std.ArrayList(User)) void {
    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    zx.util.zxon.serialize(users.items, &aw.writer, .{}) catch return;
    kv().put("users", aw.written(), .{}) catch return;
}
