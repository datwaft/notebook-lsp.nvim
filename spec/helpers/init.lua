-- Loaded by busted before any spec (see .busted).

-- `nvim -l` starts without filetype detection, and vim.lsp.enable() attaches on FileType.
vim.cmd("filetype on")

-- Load the plugin the way Neovim does at startup, from the runtimepath
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd.runtime("plugin/notebook_lsp.lua")
