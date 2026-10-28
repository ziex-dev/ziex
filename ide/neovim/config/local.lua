-- ~/.config/nvim/lua/plugins/zx.lua
local dir = vim.fn.expand("~/Projects/ziex-dev/ziex")
return {
    dir = dir,
    name = "zx",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    lazy = false,
    config = function()
        vim.opt.runtimepath:prepend(dir .. "/ide/neovim")
        vim.cmd("runtime! plugin/zx.lua")
        require("zx").setup()
    end,
}
