local M = {}

M.config = {
  -- Command for the language server; nil resolves `zx lsp`, then `zig build zx -- lsp`.
  cmd = nil,
  -- ZLS options, sent as the `zls` settings section.
  zls_settings = {},
  inlay_hints = true,
  -- Build missing parsers with the tree-sitter CLI on first use.
  auto_install = true,
  keymaps = true,
}

local configured = false
local warned = false
local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local repo_dir = vim.fn.fnamemodify(plugin_dir, ":h:h")
local parser_dir = vim.fn.stdpath("data") .. "/site/parser"

local grammars = {
  zx = "pkg/tree-sitter-zx",
  mdzx = "pkg/tree-sitter-mdzx",
  mdzx_inline = "pkg/tree-sitter-mdzx/tree-sitter-mdzx-inline",
}

local function parser_path(lang)
  return parser_dir .. "/" .. lang .. ".so"
end

function M.install_parsers(force)
  if vim.fn.executable("tree-sitter") == 0 then
    vim.notify("zx: install the tree-sitter CLI to build parsers", vim.log.levels.WARN)
    return false
  end
  vim.fn.mkdir(parser_dir, "p")
  local ok = true
  for lang, dir in pairs(grammars) do
    if force or vim.fn.filereadable(parser_path(lang)) == 0 then
      local out = vim.fn.system({ "tree-sitter", "build", "--output", parser_path(lang), repo_dir .. "/" .. dir })
      if vim.v.shell_error ~= 0 then
        vim.notify("zx: building " .. lang .. " parser failed\n" .. out, vim.log.levels.ERROR)
        ok = false
      else
        -- Load now; runtime parser lookups are cached until restart.
        pcall(vim.treesitter.language.add, lang, { path = parser_path(lang) })
      end
    end
  end
  if ok then vim.notify("zx: parsers installed", vim.log.levels.INFO) end
  return ok
end

local function parsers_missing()
  for lang in pairs(grammars) do
    if vim.fn.filereadable(parser_path(lang)) == 0 then return true end
  end
  return false
end

-- Prefers an installed `zx lsp`; otherwise builds and runs it from the
-- project's build.zig.
local function resolve_cmd(root_dir)
  if M.config.cmd then return M.config.cmd end
  if vim.fn.executable("zx") == 1 then return { "zx", "lsp" } end
  if vim.fn.executable("zig") == 1 then
    local cmd = { "zig", "build" }
    if root_dir then vim.list_extend(cmd, { "--build-file", root_dir .. "/build.zig" }) end
    vim.list_extend(cmd, { "-Dziex-lsp=true", "--release=fast", "zx", "--", "lsp" })
    return cmd
  end
  return nil
end

local function setup_lsp()
  vim.lsp.config("zxls", {
    cmd = function(dispatchers, config)
      return vim.lsp.rpc.start(resolve_cmd(config.root_dir), dispatchers, { cwd = config.root_dir })
    end,
    filetypes = { "zx", "mdzx" },
    -- Nearest build.zig, so a Ziex subproject in a monorepo is its own root.
    root_dir = function(bufnr, on_dir)
      local root = vim.fs.root(bufnr, "build.zig") or vim.fs.root(bufnr, ".git")
      if resolve_cmd(root) then
        on_dir(root)
      elseif not warned then
        warned = true
        vim.notify("zx: neither zx nor zig found; LSP disabled", vim.log.levels.WARN)
      end
    end,
    settings = { zls = M.config.zls_settings },
    on_attach = function(client, bufnr)
      if M.config.inlay_hints and client:supports_method("textDocument/inlayHint") then
        vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
      end
    end,
  })
  vim.lsp.enable("zxls")
end

local function setup_icons()
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then return end
  local icon = { icon = "zx ", color = "#4ade80", cterm_color = "114" }
  devicons.set_icon({
    zx = vim.tbl_extend("force", icon, { name = "Zx" }),
    mdzx = vim.tbl_extend("force", icon, { name = "Mdzx" }),
  })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  configured = true
  setup_lsp()
  vim.schedule(setup_icons)
end

-- Called from the FileType autocmd; sets up with defaults when `setup` was not called.
function M.attach(bufnr, lang)
  if not configured then
    M.setup()
    -- Before VimEnter, `vim.lsp.enable` does not replay FileType for this buffer.
    if vim.v.vim_did_enter == 0 then
      vim.api.nvim_exec_autocmds("FileType", { group = "nvim.lsp.enable", buffer = bufnr, modeline = false })
    end
  end
  if M.config.auto_install and parsers_missing() then M.install_parsers(false) end
  pcall(vim.treesitter.start, bufnr, lang)
  if M.config.keymaps then
    vim.keymap.set("n", "<leader>zh", "<cmd>Inspect<CR>", { buffer = bufnr, desc = "zx: show highlight" })
    vim.keymap.set("n", "<leader>zt", "<cmd>InspectTree<CR>", { buffer = bufnr, desc = "zx: inspect tree" })
  end
end

function M.restart_lsp()
  local clients = vim.lsp.get_clients({ name = "zxls" })
  for _, client in ipairs(clients) do client:stop() end
  vim.defer_fn(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local ft = vim.bo[buf].filetype
      if vim.api.nvim_buf_is_loaded(buf) and (ft == "zx" or ft == "mdzx") then
        vim.api.nvim_exec_autocmds("FileType", { buffer = buf, modeline = false })
      end
    end
  end, 500)
end

return M
