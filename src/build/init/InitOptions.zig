/// Configuration options for initializing a Ziex project in your build.zig.
///
/// This struct provides comprehensive control over how Ziex transpiles and builds
/// your website, including CLI configuration, experimental features, and plugin integration.
///
/// ## Usage Example
/// ```zig
/// const ziex_options: ziex.InitOptions = .{
///     .cli = .{
///         .steps = .{
///             .dev = "dev",
///             .serve = "serve",
///         },
///     },
/// };
/// _ = try ziex.init(b, exe, ziex_options);
/// ```
const InitOptions = @This();

const std = @import("std");

const LazyPath = std.Build.LazyPath;

/// Configuration for the Ziex CLI executable and build steps.
pub const CliOptions = struct {
    /// Custom names for Ziex build steps.
    ///
    /// Configure which Zig build steps to create and what names to give them.
    /// Set any step to `null` to disable it.
    pub const Steps = struct {
        /// Step name for development mode with hot-reload (default: null/disabled)
        dev: ?[]const u8 = null,
        /// Step name for running the site in production build without hot-reload (default: "serve")
        serve: ?[]const u8 = null,
        /// Step name for building a static site, runs `zx build --static` (default: null/disabled)
        static: ?[]const u8 = null,
        /// Step name for bundling the website (default: null/disabled)
        bundle: ?[]const u8 = null,

        pub const default: Steps = .{ .dev = "dev", .serve = "serve" };
    };

    /// Path to the Ziex CLI executable.
    ///
    /// - If set: Uses the specified path (overrides PATH lookup and `build`)
    /// - If `null` and `build` is `null`: Prefer a matching `zx` on PATH, else
    ///   build the CLI from the Ziex dependency source
    /// - If `null` and `.build = .enabled`: Always build from source (skip PATH)
    path: ?LazyPath = null,

    /// Build the `zx` CLI from the Ziex dependency source instead of using a
    /// matching `zx` on PATH.
    ///
    /// `null` (default) prefers PATH when the version matches; `.build = .enabled`
    /// always compiles the host CLI (similar to `client.bindings.build`).
    /// Ignored when `path` is set.
    build: ?BuildOptions = null,

    /// Path to the Zig executable passed to the Ziex CLI as `--zig-path`.
    ///
    /// - If `null`: Uses `b.graph.zig_exe`
    /// - Otherwise: Uses the specified path
    zig_path: ?[]const u8 = null,

    /// Configuration for which build steps to create.
    ///
    /// If `null`, only the default "serve" step will be created.
    steps: ?Steps = .default,

    /// Optimize mode for the Ziex CLI executable.
    optimize: ?std.lang.Optimize = .fast,

    /// Log level for the Ziex CLI executable.
    log_level: ?std.log.Level = null,

    pub const BuildOptions = struct {
        pub const enabled: BuildOptions = .{};
    };
};

