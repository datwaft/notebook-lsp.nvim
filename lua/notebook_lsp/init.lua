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

-- The notebook type of Jupyter notebooks, as servers name it
local NOTEBOOK_TYPE = "jupyter-notebook"

--- Notebook buffers, by the URI Neovim sends their messages with.
---@type table<string, notebook_lsp.Notebook>
local notebooks = {}

-- A wiped buffer's notebook is gone with its cells, also for what servers say
-- about them after
vim.api.nvim_create_autocmd("BufWipeout", {
  group = vim.api.nvim_create_augroup("notebook_lsp.notebooks", {}),
  desc = "notebook-lsp: forget the buffer's notebook",
  callback = function(args)
    for uri, notebook in pairs(notebooks) do
      if notebook.bufnr == args.buf then
        notebooks[uri] = nil
      end
    end
  end,
})

--- Clients the plugin sits on, by id.
---@type table<integer, true>
local intercepted = {}

--- Whether `filter`, a notebook type or a NotebookDocumentFilter, names `notebook`.
---@param filter string|lsp.NotebookDocumentFilter
---@param notebook notebook_lsp.Notebook
local function names(filter, notebook)
  if type(filter) == "string" then
    return filter == "*" or filter == NOTEBOOK_TYPE
  end
  local pattern = filter.pattern
  if type(pattern) == "table" then -- a RelativePattern
    local base = pattern.baseUri
    pattern = vim.uri_to_fname(type(base) == "string" and base or base.uri) .. "/" .. pattern.pattern
  end ---@cast pattern string?
  return (filter.notebookType == nil or filter.notebookType == NOTEBOOK_TYPE)
    and (filter.scheme == nil or vim.startswith(notebook.notebook_uri, filter.scheme .. ":"))
    and (pattern == nil or vim.glob.to_lpeg(pattern):match(vim.uri_to_fname(notebook.notebook_uri)) ~= nil)
end

--- Whether the server syncs `notebook`. A selector without cells is for all
--- of them, prose included: the plugin syncs those it knows, the code cells in
--- the kernel's language.
---@param client vim.lsp.Client
---@param notebook notebook_lsp.Notebook
local function syncs_notebooks(client, notebook)
  local sync = client.server_capabilities.notebookDocumentSync
  for _, selector in ipairs(sync and sync.notebookSelector or {}) do
    local cells = selector.cells ---@type {language: string}[]?
    local in_language = cells == nil
    for _, cell in ipairs(cells or {}) do
      in_language = in_language or cell.language == notebook.filetype
    end
    if in_language and (selector.notebook == nil or names(selector.notebook, notebook)) then
      return true
    end
  end
  return false
end

--- Whether Neovim tells the server about the buffers it attaches to, as it
--- opens, changes and closes them: what the plugin tells it about notebooks
--- follows that.
---@param client vim.lsp.Client
local function syncs_text(client)
  local change = vim.tbl_get(client.server_capabilities, "textDocumentSync", "change")
  return client:supports_method("textDocument/didOpen")
    and change ~= nil
    and change ~= vim.lsp.protocol.TextDocumentSyncKind.None
end

--- The cell `uri` names, among the notebooks' cells.
---@type notebook_lsp.Locate
local function locate(uri)
  for _, notebook in pairs(notebooks) do
    local cell = notebook:cell_of(uri)
    if cell == false then
      return false, notebook
    elseif cell then
      return { notebook = notebook, cell = cell }
    end
  end
  -- Only the plugin makes cell URIs: this one is of a cell or notebook that's gone
  if vim.startswith(uri, "vscode-notebook-cell:") then
    return false
  end
end

--- The notebook of the buffer whose name is now `uri`, under that URI. After
--- `:saveas`, Neovim closes the document with the buffer's old name and opens
--- it with the new one, without attaching the buffer again.
---@param uri string
---@return notebook_lsp.Notebook?
local function renamed(uri)
  for old, notebook in pairs(notebooks) do
    if vim.api.nvim_buf_is_valid(notebook.bufnr) and vim.uri_from_bufnr(notebook.bufnr) == uri then
      notebooks[old] = nil
      notebooks[uri] = Notebook.new(notebook.bufnr, notebook.language, notebook.filetype)
      return notebooks[uri]
    end
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

