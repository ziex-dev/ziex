const builtin = @import("builtin");
const std_cli = @import("std_cli");
const flags = @import("shared/flag.zig");

pub const Command = std_cli.Command;
pub const Argument = std_cli.Argument;

pub const version: Command = .{
    .name = .version,
    .help_short = "Show CLI version",
};

pub const init: Command = .{
    .name = .init,
    .help_short = "Initialize a new Ziex project in the current directory",
    .named_args = &.{
        Argument.init(.template, []const u8, .{
            .default_value = "starter",
            .short = 't',
            .help = "Template to use: a builtin (starter, docker) or any github:ziex-dev/template-<name> (cloudflare, vercel, node, railway, render)",
        }),
        Argument.init(.force, bool, .{
            .default_value = false,
            .short = 'f',
            .help = "Force initialization even if the directory is not empty",
        }),
        Argument.init(.existing, bool, .{
            .default_value = false,
            .help = "Initialize Ziex in an existing project",
        }),
    },
    .positional_args = &.{
        Argument.init(.path, ?[]const u8, .{
            .help = "Path to initialize the project in (default: current directory)",
        }),
    },
};

pub const dev: Command = .{
    .name = .dev,
    .help_short = "Start the app in development mode with rebuild on change",
    .named_args = &.{
        flags.bin_path,
        flags.build_args,
        flags.zig_path,
        flags.install_prefix,
        Argument.init(.port, u32, .{
            .default_value = 0,
            .short = 'p',
            .help = "Port to listen on (default: PORT env, or 3000). Uses the next free port if busy",
        }),
        Argument.init(.incremental, bool, .{
            .default_value = false,
            .help = "Enable incremental build (-fincremental of zig build)",
        }),
        Argument.init(.@"tui-progress", bool, .{
            .default_value = true,
            .help = "Show full build progress output from zig build",
        }),
        Argument.init(.@"tui-init-time-report", bool, .{
            .default_value = false,
            .help = "Show initial build duration before the server address",
        }),
        Argument.init(.@"tui-underline", bool, .{
            .default_value = true,
            .help = "Show underlined status messages",
        }),
        Argument.init(.@"tui-spinner", bool, .{
            .default_value = false,
            .help = "Show spinner for status messages",
        }),
        Argument.init(.@"tui-clear", bool, .{
            .default_value = false,
            .help = "Clear the terminal before every restart",
        }),
        Argument.init(.manifest, []const u8, .{
            .default_value = "",
            .help = "App manifest path (contains transpile_dir for `.zx` remap; default: <install-prefix>/manifest/app.zon)",
        }),
    },
};

pub const serve: Command = .{
    .name = .serve,
    .help_short = "Run the server",
    .named_args = &.{
        Argument.init(.port, u32, .{
            .default_value = 0,
            .short = 'p',
            .help = "Port to listen on (sets PORT; default: PORT env, or 3000)",
        }),
        flags.bin_path,
        flags.zig_path,
        flags.install_prefix,
        flags.release("fast", "Release mode passed to zig build as --release=<mode> (fast, safe, small; empty for debug)"),
        flags.build_args,
    },
};

pub const build: Command = .{
    .name = .build,
    .help_short = "Build the app (equivalent to `zig build`)",
    .named_args = &.{
        flags.build_args,
        flags.zig_path,
        flags.bin_path,
        flags.install_prefix,
        Argument.init(.target, []const u8, .{
            .default_value = "",
            .help = "Zig target triple to build for (e.g. wasm32-wasi, x86_64-linux-musl)",
        }),
        flags.release("", "Release mode passed to zig build as --release=<mode> (fast, safe, small). Default: debug, or small with --static"),
        Argument.init(.prerender, bool, .{
            .default_value = false,
            .help = "Also pre-render routes with `.rendering = .prerendered` into <install-prefix>/static next to the app",
        }),
        Argument.init(.static, bool, .{
            .default_value = false,
            .help = "Pre-render every route to static HTML in --outdir instead of building a server (can't be combined with --target)",
        }),
        Argument.init(.outdir, []const u8, .{
            .default_value = "",
            .short = 'o',
            .help = "Output directory for --static builds (default: dist)",
        }),
        Argument.init(.@"prerendered-only", bool, .{
            .default_value = false,
            .hidden = true,
            .help = "With --static, only pre-render routes with `rendering.prerender` (used by --prerender)",
        }),
    },
};

