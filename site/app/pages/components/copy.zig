//! Copy buttons for code blocks and install boxes (replaces assets/clipboard.js).
//! `setup` is idempotent: buttons are added once and one delegated listener copies.
const std = @import("std");
const zx = @import("zx");

const web = zx.client.web;
const js = zx.client.js;
const gpa = zx.allocator;

var listening = false;

pub fn setup() void {
    addCopyButtons();
    if (listening) return;
    listening = true;
    const doc = web.document();
    defer doc.deinit();
    doc.addEventListener("click", .fromFn(onClick, .{}), null);
}

fn onClick(args: []const js.Value) void {
    if (args.len == 0) return;
    const ev: web.Event = .{ .h = args[0] };
    const target = ev.target() orelse return;
    defer target.deinit();
    const button = target.as(web.Element).closest(".copy-button") orelse return;
    defer button.deinit();
    copyFrom(button);
}


const copy_button_html =
    \\<svg class="copy-icon" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
    \\  <path d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 0 1 0 1.5h-1.5a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1.75 0 0 1 9.25 16h-7.5A1.75 1.75 0 0 1 0 14.25v-7.5Z"></path>
    \\  <path d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0 1 14.25 11h-7.5A1.75 1.75 0 0 1 5 9.25v-7.5Zm1.75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a.25.25 0 0 0-.25-.25h-7.5Z"></path>
    \\</svg>
    \\<svg class="check-icon" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true" style="display: none;">
    \\  <path d="M13.78 4.22a.75.75 0 0 1 0 1.06l-7.25 7.25a.75.75 0 0 1-1.06 0L2.22 9.28a.751.751 0 0 1 .018-1.042.751.751 0 0 1 1.042-.018L6 10.94l6.72-6.72a.75.75 0 0 1 1.06 0Z"></path>
    \\</svg>
;

fn newCopyButton(doc: web.Document, class: []const u8, label: []const u8) web.Element {
    const b = doc.createElement("button", null);
    b.setClassName(class);
    b.setAttribute("aria-label", label);
    b.setInnerHTML(copy_button_html);
    return b;
}

fn addCopyButtons() void {
    const doc = web.document();
    defer doc.deinit();

    const codes = doc.querySelectorAll("pre code");
    defer codes.deinit();
    for (0..codes.length()) |i| {
        const code = codes.item(@intCast(i)) orelse continue;
        defer code.deinit();
        const pre = code.parentElement() orelse continue;
        defer pre.deinit();
        if (has(pre, ".copy-button")) continue;
        if (within(pre, ".feature-examples") or within(pre, ".code-section") or within(pre, ".feature-panel-visual")) continue;
        const classes = pre.classList();
        defer classes.deinit();
        if (classes.contains("feature-syntax")) continue;
        const b = newCopyButton(doc, "copy-button", "Copy code");
        defer b.deinit();
        _ = pre.appendChild(b).deinit();
    }

    const boxes = doc.querySelectorAll(".install-box");
    defer boxes.deinit();
    for (0..boxes.length()) |i| {
        const n = boxes.item(@intCast(i)) orelse continue;
        defer n.deinit();
        const box = n.as(web.Element);
        if (has(box, ".copy-button")) continue;
        const b = newCopyButton(doc, "copy-button install-box-copy", "Copy command");
        defer b.deinit();
        const parent = box.querySelector(".install-box-header") orelse box.querySelector(".install-box-content") orelse continue;
        defer parent.deinit();
        _ = parent.appendChild(b).deinit();
    }
}

fn has(el: web.Element, selector: []const u8) bool {
    const found = el.querySelector(selector) orelse return false;
    found.deinit();
    return true;
}

fn within(el: web.Element, selector: []const u8) bool {
    const found = el.closest(selector) orelse return false;
    found.deinit();
    return true;
}

fn textOf(node: anytype) ?[]u8 {
    return (node.textContent(gpa) catch return null) orelse null;
}

/// Leading `$ ` / `> ` prompt stripped.
fn stripPrompt(s: []const u8) []const u8 {
    if (s.len > 0 and (s[0] == '$' or s[0] == '>')) return std.mem.trimStart(u8, s[1..], &std.ascii.whitespace);
    return s;
}

