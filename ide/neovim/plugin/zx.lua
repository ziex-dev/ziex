if vim.g.loaded_zx then return end
vim.g.loaded_zx = true

vim.filetype.add({ extension = { zx = "zx", mdzx = "mdzx" } })
vim.treesitter.language.register("zx", "zx")
vim.treesitter.language.register("mdzx", "mdzx")

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("zx", { clear = true }),
  pattern = { "zx", "mdzx" },
  callback = function(args)
    require("zx").attach(args.buf, args.match)
  end,
})

vim.api.nvim_create_user_command("ZxInstallParser", function()
  require("zx").install_parsers(true)
end, { desc = "Build the zx and mdzx tree-sitter parsers" })

vim.api.nvim_create_user_command("ZxLspRestart", function()
  require("zx").restart_lsp()
end, { desc = "Restart the zx language server" })
