/// Apply a packed DomCmd buffer written in WASM linear memory.
pub extern "__zx" fn _flush(ptr: [*]const u8, len: usize) void;

// Async / timer
pub extern "__zx" fn _setTimeout(callback_id: u64, delay_ms: u32) void;
pub extern "__zx" fn _setInterval(callback_id: u64, interval_ms: u32) void;
pub extern "__zx" fn _clearInterval(callback_id: u64) void;

// WebSocket
pub extern "__zx" fn _wsConnect(ws_id: u64, url_ptr: [*]const u8, url_len: usize, protocols_ptr: [*]const u8, protocols_len: usize) void;
pub extern "__zx" fn _wsSend(ws_id: u64, data_ptr: [*]const u8, data_len: usize, is_binary: u8) void;
pub extern "__zx" fn _wsClose(ws_id: u64, code: u16, reason_ptr: [*]const u8, reason_len: usize) void;

// Location
/// Write window.location.href into buf. Returns the number of bytes written.
pub extern "__zx" fn _getLocationHref(buf: [*]u8, buf_len: usize) usize;

/// Gets form entries `[k1,v1,...]` from JS and writes the pointer to `out_ptr`.
pub extern "__zx" fn _getFormData(event_ref: u64, out_ptr: *[*]u8) usize;

/// Submits a form with action identity
pub extern "__zx" fn _submitFormAction(vnode_id: u64, action_id: u32) void;

/// Submits a form with component states in __$states field
pub extern "__zx" fn _submitFormActionAsync(
    vnode_id: u64,
    action_id: u32,
    states_ptr: [*]const u8,
    states_len: usize,
    fetch_id: u64,
) void;

/// Call `HTMLFormElement.reset()` on the form registered for `vnode_id`.
pub extern "__zx" fn _formReset(vnode_id: u64) void;

// Logging
/// Forward a log message to the JS console. level: 0=error, 1=warn, 2=info, 3=debug
pub extern "__zx" fn _log(level: u8, ptr: [*]const u8, len: usize) void;

// Event handlers
/// Register a delegated event handler for a vnode.
pub extern "__zx" fn _registerEventHandler(vnode_id: u64, event_type_id: u8) void;

/// Clear all delegated event handlers for a vnode.
pub extern "__zx" fn _clearEventHandlers(vnode_id: u64) void;

// Fetch
pub extern "__zx" fn _fetchAsync(
    url_ptr: [*]const u8,
    url_len: usize,
    method_ptr: [*]const u8,
    method_len: usize,
    headers_ptr: [*]const u8,
    headers_len: usize,
    body_ptr: [*]const u8,
    body_len: usize,
    timeout_ms: u32,
    redirect: u32,
    callback_id: u64,
) void;
