-- notebook-lsp.nvim: LSP for jupytext Markdown notebooks, through the LSP
-- notebook protocol (notebookDocument/*).
--
-- Servers extended to notebooks also attach to jupytext notebooks in their
-- language, through the same clients .py files use: Neovim attaches them, and
-- the plugin translates what concerns notebook buffers on the client itself.
-- Everything else passes through untouched.
local jupytext = require("notebook_lsp.jupytext")

local M = {}

-- Neovim's filetype for kernel languages whose jupytext name differs from it
local FILETYPES = { R = "r", ["c++"] = "cpp", csharp = "cs" }

---@class (private) notebook_lsp.Notebook
---@field bufnr integer
---@field filetype string Neovim's filetype for the kernel's language

--- Notebook buffers, by the URI Neovim sends their messages with.
---@type table<string, notebook_lsp.Notebook>
local notebooks = {}

--- Clients whose server can't sync these notebooks, by client id: the URIs of
--- the notebooks being detached from them.
---@type table<integer, table<string, true>>
local rejected = {}

--- Whether the server syncs notebooks whose code cells are in `filetype`.
---@param client vim.lsp.Client
---@param filetype string
local function syncs_notebooks(client, filetype)
  local sync = client.server_capabilities.notebookDocumentSync
  for _, selector in ipairs(sync and sync.notebookSelector or {}) do
    if selector.cells == nil then
      return true
    end
    for _, cell in ipairs(selector.cells) do
      if cell.language == filetype then
        return true
      end
    end
  end
  return false
end

--- Puts the plugin between `client` and its server, once per client. Messages
--- about other documents pass through as they are.
---@param client vim.lsp.Client
local function intercept(client)
  if rejected[client.id] then
    return
  end
  local rejections = {} ---@type table<string, true>
  rejected[client.id] = rejections
  local rpc = client.rpc
  client.rpc = setmetatable({
    notify = function(method, params)
      local document = type(params) == "table" and params.textDocument or nil
      local uri = document and document.uri ---@type string?
      local notebook = uri and notebooks[uri]
      if uri and notebook then
        -- Neovim opens an attached buffer once the server is initialized, which
        -- is when the server tells whether it syncs notebooks
        if method == "textDocument/didOpen" and not syncs_notebooks(client, notebook.filetype) then
          rejections[uri] = true
          vim.schedule(function()
            vim.lsp.buf_detach_client(notebook.bufnr, client.id)
          end)
        end
        if rejections[uri] then
          if method == "textDocument/didClose" then
            rejections[uri] = nil
          end
          return true
        end
      end
      return rpc.notify(method, params)
    end,
  }, { __index = rpc })
end

--- Extends the `vim.lsp.config` named `name` to also attach to jupytext
--- Markdown notebooks whose kernel's language is one of `filetypes`. It sets
--- the config's `filetypes`, which replaces the server's own list, and its
--- `root_dir`: notebooks don't attach if the user's config sets either.
---@param name string
---@param filetypes string[] the server's own filetypes
function M.extend(name, filetypes)
  vim.lsp.config(name, {
    filetypes = vim.list_extend(vim.deepcopy(filetypes), { "markdown" }),

    -- Lets notebooks in the server's language through, and decides no root: Neovim
    -- then uses the config's root_markers, as it does without a root_dir
    root_dir = function(bufnr, on_dir)
      if vim.bo[bufnr].filetype ~= "markdown" then
        on_dir(nil)
        return
      end
      local uri = vim.uri_from_bufnr(bufnr)
      local notebook = jupytext.read(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
      if not notebook then
        notebooks[uri] = nil
        return
      end
      local filetype = FILETYPES[notebook.language] or notebook.language
      if not vim.list_contains(filetypes, filetype) then
        return
      end

      notebooks[uri] = { bufnr = bufnr, filetype = filetype }
      -- Neovim opens the notebook as it attaches it, before LspAttach: the plugin
      -- must already be between the client and its server by then. So get the
      -- client Neovim will attach (or start it), for the root Neovim will give it
      local config = assert(vim.lsp.config[name])
      local root = config.root_markers and vim.fs.root(bufnr, config.root_markers)
      local client_id = vim.lsp.start(
        vim.tbl_extend("force", config, { root_dir = root }) --[[@as vim.lsp.ClientConfig]],
        { bufnr = bufnr, attach = false }
      )
      if client_id then
        intercept(assert(vim.lsp.get_client_by_id(client_id)))
      end
      on_dir(nil)
    end,

    capabilities = {
      notebookDocument = { synchronization = { dynamicRegistration = false, executionSummarySupport = false } },
    },
  })
end

return M
