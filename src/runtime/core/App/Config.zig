server: ServerConfig = .{},
cache: CacheConfig = .{},

datadir: ?[]const u8 = null,
staticdir: ?[]const u8 = null,

pub const CacheConfig = struct {
    max_size: u32 = 1000,
    default_ttl: u32 = 10,
};

pub const ServerConfig = struct {
    /// Deprecated: This needs to be configured via the `PORT` env variable. Will be removed in a future release.
    port: ?u16 = null,
    /// Deprecated: This needs to be configured via the `HOST` env variable. Will be removed in a future release.
    address: ?[]const u8 = null,
    unix_path: ?[]const u8 = null,
    workers: Worker = .{},
    request: Request = .{},
    response: Response = .{},
    timeout: Timeout = .{},
    thread_pool: ThreadPool = .{},
    websocket: Websocket = .{},

    pub const ThreadPool = struct {
        /// `null` resolves to `std.Thread.getCpuCount()` at App init
        count: ?u16 = null,
        /// Pending jobs before accept/enqueue applies backpressure.
        backlog: u32 = 500,
        buffer_size: usize = 32_768,
    };

    pub const Worker = struct {
        count: u16 = 1,
        max_conn: u16 = 8_192,
        min_conn: u16 = 64,
        large_buffer_count: u16 = 16,
        large_buffer_size: u32 = 65536,
        retain_allocated_bytes: usize = 8192,
    };

    pub const Request = struct {
        lazy_read_size: ?usize = null,
        max_body_size: usize = 1_048_576,
        buffer_size: usize = 4_096,
        max_header_count: usize = 32,
        max_param_count: usize = 10,
        max_query_count: usize = 32,
        max_form_count: usize = 20,
        max_multiform_count: usize = 20,
    };

    pub const Response = struct {
        max_header_count: usize = 16,
    };

    pub const Timeout = struct {
        request: ?u32 = null,
        keepalive: ?u32 = null,
        request_count: ?usize = null,
    };

    pub const Websocket = struct {
        max_message_size: ?usize = null,
        small_buffer_size: ?usize = null,
        small_buffer_pool: ?usize = null,
        large_buffer_size: ?usize = null,
        large_buffer_pool: ?u16 = null,
        compression: bool = false,
        compression_retain_writer: bool = true,
        compression_write_treshold: ?usize = null,
    };
};
