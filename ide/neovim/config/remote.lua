-- ~/.config/nvim/lua/plugins/zx.lua
return {
    "ziex-dev/ziex",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    lazy = false,
    config = function(plugin)
        vim.opt.runtimepath:prepend(plugin.dir .. "/ide/neovim")
        vim.cmd("runtime! plugin/zx.lua")
        require("zx").setup()
    end,
}
