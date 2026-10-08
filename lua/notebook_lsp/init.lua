-- notebook-lsp.nvim: LSP for jupytext Markdown notebooks, through the LSP
-- notebook protocol (notebookDocument/*).
--
-- Servers extended to notebooks also attach to jupytext notebooks in their
-- language, through the same clients .py files use: Neovim attaches them, and
-- the plugin translates what concerns notebook buffers on the client itself.
-- Everything else passes through untouched.
local jupytext = require("notebook_lsp.jupytext")
local Notebook = require("notebook_lsp.notebook")

local M = {}

-- Neovim's filetype for kernel languages whose jupytext name differs from it
local FILETYPES = { R = "r", ["c++"] = "cpp", csharp = "cs" }

-- NotebookCellKind.Code
local CODE = 2

--- Notebook buffers, by the URI Neovim sends their messages with.
---@type table<string, notebook_lsp.Notebook>
local notebooks = {}

--- Clients the plugin sits on, by id.
---@type table<integer, true>
local intercepted = {}

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

---@class (private) notebook_lsp.Synced what a server was told about a notebook
---@field version integer
---@field cells {id: integer, text: string, version: integer}[]

--- Puts the plugin between `client` and its server, once per client: Neovim's
--- messages about notebook buffers become notebookDocument/* messages, and
--- messages about other documents pass through as they are.
---@param client vim.lsp.Client
local function intercept(client)
  if intercepted[client.id] then
    return
  end
  intercepted[client.id] = true
  local rpc = client.rpc

  -- By the Markdown buffer's URI
  local rejected = {} ---@type table<string, true>
  local synced = {} ---@type table<string, notebook_lsp.Synced>

  ---@param notebook notebook_lsp.Notebook
  ---@param cell {id: integer, text: string, version: integer}
  local function cell_document(notebook, cell)
    return { uri = notebook:cell_uri(cell.id), languageId = notebook.filetype, version = cell.version, text = cell.text }
  end

  ---@param notebook notebook_lsp.Notebook
  local function open(notebook)
    local state = { version = 1, cells = {} }
    for _, cell in ipairs(notebook:read()) do
      table.insert(state.cells, { id = cell.id, text = cell.text, version = 1 })
    end
    synced[notebook.uri] = state
    return rpc.notify("notebookDocument/didOpen", {
      notebookDocument = {
        uri = notebook.notebook_uri,
        notebookType = "jupyter-notebook",
        version = state.version,
        cells = vim.tbl_map(function(cell)
          return { kind = CODE, document = notebook:cell_uri(cell.id) }
        end, state.cells),
      },
      cellTextDocuments = vim.tbl_map(function(cell)
        return cell_document(notebook, cell)
      end, state.cells),
    })
  end

  --- Tells the server how the cells changed since it was last told, if they did.
  ---@param notebook notebook_lsp.Notebook
  local function change(notebook)
    local state = assert(synced[notebook.uri], "notebook-lsp: a change to a notebook the server doesn't have open")
    local old, new = state.cells, notebook:read()

    -- The cells that differ, as one change to the array of cells: what is
    -- left between the cells that are the same at the start and at the end
    local first, old_last, new_last = 1, #old, #new
    while first <= old_last and first <= new_last and old[first].id == new[first].id do
      first = first + 1
    end
    while old_last >= first and new_last >= first and old[old_last].id == new[new_last].id do
      old_last, new_last = old_last - 1, new_last - 1
    end

    local before, inserted = {}, {} ---@type table<integer, {id: integer, text: string, version: integer}>, table<integer, true>
    for _, cell in ipairs(old) do
      before[cell.id] = cell
    end
    local structure
    if first <= old_last or first <= new_last then
      structure =
        { array = { start = first - 1, deleteCount = old_last - first + 1, cells = {} }, didOpen = {}, didClose = {} }
      for i = first, new_last do
        local cell = new[i]
        inserted[cell.id] = true
        table.insert(structure.array.cells, { kind = CODE, document = notebook:cell_uri(cell.id) })
        if not before[cell.id] then
          table.insert(structure.didOpen, cell_document(notebook, { id = cell.id, text = cell.text, version = 1 }))
        end
      end
      for i = first, old_last do
        if not inserted[old[i].id] then
          table.insert(structure.didClose, { uri = notebook:cell_uri(old[i].id) })
        end
      end
    end

    -- The new text of the cells that were already open
    local cells, text_content = {}, {}
    for _, cell in ipairs(new) do
      local known = before[cell.id]
      local version = known and known.version or 1
      if known and known.text ~= cell.text then
        version = version + 1
        table.insert(text_content, {
          document = { uri = notebook:cell_uri(cell.id), version = version },
          changes = { { text = cell.text } },
        })
      end
      table.insert(cells, { id = cell.id, text = cell.text, version = version })
    end
    state.cells = cells

    if not structure and #text_content == 0 then
      return true
    end
    state.version = state.version + 1
    return rpc.notify("notebookDocument/didChange", {
      notebookDocument = { uri = notebook.notebook_uri, version = state.version },
      change = { cells = { structure = structure, textContent = #text_content > 0 and text_content or nil } },
    })
  end

  ---@param notebook notebook_lsp.Notebook
  local function close(notebook)
    local state = assert(synced[notebook.uri], "notebook-lsp: closing a notebook the server doesn't have open")
    synced[notebook.uri] = nil
    return rpc.notify("notebookDocument/didClose", {
      notebookDocument = { uri = notebook.notebook_uri },
      cellTextDocuments = vim.tbl_map(function(cell)
        return { uri = notebook:cell_uri(cell.id) }
      end, state.cells),
    })
  end

  client.rpc = setmetatable({
    notify = function(method, params)
      local document = type(params) == "table" and params.textDocument or nil
      local uri = document and document.uri ---@type string?
      local notebook = uri and notebooks[uri]
      if not uri or not notebook then
        return rpc.notify(method, params)
      end

      -- Neovim opens an attached buffer once the server is initialized, which
      -- is when the server tells whether it syncs notebooks
      if method == "textDocument/didOpen" and not syncs_notebooks(client, notebook.filetype) then
        rejected[uri] = true
        vim.schedule(function()
          vim.lsp.buf_detach_client(notebook.bufnr, client.id)
        end)
      end
      if rejected[uri] then
        if method == "textDocument/didClose" then
          rejected[uri] = nil
        end
        return true
      end

      if method == "textDocument/didOpen" then
        return open(notebook)
      elseif method == "textDocument/didChange" then
        return change(notebook)
      elseif method == "textDocument/didSave" then
        return rpc.notify("notebookDocument/didSave", { notebookDocument = { uri = notebook.notebook_uri } })
      elseif method == "textDocument/didClose" then
        return close(notebook)
      end
      -- Nothing else about the Markdown file concerns the server
      return true
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
      local read = jupytext.read(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
      if not read then
        notebooks[uri] = nil
        return
      end
      local filetype = FILETYPES[read.language] or read.language
      if not vim.list_contains(filetypes, filetype) then
        return
      end

      -- One per buffer, whichever server lets it through first: its cells' ids
      -- are the same for every server
      local notebook = notebooks[uri]
      if not notebook or notebook.bufnr ~= bufnr or notebook.language ~= read.language then
        notebooks[uri] = Notebook.new(bufnr, read.language, filetype)
      end

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
