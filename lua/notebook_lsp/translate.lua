-- Translates LSP values between notebook buffers and the cells servers know.
-- A cell's lines are the buffer's rows from the cell's start, column for
-- column, so translating a position only moves its line. Opaque `data` fields
-- are the server's own and are never touched.
local M = {}

---@class notebook_lsp.Where the cell a value is about
---@field notebook notebook_lsp.Notebook
---@field cell notebook_lsp.Cell

--- The cell a URI names: nil when it doesn't name a cell, false when it names
--- a cell that no longer exists (and its notebook, if that's still open).
---@alias notebook_lsp.Locate fun(uri: string): notebook_lsp.Where|false|nil, notebook_lsp.Notebook?

---@class notebook_lsp.Context what translating a server's values needs to know of the notebooks
---@field locate notebook_lsp.Locate
---@field current fun(where: notebook_lsp.Where, version: integer): boolean whether the cell's text is still the server's `version` of it
---@field skip fun(uri: string) skips the edits to the notebook (or the cell that's gone) `uri`

local function is_position(value)
  return type(value.line) == "number" and type(value.character) == "number"
end

--- An empty table that encodes like `value` (a JSON object or array).
local function like(value)
  return setmetatable({}, getmetatable(value))
end

--- `value` with every position in it moved by `lines` lines.
---@param value any
---@param lines integer
function M.shift(value, lines)
  if type(value) ~= "table" then
    return value
  end
  if is_position(value) then
    local moved = vim.deepcopy(value)
    moved.line = value.line + lines
    return moved
  end
  local out = like(value)
  for key, item in pairs(value) do
    out[key] = key == "data" and item or M.shift(item, lines)
  end
  return out
end

--- `value` from the server, for Neovim: positions in cells become positions
--- in their notebook buffer, and cell URIs the buffer's URI. Positions without
--- a URI of their own are in `where`, the cell the request was about (nil when
--- there was none). Edits to several cells of a notebook become edits to its
--- buffer, applied together.
---
--- A value about a cell that's gone, like a Location, is nil, and so is
--- whatever it's part of, up to the list it's in.
---@param value any
---@param where notebook_lsp.Where?
---@param context notebook_lsp.Context
function M.to_client(value, where, context)
  if type(value) ~= "table" then
    return value
  end
  if is_position(value) then
    return where and M.shift(value, where.cell.start) or value
  end
  if vim.islist(value) then
    local out = like(value)
    for _, item in ipairs(value) do
      local translated = M.to_client(item, where, context)
      if translated ~= nil then
        table.insert(out, translated)
      end
    end
    return out
  end

  -- Where the positions in this value are: in a document it names (a
  -- Location, a TextDocumentEdit), or wherever its parent's are
  local inner = where ---@type notebook_lsp.Where|false|nil
  if type(value.uri) == "string" then
    inner = context.locate(value.uri)
  elseif type(value.textDocument) == "table" and type(value.textDocument.uri) == "string" then
    inner = context.locate(value.textDocument.uri)
  end
  local target = nil ---@type notebook_lsp.Where|false|nil
  if type(value.targetUri) == "string" then
    target = context.locate(value.targetUri)
  end
  if inner == false or target == false then
    return nil
  end

  local out = like(value)
  for key, item in pairs(value) do
    if key == "data" then
      out[key] = item
    elseif key == "uri" then
      out[key] = inner and inner.notebook.uri or item
    elseif key == "targetUri" then
      out[key] = target and target.notebook.uri or item
    elseif key == "targetRange" or key == "targetSelectionRange" then
      out[key] = M.to_client(item, target, context)
    elseif key == "originSelectionRange" then
      out[key] = M.to_client(item, where, context)
    elseif key == "changes" and type(item) == "table" and not vim.islist(item) then
      out[key] = M.changes(item, context)
    elseif key == "documentChanges" then
      out[key] = M.document_changes(item, context)
    else
      out[key] = M.to_client(item, inner, context)
    end
    if out[key] == nil then
      return nil -- a part of it is about a cell that's gone
    end
  end
  -- The buffer's version is not the cell's
  if type(value.uri) == "string" and inner and value.version ~= nil then
    out.version = vim.NIL
  end
  return out
end

--- TextDocumentEdits from the server, for Neovim (other document changes stay
--- as they are): the edits to a notebook's cells become one edit of its
--- buffer, where the first of them was. If the server versioned the cells',
--- it has the buffer's version (its changedtick), which Neovim checks as it
--- applies it.
---
--- Like Neovim does with the edits for an older version of a document, a
--- notebook's are skipped if one of its cells is gone, or changed since the
--- version the server made them for.
---@param changes any[]
---@param context notebook_lsp.Context
---@return any[]
local function notebook_edits(changes, context)
  local out, merged, stale = {}, {}, {} ---@type any[], table<string, lsp.TextDocumentEdit>, table<string, true>
  for _, change in ipairs(changes) do
    local where, owner = nil, nil ---@type notebook_lsp.Where|false|nil, notebook_lsp.Notebook?
    if change.edits then
      where, owner = context.locate(change.textDocument.uri)
    end
    if where == nil then
      table.insert(out, change)
    else
      local notebook = where and where.notebook or owner
      local uri = notebook and notebook.uri or change.textDocument.uri
      local version = change.textDocument.version
      local versioned = version ~= nil and version ~= vim.NIL
      if not where or (versioned and not context.current(where, version)) then
        stale[uri] = true
      end
      if not merged[uri] then
        merged[uri] = { textDocument = { uri = uri, version = vim.NIL }, edits = {} }
        table.insert(out, merged[uri])
      end
      if where then
        if versioned then
          -- Not Neovim's version of it, which is 0 until it changes and never checked then
          merged[uri].textDocument.version = vim.api.nvim_buf_get_changedtick(where.notebook.bufnr)
        end
        vim.list_extend(merged[uri].edits, M.to_client(change.edits, where, context) --[[@as lsp.TextEdit[] ]])
      end
    end
  end

  local kept = {}
  for _, change in ipairs(out) do
    local uri = change.textDocument and change.textDocument.uri
    if merged[uri] == change and stale[uri] then
      context.skip(uri)
    else
      table.insert(kept, change)
    end
  end
  return kept
end

--- WorkspaceEdit.changes: the edits to a notebook's cells become one list of
--- edits to its buffer, skipped if one of its cells is gone.
---@param changes table<string, lsp.TextEdit[]>
---@param context notebook_lsp.Context
function M.changes(changes, context)
  local edits = {}
  for uri, list in pairs(changes) do
    table.insert(edits, { textDocument = { uri = uri, version = vim.NIL }, edits = list })
  end
  local out = like(changes)
  for _, change in ipairs(notebook_edits(edits, context)) do
    out[change.textDocument.uri] = change.edits
  end
  return out
end

--- WorkspaceEdit.documentChanges: the edits to a notebook's cells become one
--- TextDocumentEdit of its buffer, where the first of them was, skipped if one
--- of its cells is gone or changed since.
---@param changes any[]
---@param context notebook_lsp.Context
function M.document_changes(changes, context)
  return setmetatable(notebook_edits(changes, context), getmetatable(changes))
end

-- The key under which an item's `data` records the cell it came from
local TAG = "notebook_lsp"

--- Records in `item`'s data the cell it came from and the item as the server
--- gave it: resolving the item later sends the server its own item, in its
--- cell, with no translation back.
---@param item table the item for Neovim
---@param cell_uri string
---@param original table the item as the server gave it
function M.tag(item, cell_uri, original)
  item.data = { [TAG] = cell_uri, item = original }
end

--- The cell `item` came from and the item as the server gave it, if `item`
--- records them.
---@param item table
---@return string? cell_uri
---@return table? original
function M.untag(item)
  local data = item.data
  if type(data) ~= "table" or type(data[TAG]) ~= "string" then
    return nil, nil
  end
  return data[TAG], data.item
end

return M