pub const @"app.asset": Command = .{
    .name = .asset,
    .help_short = "Install a static client asset (optionally upsert its manifest injection)",
    .named_args = &.{
        Argument.init(.outdir, []const u8, .{
            .default_value = "",
            .short = 'o',
            .help = "Directory to write the installed asset into",
        }),
        Argument.init(.@"href-stem", []const u8, .{
            .default_value = "",
            .hidden = true,
            .help = "Public URL stem (required when updating a manifest)",
        }),
        Argument.init(.manifest, []const u8, .{
            .default_value = "",
            .help = "Input app manifest path (omit for copy-only install)",
        }),
        Argument.init(.@"manifest-out", []const u8, .{
            .default_value = "",
            .hidden = true,
            .help = "Output app manifest path (required with --manifest)",
        }),
        Argument.init(.@"file-stem", []const u8, .{
            .default_value = "app",
            .help = "Installed filename stem (default: app)",
        }),
        Argument.init(.ext, []const u8, .{
            .default_value = ".wasm",
            .help = "Installed filename extension (default: .wasm)",
        }),
        Argument.init(.kind, []const u8, .{
            .default_value = "wasmlink",
            .help = "Manifest injection kind: wasmlink or script",
        }),
        Argument.init(.clean, bool, .{
            .default_value = false,
            .help = "Delete the output directory before installing",
        }),
        Argument.init(.hash, bool, .{
            .default_value = true,
            .help = "Content-hash the installed filename (--no-hash for stable filenames in dev rebuilds)",
        }),
    },
    .positional_args = &.{
        Argument.init(.src, []const u8, .{
            .help = "Source asset path (.wasm / .js)",
        }),
    },
};

pub const app: Command = .{
    .name = .app,
    .help_short = "App build helpers",
    .subcommands = &.{
        @"app.asset",
    },
};

pub const transpile: Command = .{
    .name = .transpile,
    .help_short = "Transpile a .zx file or directory to zig source code.",
    .named_args = &.{
        Argument.init(.outdir, []const u8, .{
            .default_value = ".zx",
            .short = 'o',
            .help = "Output directory",
        }),
        Argument.init(.@"copy-only", bool, .{
            .default_value = false,
            .help = "Copy only the files to the output directory",
        }),
        flags.verbose,
        Argument.init(.map, []const u8, .{
            .default_value = "none",
            .help = "Generate source map",
        }),
        Argument.init(.@"dep-file", []const u8, .{
            .default_value = "",
            .hidden = true,
            .help = "Write a Make-format dependency file listing all transpiled input files",
        }),
        Argument.init(.@"cache-dir", []const u8, .{
            .default_value = "",
            .hidden = true,
            .help = "Persistent transpile cache directory (mtime + Transpile.shape; survives zig-cache invalidation)",
        }),
        Argument.init(.roots, []const u8, .{
            .default_value = "",
            .hidden = true,
            .help = "File listing route files (one per line, relative to the path) to transpile from; default: scan pages/ and routes/",
        }),
        Argument.init(.@"base-path", []const u8, .{
            .default_value = "",
            .help = "Base path for the application (e.g., /test)",
        }),
        Argument.init(.manifest, []const u8, .{
            .default_value = "",
            .hidden = true,
            .help = "Centralized app manifest path (zig-out/manifest/app.zon)",
        }),
        Argument.init(.@"build-injections", []const u8, .{
            .default_value = "",
            .hidden = true,
            .help = "Build-managed injections to merge into the app manifest",
        }),
        Argument.init(.@"exe-path", []const u8, .{
            .default_value = "",
            .hidden = true,
            .help = "Path to the executable",
        }),
        Argument.init(.@"client-dir", []const u8, .{
            .default_value = "",
            .hidden = true,
            .help = "Directory of module client component lists",
        }),
    },
    .positional_args = &.{
        Argument.init(.path, []const u8, .{
            .help = "Path to .zx file or directory",
        }),
    },
};

