-- notebook-lsp.nvim: LSP for jupytext Markdown notebooks, through the LSP
-- notebook protocol (notebookDocument/*).
--
-- Servers extended to notebooks also attach to jupytext notebooks in their
-- language, through the same clients .py files use: Neovim attaches them, and
-- the plugin translates what concerns notebook buffers on the client itself.
-- Everything else passes through untouched.
local jupytext = require("notebook_lsp.jupytext")
local Notebook = require("notebook_lsp.notebook")
local translate = require("notebook_lsp.translate")

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

--- The cell `uri` names, among the notebooks' cells.
---@type notebook_lsp.Locate
local function locate(uri)
  for _, notebook in pairs(notebooks) do
    local cell = notebook:cell_of(uri)
    if cell ~= nil then
      return cell and { notebook = notebook, cell = cell }
    end
  end
  -- Only the plugin makes cell URIs: this one is of a cell or notebook that's gone
  if vim.startswith(uri, "vscode-notebook-cell:") then
    return false
  end
end

-- Requests that resolve an item of an earlier result, and the results that carry such items
local RESOLVE = {
  ["completionItem/resolve"] = true,
  ["codeAction/resolve"] = true,
  ["codeLens/resolve"] = true,
  ["inlayHint/resolve"] = true,
  ["documentLink/resolve"] = true,
}
local RESOLVABLE = {
  ["textDocument/completion"] = true,
  ["textDocument/codeAction"] = true,
  ["textDocument/codeLens"] = true,
  ["textDocument/inlayHint"] = true,
  ["textDocument/documentLink"] = true,
}

--- The result of `method` from the server, about `where`, for Neovim. Items
--- that may be resolved later record their cell, so they resolve in it.
---@param method string
---@param result any
---@param where notebook_lsp.Where
local function to_client(method, result, where)
  local translated = translate.to_client(result, where, locate)
  if RESOLVABLE[method] and type(result) == "table" then
    local cell_uri = where.notebook:cell_uri(where.cell.id)
    local originals, items, default = result, translated, nil
    if result.items then -- a CompletionList
      originals, items = result.items, translated.items
      default = result.itemDefaults and result.itemDefaults.data
    end
    for i, original in ipairs(originals) do
      -- A code action may be a Command, which has nothing to resolve
      if type(original) == "table" and type(original.command) ~= "string" then
        if original.data == nil and default ~= nil then
          -- What the client would send: the item with the list's default data
          original = vim.tbl_extend("force", original, { data = default })
        end
        translate.tag(items[i], cell_uri, original)
      end
    end
  end
  return translated
end

---@class (private) notebook_lsp.Target a cell a request goes to, and the request as that cell's
---@field where notebook_lsp.Where
---@field params table

--- The cells a request about `notebook` goes to: the cell of its position, the
--- cells its range overlaps (with the range clipped to each), or every cell.
---@param notebook notebook_lsp.Notebook
---@param params table
---@return notebook_lsp.Target[]
local function targets(notebook, params)
  local function target(cell, range)
    local cell_params = translate.shift(vim.tbl_extend("force", params, { range = range }), -cell.start)
    cell_params.textDocument = vim.tbl_extend("force", cell_params.textDocument, { uri = notebook:cell_uri(cell.id) })
    return { where = { notebook = notebook, cell = cell }, params = cell_params }
  end
  local function before(a, b)
    return a.line < b.line or (a.line == b.line and a.character < b.character)
  end

  if params.position then
    local cell = notebook:cell_at(params.position.line)
    return cell and { target(cell) } or {}
  end
  local found = {}
  for _, cell in ipairs(notebook:read()) do
    local range = params.range
    if not range then
      table.insert(found, target(cell))
    else
      local start = { line = cell.start, character = 0 }
      local finish = { line = cell.start + #cell.lines, character = 0 } -- just after the cell's code
      if before(range.start, finish) and not before(range["end"], start) then
        table.insert(
          found,
          target(cell, {
            start = before(range.start, start) and start or range.start,
            ["end"] = before(finish, range["end"]) and finish or range["end"],
          })
        )
      end
    end
  end
  return found
end

--- The semantic tokens of the cells (LSP's encoding: five numbers per token,
--- its line and start relative to the token before it) as the notebook's.
---@param results any[] by target
---@param targets_ notebook_lsp.Target[]
---@return integer[]
local function merge_tokens(results, targets_)
  local data, last_line, last_start = {}, 0, 0
  for i, target in ipairs(targets_) do
    local tokens = results[i] and results[i].data or {}
    local line, start = 0, 0 -- in the cell
    for j = 1, #tokens, 5 do
      line = line + tokens[j]
      start = tokens[j] == 0 and start + tokens[j + 1] or tokens[j + 1]
      local row = target.where.cell.start + line
      vim.list_extend(data, {
        row - last_line,
        row == last_line and start - last_start or start,
        tokens[j + 2],
        tokens[j + 3],
        tokens[j + 4],
      })
      last_line, last_start = row, start
    end
  end
  return data
end

--- One result of `method` for the notebook out of the results for its cells.
---@param method string
---@param results any[] by target; nil for no result
---@param targets_ notebook_lsp.Target[]
local function merge(method, results, targets_)
  local count = #targets_
  if method == "textDocument/semanticTokens/full" or method == "textDocument/semanticTokens/range" then
    -- Without a result id: the next request can't be for the changes since this one
    return { data = merge_tokens(results, targets_) }
  end

  -- A full report of the notebook's diagnostics: the cells' reports were full too
  if method == "textDocument/diagnostic" then
    local items = {}
    for i = 1, count do
      local report = results[i]
      if report then
        assert(report.kind == "full", "notebook-lsp: a cell's diagnostic report is not full")
        vim.list_extend(items, report.items)
      end
    end
    return { kind = "full", items = items }
  end

  local merged
  for i = 1, count do
    local result = results[i]
    if result ~= nil and result ~= vim.NIL then
      assert(
        type(result) == "table" and vim.islist(result),
        ("notebook-lsp: can't combine the results of %s for several cells"):format(method)
      )
      merged = vim.list_extend(merged or {}, result)
    end
  end
  return merged
end

-- Ids of the requests the plugin answers itself or sends to several cells:
-- negative, so that they never clash with the ids of the client's requests
local last_request_id = 0

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
  -- What the server last published for each cell, in the cell's lines, by cell id
  local pushed = {} ---@type table<string, table<integer, lsp.Diagnostic[]>>

  ---@diagnostic disable-next-line: invisible
  local notification = client._notification

  --- Shows the diagnostics the server published for the notebook's cells,
  --- where the cells are now. Those of cells that are gone go with them.
  ---@param notebook notebook_lsp.Notebook
  local function show_diagnostics(notebook)
    local by_cell = pushed[notebook.uri]
    if not by_cell then
      return
    end
    local current, diagnostics = {}, {}
    for _, cell in ipairs(notebook:read()) do
      current[cell.id] = by_cell[cell.id]
      for _, diagnostic in ipairs(by_cell[cell.id] or {}) do
        table.insert(diagnostics, translate.to_client(diagnostic, { notebook = notebook, cell = cell }, locate))
      end
    end
    pushed[notebook.uri] = current
    notification(client, "textDocument/publishDiagnostics", { uri = notebook.uri, diagnostics = diagnostics })
  end

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
    pushed[notebook.uri] = nil
    return rpc.notify("notebookDocument/didClose", {
      notebookDocument = { uri = notebook.notebook_uri },
      cellTextDocuments = vim.tbl_map(function(cell)
        return { uri = notebook:cell_uri(cell.id) }
      end, state.cells),
    })
  end

  -- The requests to the server behind each of the plugin's own request ids
  local fanned_out = {} ---@type table<integer, integer[]>

  --- Sends `method` to `targets`, and answers `callback` with their results
  --- combined, under a request id of the plugin's own.
  ---@param method string
  ---@param targets_ notebook_lsp.Target[]
  local function fan_out(method, targets_, callback, notify_reply)
    last_request_id = last_request_id - 1
    local id, results, pending, failure = last_request_id, {}, #targets_, nil
    local function finish()
      fanned_out[id] = nil
      if notify_reply then
        notify_reply(id)
      end
      if failure then
        callback(failure, nil, id)
      else
        callback(nil, merge(method, results, targets_), id)
      end
    end

    if pending == 0 then
      vim.schedule(finish)
      return true, id
    end
    fanned_out[id] = {}
    for i, target in ipairs(targets_) do
      local sent, request_id = rpc.request(method, target.params, function(err, result)
        failure = failure or err
        results[i] = result and to_client(method, result, target.where)
        pending = pending - 1
        if pending == 0 then
          finish()
        end
      end)
      if not sent then
        return false
      end
      table.insert(fanned_out[id], request_id)
    end
    return true, id
  end

  --- Sends a request about another document as it is. Its result may still be
  --- about cells, like a rename's edits, which become the notebook's.
  local function pass_through(method, params, callback, notify_reply)
    return rpc.request(method, params, function(err, result, id)
      if result ~= nil and next(notebooks) then
        result = translate.to_client(result, nil, locate)
      end
      callback(err, result, id)
    end, notify_reply)
  end

  client.rpc = setmetatable({
    request = function(method, params, callback, notify_reply)
      -- An item of an earlier result resolves in the cell it came from
      if RESOLVE[method] and type(params) == "table" then
        local cell_uri, item = translate.untag(params)
        if not cell_uri then
          return pass_through(method, params, callback, notify_reply)
        end
        local where = locate(cell_uri)
        if not where then
          error("notebook-lsp: resolving an item of a cell that no longer exists: " .. cell_uri)
        end
        return rpc.request(method, item, function(err, result, id)
          local resolved = result and translate.to_client(result, where, locate)
          if type(resolved) == "table" then
            translate.tag(resolved, cell_uri, result)
          end
          callback(err, resolved, id)
        end, notify_reply)
      end

      local document = type(params) == "table" and params.textDocument or nil
      local notebook = type(document) == "table" and notebooks[document.uri]
      if not notebook then
        return pass_through(method, params, callback, notify_reply)
      end
      if method == "textDocument/diagnostic" then
        -- The notebook's previous report says nothing of the cells' reports
        params = vim.deepcopy(params)
        params.previousResultId = nil
      end
      local found = targets(notebook, params)
      if #found == 1 and (params.position or params.range) then
        local target = found[1]
        return rpc.request(method, target.params, function(err, result, id)
          callback(err, result and to_client(method, result, target.where), id)
        end, notify_reply)
      end
      return fan_out(method, found, callback, notify_reply)
    end,

    notify = function(method, params)
      if method == "$/cancelRequest" and type(params.id) == "number" and params.id < 0 then
        for _, id in ipairs(fanned_out[params.id] or {}) do
          rpc.notify(method, { id = id })
        end
        return true
      end

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
        -- Also when only lines outside cells changed: the cells may have moved
        show_diagnostics(notebook)
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

  -- Notifications from the server: diagnostics of cells are shown where the
  -- cells are. Like _server_request below, the dispatchers look it up on the client
  ---@diagnostic disable-next-line: duplicate-set-field, invisible
  function client._notification(self, method, params)
    if method == "textDocument/publishDiagnostics" and type(params) == "table" then
      local where = locate(params.uri)
      if where == false then
        return -- for a cell that's gone
      elseif where and client:supports_method("textDocument/diagnostic", where.notebook.bufnr) then
        return -- the server answers pull requests for the notebook, which give the same diagnostics
      elseif where then
        pushed[where.notebook.uri] = pushed[where.notebook.uri] or {}
        pushed[where.notebook.uri][where.cell.id] = params.diagnostics
        return show_diagnostics(where.notebook)
      end
    end
    return notification(self, method, params)
  end

  -- Requests from the server: edits to cells are edits to their notebook buffer.
  -- The client's dispatchers look this method up on the client when a request
  -- arrives, which makes it the one place to see them before Neovim does
  ---@diagnostic disable-next-line: invisible
  local server_request = client._server_request
  ---@diagnostic disable-next-line: duplicate-set-field, invisible
  function client._server_request(self, method, params)
    if method == "workspace/applyEdit" and type(params) == "table" then
      params = vim.tbl_extend("force", params, { edit = translate.to_client(params.edit, nil, locate) })
    end
    return server_request(self, method, params)
  end
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
