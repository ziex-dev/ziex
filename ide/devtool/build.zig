const std = @import("std");
const ziex = @import("ziex");
const esbuild = @import("esbuild");

const manifest = @import("extension/manifest.zig");
const zon = @import("build.zig.zon");

const Platform = enum {
    extension,
    development,
};

pub fn build(b: *std.Build) !void {
    // --- Target and Optimize from `zig build` arguments ---
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    const platform = b.option(Platform, "platform", "Platform to build for") orelse .development;
    build_options.addOption(Platform, "platform", platform);

    const exe = b.addExecutable(.{
        .name = "ziex_devtool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    exe.root_module.addOptions("build_options", build_options);
    var ziex_b = try ziex.init(b, exe, .{
        .cli = .{ .optimize = optimize },
        .app = .{
            .base_path = switch (platform) {
                .extension => "/pages/",
                else => null,
            },
            .client = .{
                .bindings = .{
                    .href = "/assets/app.js",
                },
            },
        },
    });
    ziex_b = ziex_b;

    const is_release = optimize != .debug;
    const client_scripts = esbuild.addBuild(b, .{
        .name = "devtool_scripts",
        .config = .{
            .entrypoints = &.{
                b.path("app/scripts/client.ts"),
            },
            .platform = .browser,
            .minify = is_release,
            .sourcemap = if (is_release) .none else .@"inline",
            .define = &.{
                .{ .key = "__DEV__", .value = if (is_release) "false" else "true" },
                .{ .key = "process.env.NODE_ENV", .value = if (is_release) "\"production\"" else "\"development\"" },
            },
        },
    });

    const install_main_js = b.addInstallFile(client_scripts.dir.path(b, "client.js"), "static/assets/app.js");
    b.default_step.dependOn(&install_main_js.step);

    const branding_dep = b.dependency("branding", .{});
    const install_branding = b.addInstallDirectory(.{
        .source_dir = branding_dep.path("compressed"),
        .install_dir = .prefix,
        .install_subdir = "static/assets/branding",
        .include_extensions = &.{"png"},
    });
    b.default_step.dependOn(&install_branding.step);

    // Panel pages, exported once and shared by every browser
    const pages_export = b.addRunArtifact(ziex_b.cli.exe);
    pages_export.addArgs(&.{ "build", "--static", "--build-args", "-Dplatform=extension", "--outdir" });
    const pages_dir = pages_export.addOutputDirectoryArg("pages");
    // The export runs a nested zig build whose inputs zig can't track
    pages_export.has_side_effects = true;

    const extension_step = b.step("extension", "Build all browser extensions");
    for (std.enums.values(manifest.Browser)) |browser| {
        const name = @tagName(browser);

        // `__BROWSER__` lets esbuild drop the other browsers' code
        const scripts = esbuild.addBuild(b, .{
            .name = b.fmt("{s}_scripts", .{name}),
            .config = .{
                .entrypoints = &.{
                    b.path("extension/background.ts"),
                    b.path("extension/content.ts"),
                    b.path("extension/page.ts"),
                    b.path("extension/devtools.ts"),
                },
                .platform = .browser,
                .format = .iife,
                .target = &.{switch (browser) {
                    .chromium => "chrome111",
                    .firefox => "firefox140",
                    .safari => "safari16",
                }},
                .minify = is_release,
                .define = &.{.{ .key = "__BROWSER__", .value = b.fmt("\"{s}\"", .{name}) }},
            },
        });

        const files = b.addWriteFiles();
        _ = files.addCopyDirectory(pages_dir, "pages", .{});
        _ = files.addCopyDirectory(scripts.dir, "scripts", .{ .include_extensions = &.{".js"} });
        _ = files.add("devtools.html", manifest.devtools_html);
        _ = files.add("manifest.json", try manifest.render(b.allocator, browser, zon.version));

        const step = b.step(name, b.fmt("Build {s} extension", .{name}));
        step.dependOn(&b.addInstallDirectory(.{
            .source_dir = files.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = name,
        }).step);
        extension_step.dependOn(step);

        if (browser == .safari) {
            if (b.graph.host.result.os.tag == .macos) addSafariApp(b, step, files.getDirectory());
            continue;
        }

        const zip = b.addSystemCommand(&.{ "zip", "-q", "-r", "-X" });
        zip.setCwd(files.getDirectory());
        zip.has_side_effects = true;
        const zip_output = zip.addOutputFileArg(b.fmt("ziex-devtools-{s}.zip", .{name}));
        zip.addArg(".");
        step.dependOn(&b.addInstallFile(zip_output, b.fmt("ziex-devtools-{s}.zip", .{name})).step);
    }
}

/// Builds the ad-hoc signed Safari container app with swiftc, no Xcode project needed.
fn addSafariApp(b: *std.Build, step: *std.Build.Step, extension_dir: std.Build.LazyPath) void {
    const app = manifest.safari_app_name ++ ".app";
    const appex = app ++ "/Contents/PlugIns/" ++ manifest.safari_extension_name ++ ".appex";

    const bundle = b.addWriteFiles();
    _ = bundle.addCopyFile(swiftBinary(b, "SAFARI_APP"), app ++ "/Contents/MacOS/" ++ manifest.safari_app_name);
    _ = bundle.add(app ++ "/Contents/Info.plist", manifest.safariAppPlist(b.allocator, zon.version) catch @panic("OOM"));
    _ = bundle.addCopyFile(swiftBinary(b, "SAFARI_EXTENSION"), appex ++ "/Contents/MacOS/" ++ manifest.safari_extension_name);
    _ = bundle.add(appex ++ "/Contents/Info.plist", manifest.safariExtensionPlist(b.allocator, zon.version) catch @panic("OOM"));
    _ = bundle.addCopyDirectory(extension_dir, appex ++ "/Contents/Resources", .{});
    const entitlements = bundle.add("entitlements.plist", manifest.safari_entitlements);

    // Sign a copy, the extension before the app that contains it
    const sign = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\app="$3/$(basename "$1")"
        \\ditto "$1" "$app"
        \\sign() { out=$(codesign --force --sign - --entitlements "$2" "$1" 2>&1) || { echo "$out" >&2; exit 1; }; }
        \\sign "$app/Contents/PlugIns/"*.appex "$2"
        \\sign "$app" "$2"
        ,
        "sh",
    });
    sign.addDirectoryArg(bundle.getDirectory().path(b, app));
    sign.addFileArg(entitlements);
    const signed = sign.addOutputDirectoryArg("signed").path(b, app);

    step.dependOn(&b.addInstallDirectory(.{ .source_dir = signed, .install_dir = .prefix, .install_subdir = app }).step);

    // ditto keeps the bundle's permissions and signature intact
    const zip = b.addSystemCommand(&.{ "ditto", "-c", "-k", "--keepParent" });
    zip.addDirectoryArg(signed);
    step.dependOn(&b.addInstallFile(zip.addOutputFileArg("ziex-devtools-safari.zip"), "ziex-devtools-safari.zip").step);
}

/// Universal (arm64 + x86_64) build of extension/safari.swift with `define` set.
fn swiftBinary(b: *std.Build, comptime define: []const u8) std.Build.LazyPath {
    const lipo = b.addSystemCommand(&.{ "lipo", "-create" });
    for ([_][]const u8{ "arm64", "x86_64" }) |arch| {
        const swiftc = b.addSystemCommand(&.{ "xcrun", "swiftc", "-O", "-parse-as-library", "-D", define, "-target", b.fmt("{s}-apple-macos12", .{arch}) });
        if (std.mem.eql(u8, define, "SAFARI_EXTENSION")) {
            swiftc.addArgs(&.{ "-application-extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain" });
        }
        swiftc.addFileArg(b.path("extension/safari.swift"));
        swiftc.addArg("-o");
        lipo.addFileArg(swiftc.addOutputFileArg(arch));
    }
    lipo.addArg("-output");
    return lipo.addOutputFileArg(define);
}