/// Configuration for the Ziex app directory.
pub const AppOptions = struct {
    /// Native HTTP server settings (ignored on WASI / client builds).
    pub const Server = struct {
        pub const Backend = enum {
            /// Debug builds use `std`; release builds use `httpz`.
            auto,
            /// `std.http.Server` + fixed worker pool (better SafeAllocator / leak reports).
            std,
            /// httpz (production throughput).
            httpz,
        };

        /// HTTP server transport backend. Defaults to `.auto`.
        backend: Backend = .auto,
    };

    pub const FeatureOptions = struct {
        /// Embedded SQLite database, exposed at runtime as `zx.db`.
        pub const SqliteOptions = struct {
            pub const SqliteServerOptions = struct {
                pub const enabled: SqliteServerOptions = .{};
            };
            // In the browser, stored at `db/default.db` on the `fs` feature's file system (implied).
            pub const SqliteClientOptions = struct {
                pub const enabled: SqliteClientOptions = .{};
            };
            // For `zx.worker` modules: built into client wasm without opening `zx.db` on the page.
            pub const SqliteWorkerOptions = struct {
                pub const enabled: SqliteWorkerOptions = .{};
            };
            pub const enabled: SqliteOptions = .{ .server = .enabled };

            server: ?SqliteServerOptions = null,
            client: ?SqliteClientOptions = null,
            worker: ?SqliteWorkerOptions = null,
        };

        /// Enable Postgres database client, available through `zx.Db.Postgres`.
        pub const PostgresOptions = struct {
            pub const PostgresServerOptions = struct {
                pub const enabled: PostgresServerOptions = .{};
            };
            pub const enabled: PostgresOptions = .{ .server = .enabled };

            server: ?PostgresServerOptions = null,
        };

        /// Enable MySQL/MariaDB database client, available through `zx.Db.Mysql`.
        pub const MysqlOptions = struct {
            pub const MysqlServerOptions = struct {
                pub const enabled: MysqlServerOptions = .{};
            };
            pub const enabled: MysqlOptions = .{ .server = .enabled };

            server: ?MysqlServerOptions = null,
        };

        /// Filesystem-backed key/value store, exposed at runtime as `zx.kv`.
        pub const KvOptions = struct {
            pub const KvServerOptions = struct {
                pub const enabled: KvServerOptions = .{};
            };
            pub const KvClientOptions = struct {
                pub const enabled: KvClientOptions = .{};
            };
            pub const enabled: KvOptions = .{ .server = .enabled, .client = .enabled };

            server: ?KvServerOptions = null,
            client: ?KvClientOptions = null,
        };

        // `std.Io.Dir`/`File` in the browser, persisted to OPFS. `Dir.cwd()` is its root.
        pub const FsOptions = struct {
            pub const FsClientOptions = struct {
                pub const enabled: FsClientOptions = .{};
            };
            pub const enabled: FsOptions = .{ .client = .enabled };

            client: ?FsClientOptions = null,
        };

        /// Filesystem-backed cache (used by component-level caching),
        /// exposed at runtime as `zx.cache`.
        pub const CacheOptions = struct {
            pub const CacheServerOptions = struct {
                pub const enabled: CacheServerOptions = .{};
            };
            pub const enabled: CacheOptions = .{ .server = .enabled };

            server: ?CacheServerOptions = null,
        };

        // `zx.ai`. Only the provider is a build option; key and base URL come from
        // env (`OPENAI_API_KEY`, `OPENAI_BASE_URL`, or the `ANTHROPIC_*` equivalents).
        // The model is passed per call.
        pub const AiOptions = struct {
            pub const Provider = enum { openai, anthropic };
            pub const AiServerOptions = struct {
                pub const enabled: AiServerOptions = .{};

                provider: Provider = .openai,
            };
            pub const enabled: AiOptions = .{ .server = .enabled };

            server: ?AiServerOptions = null,
        };

        pub const FlagOptions = struct {
            pub const Provider = enum { ofrep, flagship, kv };
            pub const FlagServerOptions = struct {
                pub const enabled: FlagServerOptions = .{};

                provider: Provider = .ofrep,
            };
            pub const enabled: FlagOptions = .{ .server = .enabled };

            server: ?FlagServerOptions = null,
        };

        pub const EmailOptions = struct {
            pub const Provider = enum { resend, smtp, wasm, memory };
            pub const EmailServerOptions = struct {
                pub const enabled: EmailServerOptions = .{};

                provider: Provider = .resend,
            };
            pub const enabled: EmailOptions = .{ .server = .enabled };

            server: ?EmailServerOptions = null,
        };

        pub const BucketOptions = struct {
            pub const Provider = enum { fs, wasm, s3 };
            pub const BucketServerOptions = struct {
                pub const enabled: BucketServerOptions = .{};

                provider: ?Provider = null,
            };
            pub const enabled: BucketOptions = .{ .server = .enabled };

            server: ?BucketServerOptions = null,
        };

        pub const default = FeatureOptions{};

        sqlite: ?SqliteOptions = null,
        postgres: ?PostgresOptions = null,
        mysql: ?MysqlOptions = null,
        kv: ?KvOptions = null,
        cache: ?CacheOptions = null,
        fs: ?FsOptions = null,
        ai: ?AiOptions = null,
        flag: ?FlagOptions = null,
        email: ?EmailOptions = null,
        bucket: ?BucketOptions = null,
    };

    /// Path to the Ziex app source directory.
    ///
    /// This directory should contain your `.zx` template files, layouts,
    /// and other app assets. Defaults to "app" if not specified in InitOptions.
    path: ?LazyPath = null,

    /// Base path for all routes in your app (e.g. if your app is served from "/blog", set this to "/blog").
    ///
    /// This will be used to prefix all route URLs and asset paths in your app.
    /// If `null`, defaults to root path ("/").
    base_path: ?[]const u8 = null,

    /// HTTP server backend configuration.
    server: Server = .{},

    /// Features that can be optionally enabled
    features: FeatureOptions = .default,

    client: ClientOptions = .default,
};

