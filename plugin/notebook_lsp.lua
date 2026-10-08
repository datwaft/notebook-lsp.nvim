-- notebook-lsp.nvim: extends the configs of the language servers known to
-- support the LSP notebook protocol to jupytext Markdown notebooks. Nothing to
-- set up: enabling those servers with vim.lsp.enable() is enough.
if vim.g.loaded_notebook_lsp then
  return
end
vim.g.loaded_notebook_lsp = true

-- Their filetypes as nvim-lspconfig configures them, which the extended
-- configs' filetypes replace
local servers = {
  basedpyright = { "python" },
  pyright = { "python" },
  ruff = { "python" },
  ty = { "python" },
}

for name, filetypes in pairs(servers) do
  require("notebook_lsp").extend(name, filetypes)
end
