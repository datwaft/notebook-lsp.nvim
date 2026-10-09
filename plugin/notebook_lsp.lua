-- notebook-lsp.nvim: extends the configs of the language servers known to
-- support the LSP notebook protocol to jupytext Markdown notebooks. Nothing to
-- set up: enabling those servers with vim.lsp.enable() is enough.
if vim.g.loaded_notebook_lsp then
  return
end

-- Their filetypes as nvim-lspconfig configures them, which the extended
-- configs' filetypes replace
local servers = {
  basedpyright = { "python" },
  pyright = { "python" },
  ruff = { "python" },
  ty = { "python" },
}

-- vim.g.notebook_lsp.servers adds servers (or sets their filetypes), and
-- leaves out those set to false
vim.validate("vim.g.notebook_lsp", vim.g.notebook_lsp, "table", true)
local options = vim.g.notebook_lsp or {}
for key in pairs(options) do
  assert(key == "servers", ("notebook-lsp: unknown option vim.g.notebook_lsp.%s"):format(key))
end
vim.validate("vim.g.notebook_lsp.servers", options.servers, "table", true)
for name, filetypes in pairs(options.servers or {}) do
  assert(type(name) == "string", ("notebook-lsp: vim.g.notebook_lsp.servers has %s for a server name"):format(name))
  vim.validate(("vim.g.notebook_lsp.servers.%s"):format(name), filetypes, function(value)
    if value == false then
      return true
    end
    if not vim.islist(value) or #value == 0 then
      return false
    end
    for _, filetype in ipairs(value) do
      if type(filetype) ~= "string" then
        return false
      end
    end
    return true
  end, "a list of filetypes, or false")
  servers[name] = filetypes or nil
end

-- Only once the options are valid: sourcing the plugin again after fixing them loads it
vim.g.loaded_notebook_lsp = true
for name, filetypes in pairs(servers) do
  require("notebook_lsp").extend(name, filetypes)
end