fn copyFrom(button: web.Element) void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);

    if (within(button, ".install-box")) {
        const box = button.closest(".install-box").?;
        defer box.deinit();
        const install = installCode(box) orelse return;
        defer install.deinit();
        const lines = install.querySelectorAll(".install-code-multiline > div");
        defer lines.deinit();
        if (lines.length() > 0) {
            for (0..lines.length()) |i| {
                const l = lines.item(@intCast(i)) orelse continue;
                defer l.deinit();
                const t = textOf(l) orelse continue;
                defer gpa.free(t);
                if (i > 0) out.appendSlice(gpa, " && ") catch return;
                out.appendSlice(gpa, std.mem.trim(u8, stripPrompt(t), &std.ascii.whitespace)) catch return;
            }
        } else {
            const t = textOf(install) orelse return;
            defer gpa.free(t);
            var s = stripPrompt(t);
            var buf: [256]u8 = undefined;
            if (std.mem.indexOf(u8, s, " #or")) |at| {
                if (s.len - 4 <= buf.len) {
                    @memcpy(buf[0..at], s[0..at]);
                    @memcpy(buf[at .. s.len - 4], s[at + 4 ..]);
                    s = buf[0 .. s.len - 4];
                }
            }
            out.appendSlice(gpa, std.mem.trim(u8, s, &std.ascii.whitespace)) catch return;
        }
    } else {
        const pre = button.parentElement() orelse return;
        defer pre.deinit();
        const code = pre.querySelector("code") orelse return;
        defer code.deinit();
        const t = textOf(code) orelse return;
        defer gpa.free(t);
        out.appendSlice(gpa, t) catch return;
    }
    copyText(out.items, button);
}

/// The install snippet for the checked tab, else the first.
fn installCode(box: web.Element) ?web.Element {
    if (box.querySelector(".install-tab-radio:checked")) |radio| {
        defer radio.deinit();
        const id = radio.id(gpa) catch null;
        if (id) |tab_id| {
            defer gpa.free(tab_id);
            var buf: [128]u8 = undefined;
            const name = if (std.mem.indexOf(u8, tab_id, "tab-")) |at|
                std.fmt.bufPrint(&buf, "#content-{s}{s}", .{ tab_id[0..at], tab_id[at + 4 ..] }) catch null
            else
                std.fmt.bufPrint(&buf, "#content-{s}", .{tab_id}) catch null;
            if (name) |sel| if (box.querySelector(sel)) |tab| {
                defer tab.deinit();
                if (tab.querySelector(".install-code")) |code| return code;
            };
        }
    }
    return box.querySelector(".install-code");
}

const Copy = struct { button: js.Value, text: []u8 };

fn copyText(text: []const u8, button: web.Element) void {
    const nav = web.window().navigator();
    defer nav.deinit();
    const clipboard = nav.clipboard();
    defer clipboard.deinit();
    const job = gpa.create(Copy) catch return;
    job.* = .{ .button = button.h.dup(), .text = gpa.dupe(u8, text) catch return };
    // One callback for both outcomes: success resolves with `undefined`.
    const done = js.Callback.bind(job, copied, .{ .once = true });
    const p = clipboard.writeText(text);
    defer p.deinit();
    p.then(done, done);
}

fn copied(job: *Copy, args: []const js.Value) void {
    defer {
        job.button.deinit();
        gpa.free(job.text);
        gpa.destroy(job);
    }
    const button: web.Element = .{ .h = job.button };
    const failed = args.len > 0 and args[0] != .undefined;
    if (!failed or fallbackCopy(job.text)) showCopied(button);
}

/// `document.execCommand("copy")` from a hidden textarea.
fn fallbackCopy(text: []const u8) bool {
    const doc = web.document();
    defer doc.deinit();
    const body = doc.body() orelse return false;
    defer body.deinit();
    const area = doc.createElement("textarea", null).as(web.HTMLTextAreaElement);
    defer area.deinit();
    area.setValue(text);
    const style = area.style();
    defer style.deinit();
    style.setProperty("position", "fixed", null);
    style.setProperty("opacity", "0", null);
    _ = body.appendChild(area).deinit();
    area.select();
    const ok = doc.execCommand("copy", null, null);
    area.remove();
    return ok;
}

fn iconDisplay(button: web.Element, selector: []const u8, value: []const u8) void {
    const icon = button.querySelector(selector) orelse return;
    defer icon.deinit();
    const style = icon.as(web.HTMLElement).style();
    defer style.deinit();
    style.setProperty("display", value, null);
}

fn showCopied(button: web.Element) void {
    setCopied(button, true);
    const keep = gpa.create(js.Value) catch return;
    keep.* = button.h.dup();
    _ = web.window().setTimeout(js.Callback.bind(keep, resetCopied, .{ .once = true }), 2000, .{});
}

fn resetCopied(h: *js.Value, _: []const js.Value) void {
    setCopied(.{ .h = h.* }, false);
    h.deinit();
    gpa.destroy(h);
}

fn setCopied(button: web.Element, on: bool) void {
    iconDisplay(button, ".copy-icon", if (on) "none" else "block");
    iconDisplay(button, ".check-icon", if (on) "block" else "none");
    const classes = button.classList();
    defer classes.deinit();
    if (on) classes.add(.{"copied"}) else classes.remove(.{"copied"});
    button.setAttribute("aria-label", if (on) "Copied!" else "Copy code");
}