-- Requests about an item of a call or type hierarchy, and the results that carry such items
local HIERARCHY = {
  ["callHierarchy/incomingCalls"] = true,
  ["callHierarchy/outgoingCalls"] = true,
  ["typeHierarchy/supertypes"] = true,
  ["typeHierarchy/subtypes"] = true,
}
local HIERARCHY_ITEMS = {
  ["textDocument/prepareCallHierarchy"] = true,
  ["textDocument/prepareTypeHierarchy"] = true,
  ["typeHierarchy/supertypes"] = true,
  ["typeHierarchy/subtypes"] = true,
}

--- The hierarchy items in a result of `method`, each recording the item as the
--- server gave it if it's in a cell: the requests about an item get it back as
--- it was, in its cell.
---@param method string
---@param result any
local function tag_hierarchy(method, result)
  local function tagged(item)
    if type(item) ~= "table" or type(item.uri) ~= "string" or not locate(item.uri) then
      return item
    end
    local copy = vim.tbl_extend("force", {}, item)
    translate.tag(copy, item.uri, item)
    return copy
  end
  if type(result) ~= "table" then
    return result
  elseif method == "callHierarchy/incomingCalls" or method == "callHierarchy/outgoingCalls" then
    local key = method == "callHierarchy/incomingCalls" and "from" or "to"
    return vim.tbl_map(function(call)
      return vim.tbl_extend("force", call, { [key] = tagged(call[key]) })
    end, result)
  elseif HIERARCHY_ITEMS[method] then
    return vim.tbl_map(tagged, result)
  end
  return result
end

--- The result of `method` from the server, about `where`, for Neovim: nil if
--- the cell is gone since. Items that may be resolved later record their
--- cell, so they resolve in it.
---@param method string
---@param result any
---@param where notebook_lsp.Where
---@param context notebook_lsp.Context
local function to_client(method, result, where, context)
  local cell_uri = where.notebook:cell_uri(where.cell.id)
  if locate(cell_uri) == false then
    return nil
  end
  if RESOLVABLE[method] and type(result) == "table" then
    -- Tagged before translating, which drops the items about cells that are gone
    local items, default, merge = result, nil, false
    if result.items then -- a CompletionList
      items, default = result.items, vim.tbl_get(result, "itemDefaults", "data")
      merge = vim.tbl_get(result, "applyKind", "data") == vim.lsp.protocol.ApplyKind.Merge
    end
    local tagged = {}
    for i, original in ipairs(items) do
      tagged[i] = original
      -- A code action may be a Command, which has nothing to resolve
      if type(original) == "table" and type(original.command) ~= "string" then
        tagged[i] = vim.tbl_extend("force", {}, original)
        -- What the client would send: the item with the list's default data, as Neovim applies it
        local data = original.data
        if merge and type(default) == "table" and type(data) == "table" then
          data = vim.tbl_extend("force", default, data)
        elseif data == nil then
          data = default
        end
        if data ~= original.data then
          original = vim.tbl_extend("force", original, { data = data })
        end
        translate.tag(tagged[i], cell_uri, original)
      end
    end
    result = result.items and vim.tbl_extend("force", result, { items = tagged }) or tagged
  end
  return translate.to_client(tag_hierarchy(method, result), where, context)
end

---@class (private) notebook_lsp.Target a cell a request goes to, and the request as that cell's
---@field where notebook_lsp.Where
---@field params table
---@field indexes? integer[] for a request with several positions: which of them are the cell's, in its params' order