pub const fmt: Command = .{
    .name = .fmt,
    .help_short = "Format .zx files or directories.",
    .named_args = &.{
        Argument.init(.stdin, bool, .{
            .default_value = false,
            .help = "Read from stdin and write formatted output to stdout",
        }),
        Argument.init(.stdout, bool, .{
            .default_value = false,
            .help = "Write formatted output to stdout instead of disk",
        }),
    },
    .positional_args = &.{
        Argument.init(.paths, []const []const u8, .{
            .count = .unlimited,
            .default_value = &.{},
            .help = "Paths to .zx files or directories",
        }),
    },
};

pub const diagnose: Command = .{
    .name = .diagnose,
    .help_short = "Pretty-print zig build errors read from stdin",
    .help =
    \\Reads `zig build` error output from stdin, remaps generated `.zig`
    \\locations back to their `.zx` sources and pretty-prints them.
    \\
    \\Example: zig build 2>&1 | zx diagnose
    \\
    ,
    .hidden = true,
};

pub const EnvFormat = enum { zon, json };

pub const env: Command = .{
    .name = .env,
    .help_short = "Print Ziex environment information",
    .help =
    \\Prints resolved Ziex paths and environment values for the current process
    \\(same style as `zig env` when --format=zon).
    \\
    \\When run via `zig build zx -- env`, the build step injects project-local
    \\paths (such as ZIEX_MODULE_PATH and ZIEX_ZIG_PATH) into the process environment.
    \\
    ,
    .named_args = &.{
        Argument.init(.format, EnvFormat, .{
            .default_value = .zon,
            .help = "Output format: zon (default) or json",
        }),
    },
};

pub const lsp: Command = .{
    .name = .lsp,
    .help_short = "Start the Ziex language server",
    .help =
    \\Default: long-running stdio JSON-RPC language server.
    \\
    \\Pass --message one or more times to process JSON-RPC payloads and print
    \\NDJSON responses, then exit.
    \\
    \\The zx module path for `@import("zx")` is resolved from `--zx-module`,
    \\falling back to the ZIEX_MODULE_PATH environment variable.
    \\
    ,
    .named_args = &.{
        Argument.init(.message, []const []const u8, .{
            .count = .unlimited,
            .default_value = &.{},
            .short = 'm',
            .help = "JSON-RPC LSP message to process (repeatable; disables stdio mode)",
        }),
        Argument.init(.@"zx-module", []const u8, .{
            .default_value = "",
            .help = "Path to the zx module root (src/root.zig); overrides ZIEX_MODULE_PATH",
        }),
    },
};

pub const bundle: Command = .{
    .name = .bundle,
    .help_short = "Bundle the built app and its static assets for native deployment",
    .help =
    \\Copy the built app executable and its static assets into a deployable directory.
    \\Run `zx build` first.
    \\
    ,
    .named_args = &.{
        Argument.init(.outdir, []const u8, .{
            .default_value = "bundle",
            .short = 'o',
            .help = "Output directory",
        }),
        flags.bin_path,
        flags.install_prefix,
    },
};

pub const update: Command = .{
    .name = .update,
    .help_short = "Update the version of the Ziex dependency",
    .named_args = &.{
        Argument.init(.version, []const u8, .{
            .default_value = "latest",
            .help = "Version to update to",
        }),
        Argument.init(.canary, bool, .{
            .default_value = false,
            .help = "Update to the latest commit on the main branch instead of the latest release",
        }),
        flags.zig_path,
    },
};

pub const upgrade: Command = .{
    .name = .upgrade,
    .help_short = "Upgrade the version of the Ziex CLI",
    .named_args = &.{
        Argument.init(.version, []const u8, .{
            .default_value = "latest",
            .help = "Version to upgrade to",
        }),
    },
};

pub const commands: []const Command = &.{
    version,
    init,
    app,
    dev,
    serve,
    build,
    transpile,
    fmt,
    diagnose,
    env,
    lsp,
    bundle,
    update,
    upgrade,
};

const os_commands: []const Command = switch (builtin.os.tag) {
    .wasi, .freestanding => &.{ version, dev, transpile, fmt, diagnose, lsp },
    else => commands,
};

pub const root_command: Command = .{
    .name = .zx,
    .help =
    \\Ziex is a framework for building web applications with Zig.
    \\
    ,
    .help_short = "Ziex framework CLI",
    .named_args = &.{
        Argument.init(.version, bool, .{
            .default_value = false,
            .short = 'V',
            .help = "Print the CLI version and exit",
        }),
    },
    .subcommands = os_commands,
};
