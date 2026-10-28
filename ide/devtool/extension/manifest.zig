const std = @import("std");

pub const Browser = enum { chromium, firefox, safari };

const icon = "pages/assets/branding/ziex-logo-colored-128x128.png";
const all_urls: []const []const u8 = &.{"<all_urls>"};

/// Static devtools page; it only needs devtools.js, not the Ziex runtime.
pub const devtools_html =
    \\<!doctype html>
    \\<meta charset="utf-8">
    \\<script src="scripts/devtools.js"></script>
    \\
;

// No `permissions`: content scripts, messaging and devtools APIs need none.
const Manifest = struct {
    manifest_version: u8 = 3,
    name: []const u8 = "Ziex DevTools",
    version: []const u8,
    description: []const u8 = "DevTools browser extension for Ziex Framework",
    icons: Icons = .{},
    devtools_page: []const u8 = "devtools.html",
    action: struct {
        default_icon: Icons = .{},
        default_popup: []const u8 = "pages/popup.html",
        default_title: []const u8 = "Ziex DevTools",
    } = .{},
    background: Background,
    content_scripts: []const ContentScript = &.{
        .{ .js = &.{"scripts/page.js"}, .world = "MAIN" },
        .{ .js = &.{"scripts/content.js"} },
    },
    web_accessible_resources: ?[]const struct {
        resources: []const []const u8,
        matches: []const []const u8,
    } = null,
    content_security_policy: struct {
        // The panel talks to the local `zx dev` server, but never loads scripts from it
        extension_pages: []const u8 = "script-src 'self' 'wasm-unsafe-eval'; " ++
            "connect-src 'self' http://localhost:* http://127.0.0.1:* ws://localhost:* ws://127.0.0.1:* " ++
            "wss://localhost:* wss://127.0.0.1:*; object-src 'self'",
    } = .{},
    browser_specific_settings: ?struct {
        gecko: struct {
            id: []const u8 = "devtools@ziex.dev",
            // MAIN world content scripts need 128, data_collection_permissions 140
            strict_min_version: []const u8 = "140.0",
            // Required by AMO for new add-ons
            data_collection_permissions: struct {
                required: []const []const u8 = &.{"none"},
            } = .{},
        } = .{},
    } = null,

    const Icons = struct { @"128": []const u8 = icon };

    const Background = struct {
        service_worker: ?[]const u8 = null,
        scripts: ?[]const []const u8 = null,
    };

    const ContentScript = struct {
        js: []const []const u8,
        matches: []const []const u8 = all_urls,
        run_at: []const u8 = "document_start",
        world: ?[]const u8 = null,
    };
};

pub fn render(allocator: std.mem.Allocator, browser: Browser, version: []const u8) ![]const u8 {
    const background_script = "scripts/background.js";
    const manifest: Manifest = switch (browser) {
        .chromium => .{
            .version = version,
            .background = .{ .service_worker = background_script },
        },
        // Safari ignores `world`, so content.js injects page.js through a script tag
        .safari => .{
            .version = version,
            .background = .{ .service_worker = background_script },
            .content_scripts = &.{.{ .js = &.{"scripts/content.js"} }},
            .web_accessible_resources = &.{.{ .resources = &.{"scripts/page.js"}, .matches = all_urls }},
        },
        // Firefox MV3 has no service workers, only event pages
        .firefox => .{
            .version = version,
            .background = .{ .scripts = &.{background_script} },
            .browser_specific_settings = .{},
        },
    };
    return std.json.Stringify.valueAlloc(allocator, manifest, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
}

// Safari container app; bundle IDs must match extension/safari.swift.
pub const safari_app_name = "Ziex DevTools";
pub const safari_extension_name = "Ziex DevTools Extension";

pub fn safariAppPlist(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    return plist(allocator, version, key("CFBundleIdentifier", "dev.ziex.devtools") ++
        key("CFBundleExecutable", safari_app_name) ++
        key("CFBundleName", safari_app_name) ++
        key("CFBundlePackageType", "APPL") ++
        key("NSPrincipalClass", "NSApplication") ++
        key("LSApplicationCategoryType", "public.app-category.developer-tools"));
}

pub fn safariExtensionPlist(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    return plist(allocator, version, key("CFBundleIdentifier", "dev.ziex.devtools.Extension") ++
        key("CFBundleExecutable", safari_extension_name) ++
        key("CFBundleName", safari_app_name) ++
        key("CFBundleDisplayName", safari_app_name) ++
        key("CFBundlePackageType", "XPC!") ++
        "<key>NSExtension</key><dict>\n" ++
        key("NSExtensionPointIdentifier", "com.apple.Safari.web-extension") ++
        key("NSExtensionPrincipalClass", "SafariWebExtensionHandler") ++
        "</dict>\n");
}

/// Safari requires both the app and the extension to be sandboxed.
pub const safari_entitlements = plist_header ++ "<key>com.apple.security.app-sandbox</key><true/>\n" ++ plist_footer;

const plist_header =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0"><dict>
    \\
;
const plist_footer = "</dict></plist>\n";
const plist_common = key("CFBundleInfoDictionaryVersion", "6.0") ++
    key("CFBundleDevelopmentRegion", "en") ++
    key("LSMinimumSystemVersion", "12.0") ++
    "<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>\n" ++
    plist_footer;

fn key(comptime name: []const u8, comptime value: []const u8) []const u8 {
    return "<key>" ++ name ++ "</key><string>" ++ value ++ "</string>\n";
}

fn plist(allocator: std.mem.Allocator, version: []const u8, comptime keys: []const u8) ![]const u8 {
    return std.mem.concat(allocator, u8, &.{
        plist_header ++ keys ++ "<key>CFBundleShortVersionString</key><string>",
        version,
        "</string>\n<key>CFBundleVersion</key><string>",
        version,
        "</string>\n" ++ plist_common,
    });
}