pub const ClientOptions = struct {
    pub const WasmOptions = struct {
        pub const default: WasmOptions = .{ .link = true };
        pub const disabled: WasmOptions = .{ .link = false };

        /// Optimize mode for the client wasm module and executable.
        ///
        /// When `null`, inherits the app executable's optimize mode.
        optimize: ?std.lang.Optimize = null,
        link: bool = true,
    };
    /// Client-side JS bindings (`ziex` / wasm init script).
    pub const BindingsOptions = struct {
        pub const default: BindingsOptions = .{};
        pub const disabled: BindingsOptions = .{ .link = false };

        link: bool = true,

        /// URL for the client JS bindings script.
        ///
        /// When `null`, Ziex installs and injects the default hashed asset
        /// (`/assets/_/app.js` or `/assets/_/app.dev.js`).
        href: ?[]const u8 = null,

        /// Install the JS bindings package under `zig-out/<subdir>`.
        ///
        /// Ziex auto-injects bindings at runtime for normal server deployments,
        /// so this is `null` (no install) by default. Set it for platforms that
        /// need the package on disk (e.g. Vercel).
        install_subdir: ?[]const u8 = null,

        /// Build bindings from TypeScript (`pkg/ziex` via esbuild) instead of
        /// the prebuilt npm package. When set, enabled `AppOptions.features`
        /// are passed as esbuild defines so unused binding code is excluded
        /// from the bundle.
        ///
        /// `null` (default) uses the prebuilt package; `.build = .enabled`
        /// builds from source (`-Dfrom-source=true`). Additional fields
        /// (e.g. optimize) may be added later.
        build: ?BuildOptions = null,

        pub const BuildOptions = struct {
            pub const enabled: BuildOptions = .{};
        };
    };

    pub const default: ClientOptions = .{};
    pub const disabled: ClientOptions = .{ .bindings = .disabled, .wasm = .disabled };

    bindings: BindingsOptions = .default,
    wasm: WasmOptions = .default,
};

/// Experimental features that may change in future versions.
const ExperimentalOptions = struct {};

/// App directory configuration.
///
/// If `null`, defaults to `app` directory in your project root.
/// Override this to use a custom app source directory.
app: ?AppOptions = null,

/// Ziex CLI configuration.
///
/// Controls which Ziex CLI executable to use and which build steps to create.
/// If `null`, uses default configuration with Ziex CLI from dependency source.
cli: CliOptions = .{},

/// Experimental features configuration.
///
/// Enable cutting-edge Ziex features that may have breaking changes in the future.
/// If `null`, all experimental features are disabled.
experimental: ?ExperimentalOptions = null,

/// Build-time output location for compiled assets and public files.
///
/// This controls only where the build *emits* assets. The location the
/// *running app* serves static files and stores data from is controlled at
/// runtime by the `ZIEX_STATIC_DIR` and `ZIEX_DATA_DIR` environment variables.
///
/// If `null`, defaults to `zig-out/static` in your project root.
static_path: ?LazyPath = null,

/// App version string (reserved for build metadata; asset URLs are content-hashed).
///
/// ```zig
/// .version = @import("build.zig.zon").version,
/// ```
version: ?[]const u8 = null,
