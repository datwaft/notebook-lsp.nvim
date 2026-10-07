-- notebook-lsp.nvim: LSP for jupytext Markdown notebooks, through the LSP
-- notebook protocol (notebookDocument/*).
local M = {}

---@class notebook_lsp.Opts
---@field servers string[] names of `vim.lsp.config` entries that should also serve notebooks

--- Extends existing `vim.lsp.config` entries so they also attach to jupytext
--- Markdown notebooks whose kernel language is one of their filetypes.
---@param opts notebook_lsp.Opts
function M.setup(opts)
  error("notebook-lsp: setup() is not implemented yet")
end

return M