--- The cells a request about `notebook` goes to: the cell of its position,
--- the cells of its positions, the cells its range or ranges overlap (clipped
--- to each), or every cell.
---@param notebook notebook_lsp.Notebook
---@param params table
---@return notebook_lsp.Target[]
local function targets(notebook, params)
  local function target(cell, range)
    local where = { notebook = notebook, cell = cell }
    local cell_params = translate.shift(vim.tbl_extend("force", params, { range = range }), -cell.start)
    cell_params.textDocument = vim.tbl_extend("force", cell_params.textDocument, { uri = notebook:cell_uri(cell.id) })
    local diagnostics = vim.tbl_get(params, "context", "diagnostics")
    if type(diagnostics) == "table" then
      -- A code action request for a cell is about the cell's own diagnostics
      cell_params.context.diagnostics = translate.cell_diagnostics(diagnostics, where, function(uri)
        return notebooks[uri]
      end)
    end
    return { where = where, params = cell_params }
  end
  local function before(a, b)
    return a.line < b.line or (a.line == b.line and a.character < b.character)
  end
  --- The part of `range` in the cell's code, if any.
  local function clip(cell, range)
    local start = { line = cell.start, character = 0 }
    local finish = { line = cell.start + #cell.lines, character = 0 } -- just after the cell's code
    if before(range.start, finish) and not before(range["end"], start) then
      return {
        start = before(range.start, start) and start or range.start,
        ["end"] = before(finish, range["end"]) and finish or range["end"],
      }
    end
  end

  if params.position then
    local cell = notebook:cell_at(params.position.line)
    return cell and { target(cell) } or {}
  end
  local found = {}
  if params.positions then
    local by_cell = {} ---@type table<integer, notebook_lsp.Target>
    for i, position in ipairs(params.positions) do
      local cell = notebook:cell_at(position.line)
      if cell then
        if not by_cell[cell.id] then
          by_cell[cell.id] = target(cell)
          by_cell[cell.id].params.positions, by_cell[cell.id].indexes = {}, {}
          table.insert(found, by_cell[cell.id])
        end
        table.insert(by_cell[cell.id].params.positions, translate.shift(position, -cell.start))
        table.insert(by_cell[cell.id].indexes, i)
      end
    end
    return found
  end
  for _, cell in ipairs(notebook:read()) do
    if params.ranges then
      local ranges = {}
      for _, range in ipairs(params.ranges) do
        local clipped = clip(cell, range)
        if clipped then
          table.insert(ranges, clipped)
        end
      end
      if #ranges > 0 then
        local cell_target = target(cell)
        cell_target.params.ranges = translate.shift(ranges, -cell.start)
        table.insert(found, cell_target)
      end
    elseif params.range then
      local clipped = clip(cell, params.range)
      if clipped then
        table.insert(found, target(cell, clipped))
      end
    else
      table.insert(found, target(cell))
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
---@param params table the request for the notebook
---@param results any[] by target; nil for no result
---@param targets_ notebook_lsp.Target[]
local function merge(method, params, results, targets_)
  local count = #targets_
  if method == "textDocument/selectionRange" then
    if count == 0 then
      return nil
    end
    -- One range per position, in their order: outside cells, the position itself
    local ranges = {}
    for i, target in ipairs(targets_) do
      for j, index in ipairs(target.indexes) do
        ranges[index] = results[i] and results[i][j]
      end
    end
    for i, position in ipairs(params.positions) do
      ranges[i] = ranges[i] or { range = { start = position, ["end"] = position } }
    end
    return ranges
  end
  if method == "textDocument/semanticTokens/full" or method == "textDocument/semanticTokens/range" then
    -- Without a result id: the next request can't be for the changes since this one
    return { data = merge_tokens(results, targets_) }
  end

  -- A full report of the notebook's diagnostics: the cells' reports were full
  -- too. With the related reports of the cells' about other files
  if method == "textDocument/diagnostic" then
    local items, related = {}, nil ---@type lsp.Diagnostic[], table<string, any>?
    for i = 1, count do
      local report = results[i]
      if report then
        assert(report.kind == "full", "notebook-lsp: a cell's diagnostic report is not full")
        vim.list_extend(items, report.items)
        for uri, other in pairs(report.relatedDocuments or {}) do
          related = related or {}
          related[uri] = other
        end
      end
    end
    return { kind = "full", items = items, relatedDocuments = related }
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
---@field notebook_uri string
---@field version integer
---@field cells notebook_lsp.SyncedCell[]

---@class (private) notebook_lsp.SyncedCell
---@field id integer
---@field uri string
---@field text string
---@field version integer

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

  --- Detaches the server from the notebook, which it isn't told about.
  ---@param notebook notebook_lsp.Notebook
  local function reject(notebook)
    rejected[notebook.uri] = true
    vim.schedule(function()
      vim.lsp.buf_detach_client(notebook.bufnr, client.id)
    end)
  end

  -- Neovim doesn't open buffers for servers that don't sync text documents,
  -- and the notebook isn't opened for them either: it's rejected once attached
  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup(("notebook_lsp.attach.%d"):format(client.id), {}),
    desc = "notebook-lsp: detach from notebooks the server wasn't told about",
    callback = function(event)
      if client:is_stopped() then
        return true
      end
      local uri = vim.uri_from_bufnr(event.buf)
      local notebook = notebooks[uri]
      if event.data.client_id == client.id and notebook and not synced[uri] and not rejected[uri] then
        reject(notebook)
      end
    end,
  })

  ---@type notebook_lsp.Context
  local context = {
    locate = locate,
    current = function(where, version)
      local state = synced[where.notebook.uri]
      for _, cell in ipairs(state and state.cells or {}) do
        if cell.id == where.cell.id then
          return cell.version == version and cell.text == where.cell.text
        end
      end
      return false
    end,
    skip = function(uri)
      print("Buffer ", uri, " newer than edits.") -- what Neovim prints when it skips a document's edits
    end,
  }

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
        table.insert(diagnostics, translate.to_client(diagnostic, { notebook = notebook, cell = cell }, context))
      end
    end
    pushed[notebook.uri] = current
    notification(client, "textDocument/publishDiagnostics", { uri = notebook.uri, diagnostics = diagnostics })
  end

  ---@param notebook notebook_lsp.Notebook
  ---@param cell notebook_lsp.SyncedCell
  local function cell_document(notebook, cell)
    return { uri = cell.uri, languageId = notebook.filetype, version = cell.version, text = cell.text }
  end

  -- Declared here for open(), which tells the server about saves
  local change ---@type fun(notebook: notebook_lsp.Notebook): boolean

  ---@param notebook notebook_lsp.Notebook
  local function open(notebook)
    local state = { notebook_uri = notebook.notebook_uri, version = 1, cells = {} } ---@type notebook_lsp.Synced
    for _, cell in ipairs(notebook:read()) do
      table.insert(state.cells, { id = cell.id, uri = notebook:cell_uri(cell.id), text = cell.text, version = 1 })
    end
    synced[notebook.uri] = state

    -- Neovim tells servers about saves if they want them for text documents
    -- (textDocumentSync.save), while notebooks have their own option
    vim.api.nvim_create_autocmd("BufWritePost", {
      buffer = notebook.bufnr,
      group = vim.api.nvim_create_augroup(("notebook_lsp.save.%d"):format(client.id), { clear = false }),
      desc = "notebook-lsp: notebookDocument/didSave",
      callback = function()
        if synced[notebook.uri] ~= state or client:is_stopped() then
          return true -- the notebook is closed since
        end
        if vim.tbl_get(client.server_capabilities, "notebookDocumentSync", "save") then
          change(notebook) -- the changes Neovim hasn't sent yet go first
          rpc.notify("notebookDocument/didSave", { notebookDocument = { uri = state.notebook_uri } })
        end
      end,
    })

    return rpc.notify("notebookDocument/didOpen", {
      notebookDocument = {
        uri = state.notebook_uri,
        notebookType = NOTEBOOK_TYPE,
        version = state.version,
        cells = vim.tbl_map(function(cell)
          return { kind = CODE, document = cell.uri }
        end, state.cells),
      },
      cellTextDocuments = vim.tbl_map(function(cell)
        return cell_document(notebook, cell)
      end, state.cells),
    })
  end

  --- Tells the server how the cells changed since it was last told, if they did.
  ---@param notebook notebook_lsp.Notebook
  function change(notebook)
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

    local before, inserted = {}, {} ---@type table<integer, notebook_lsp.SyncedCell>, table<integer, true>
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
          table.insert(
            structure.didOpen,
            cell_document(notebook, { id = cell.id, uri = notebook:cell_uri(cell.id), text = cell.text, version = 1 })
          )
        end
      end
      for i = first, old_last do
        if not inserted[old[i].id] then
          table.insert(structure.didClose, { uri = old[i].uri })
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
      table.insert(cells, { id = cell.id, uri = notebook:cell_uri(cell.id), text = cell.text, version = version })
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

  --- Closes the notebook the server has open for the buffer with `uri`, as
  --- it was told about it: the buffer may have another name since.
  ---@param uri string
  local function close(uri)
    local state = assert(synced[uri], "notebook-lsp: closing a notebook the server doesn't have open")
    synced[uri] = nil
    pushed[uri] = nil
    return rpc.notify("notebookDocument/didClose", {
      notebookDocument = { uri = state.notebook_uri },
      cellTextDocuments = vim.tbl_map(function(cell)
        return { uri = cell.uri }
      end, state.cells),
    })
  end

  -- The requests to the server behind each of the plugin's own request ids
  local fanned_out = {} ---@type table<integer, integer[]>

  --- Answers `callback` with `result` without asking the server, under a
  --- request id of the plugin's own.
  local function answer(result, callback, notify_reply)
    last_request_id = last_request_id - 1
    local id = last_request_id
    vim.schedule(function()
      if notify_reply then
        notify_reply(id)
      end
      callback(nil, result, id)
    end)
    return true, id
  end

  --- Sends `method` to `targets`, and answers `callback` with their results
  --- combined, under a request id of the plugin's own.
  ---@param method string
  ---@param params table the request for the notebook
  ---@param targets_ notebook_lsp.Target[]
  local function fan_out(method, params, targets_, callback, notify_reply)
    if #targets_ == 0 then
      return answer(merge(method, params, {}, targets_), callback, notify_reply)
    end
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
        callback(nil, merge(method, params, results, targets_), id)
      end
    end

    -- Kept here too: a server may answer them all before the last returns, and the id be forgotten
    local requests = {}
    fanned_out[id] = requests
    for i, target in ipairs(targets_) do
      local sent, request_id = rpc.request(method, target.params, function(err, result)
        failure = failure or err
        results[i] = result and to_client(method, result, target.where, context)
        pending = pending - 1
        if pending == 0 then
          finish()
        end
      end)
      if not sent then
        return false
      end
      table.insert(requests, request_id)
    end
    return true, id
  end

  --- Sends a request about another document as it is. Its result may still be
  --- about cells, like a rename's edits, which become the notebook's.
  local function pass_through(method, params, callback, notify_reply)
    return rpc.request(method, params, function(err, result, id)
      if result ~= nil and next(notebooks) then
        result = translate.to_client(tag_hierarchy(method, result), nil, context)
      end
      callback(err, result, id)
    end, notify_reply)
  end

  client.rpc = setmetatable({
    request = function(method, params, callback, notify_reply)
      -- A hierarchy item from a cell goes back as the server gave it
      if HIERARCHY[method] and type(params) == "table" and type(params.item) == "table" then
        local cell_uri, item = translate.untag(params.item)
        local where = cell_uri and locate(cell_uri) or nil
        if cell_uri and not where then
          return answer(nil, callback, notify_reply) -- nothing to ask about an item of a cell that's gone
        end
        local sent = cell_uri and vim.tbl_extend("force", params, { item = item }) or params
        return rpc.request(method, sent, function(err, result, id)
          callback(err, result and translate.to_client(tag_hierarchy(method, result), where, context), id)
        end, notify_reply)
      end

      -- An item of an earlier result resolves in the cell it came from
      if RESOLVE[method] and type(params) == "table" then
        local cell_uri, item = translate.untag(params)
        if not cell_uri then
          return pass_through(method, params, callback, notify_reply)
        end
        local where = locate(cell_uri)
        if not where then
          return answer(params, callback, notify_reply) -- nothing to resolve in a cell that's gone
        end
        return rpc.request(method, item, function(err, result, id)
          local resolved = result and translate.to_client(result, where, context)
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
      if method == "textDocument/willSaveWaitUntil" then
        -- Cells are saved with their notebook, which the protocol has no "will save" for
        return answer(nil, callback, notify_reply)
      end
      if not synced[notebook.uri] then
        return answer(nil, callback, notify_reply) -- nothing to ask about cells the server doesn't have
      end
      -- The request is about the cells as they are now, which the server must
      -- know first. Neovim flushes its pending changes, but not for buffer 0
      change(notebook)
      if method == "textDocument/diagnostic" then
        -- The notebook's previous report says nothing of the cells' reports
        params = vim.deepcopy(params)
        params.previousResultId = nil
      end
      local found = targets(notebook, params)
      if #found == 1 and (params.position or params.range) then
        local target = found[1]
        return rpc.request(method, target.params, function(err, result, id)
          callback(err, result and to_client(method, result, target.where, context), id)
        end, notify_reply)
      end
      return fan_out(method, params, found, callback, notify_reply)
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
      if uri and not notebook and method == "textDocument/didOpen" then
        notebook = renamed(uri)
      elseif uri and not notebook and method == "textDocument/didClose" and (synced[uri] or rejected[uri]) then
        -- A notebook whose buffer was renamed, which another client reopened under the new name first
        rejected[uri] = nil
        return synced[uri] and close(uri) or true
      end
      if not uri or not notebook then
        return rpc.notify(method, params)
      end

      -- Neovim opens an attached buffer once the server is initialized, which
      -- is when the server tells whether it syncs notebooks
      if method == "textDocument/didOpen" and not (syncs_notebooks(client, notebook) and syncs_text(client)) then
        reject(notebook)
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
      elseif method == "textDocument/didClose" then
        return close(uri)
      end
      -- Nothing else about the Markdown file concerns the server, saves included: see open()
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

  -- Requests from the server: edits to cells are edits to their notebook buffer,
  -- and cells to show are shown in it.
  -- The client's dispatchers look this method up on the client when a request
  -- arrives, which makes it the one place to see them before Neovim does
  ---@diagnostic disable-next-line: invisible
  local server_request = client._server_request
  ---@diagnostic disable-next-line: duplicate-set-field, invisible
  function client._server_request(self, method, params)
    if method == "workspace/applyEdit" and type(params) == "table" then
      -- The server can be told: rather than skip part of the edit, refuse it all
      local skipped = nil ---@type string?
      local edit = translate.to_client(
        params.edit,
        nil,
        vim.tbl_extend("force", context, {
          skip = function(uri)
            skipped = skipped or uri
          end,
        })
      )
      if skipped then
        return { applied = false, failureReason = skipped .. " changed since the server made the edit" }
      end
      params = vim.tbl_extend("force", params, { edit = edit })
    elseif method == "window/showDocument" and type(params) == "table" then
      local shown = translate.to_client(params, nil, context)
      if shown == nil then
        return { success = false } -- a cell that's gone
      end
      params = shown
    end
    return server_request(self, method, params)
  end
end

--- Extends the `vim.lsp.config` named `name` to also attach to jupytext
--- Markdown notebooks whose kernel's language is one of `filetypes`. It sets
--- the config's `filetypes`, which replaces the server's own list, its
--- `root_dir` and its `get_language_id`: notebooks don't attach if the user's
--- config sets `filetypes` or `root_dir`, and registrations don't match them
--- if it sets `get_language_id`.
---@param name string
---@param filetypes string[] the server's own filetypes
function M.extend(name, filetypes)
  -- "*" is the config of every server
  assert(name ~= "*", "notebook-lsp: extend() takes a server's name, not a wildcard")
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
      -- A notebook can opt out, before its filetype is set
      local enabled = vim.b[bufnr].notebook_lsp
      assert(enabled == nil or enabled == false, "notebook-lsp: vim.b.notebook_lsp must be false or unset")
      local read = enabled ~= false and jupytext.read(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true))
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

    -- A notebook's is its cells' language, which Neovim matches the document
    -- selectors of the server's registrations against
    get_language_id = function(bufnr, filetype)
      local notebook = notebooks[vim.uri_from_bufnr(bufnr)]
      return notebook and notebook.bufnr == bufnr and notebook.filetype or filetype
    end,

    capabilities = {
      notebookDocument = { synchronization = { dynamicRegistration = false, executionSummarySupport = false } },
    },
  })
end

return M
