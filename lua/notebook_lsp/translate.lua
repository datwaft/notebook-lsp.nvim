-- Translates LSP values between notebook buffers and the cells servers know.
-- A cell's lines are the buffer's rows from the cell's start, column for
-- column, so translating a position only moves its line. Opaque `data` fields
-- are the server's own and are never touched.
local M = {}

---@class notebook_lsp.Where the cell a value is about
---@field notebook notebook_lsp.Notebook
---@field cell notebook_lsp.Cell

--- The cell a URI names: nil when it doesn't name a cell, false when it names
--- a cell that no longer exists.
---@alias notebook_lsp.Locate fun(uri: string): notebook_lsp.Where|false|nil

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

---@param locate notebook_lsp.Locate
---@param uri string
---@return notebook_lsp.Where?
local function find(locate, uri)
  local where = locate(uri)
  assert(where ~= false, "notebook-lsp: the server refers to a cell that no longer exists: " .. uri)
  return where or nil
end

--- `value` from the server, for Neovim: positions in cells become positions
--- in their notebook buffer, and cell URIs the buffer's URI. Positions without
--- a URI of their own are in `where`, the cell the request was about (nil when
--- there was none). Edits to several cells of a notebook become edits to its
--- buffer, applied together.
---@param value any
---@param where notebook_lsp.Where?
---@param locate notebook_lsp.Locate
function M.to_client(value, where, locate)
  if type(value) ~= "table" then
    return value
  end
  if is_position(value) then
    return where and M.shift(value, where.cell.start) or value
  end

  -- Where the positions in this value are: in a document it names (a
  -- Location, a TextDocumentEdit), or wherever its parent's are
  local inner = where
  if type(value.uri) == "string" then
    inner = find(locate, value.uri)
  elseif type(value.textDocument) == "table" and type(value.textDocument.uri) == "string" then
    inner = find(locate, value.textDocument.uri)
  end
  local target = type(value.targetUri) == "string" and find(locate, value.targetUri) or nil

  local out = like(value)
  for key, item in pairs(value) do
    if key == "data" then
      out[key] = item
    elseif key == "uri" then
      out[key] = inner and inner.notebook.uri or item
    elseif key == "targetUri" then
      out[key] = target and target.notebook.uri or item
    elseif key == "targetRange" or key == "targetSelectionRange" then
      out[key] = M.to_client(item, target, locate)
    elseif key == "originSelectionRange" then
      out[key] = M.to_client(item, where, locate)
    elseif key == "changes" and type(item) == "table" and not vim.islist(item) then
      out[key] = M.changes(item, locate)
    elseif key == "documentChanges" then
      out[key] = M.document_changes(item, locate)
    else
      out[key] = M.to_client(item, inner, locate)
    end
  end
  -- The buffer's version is not the cell's
  if type(value.uri) == "string" and inner and value.version ~= nil then
    out.version = vim.NIL
  end
  return out
end

--- WorkspaceEdit.changes: the edits to a notebook's cells become one list of
--- edits to its buffer.
---@param changes table<string, lsp.TextEdit[]>
---@param locate notebook_lsp.Locate
function M.changes(changes, locate)
  local out = like(changes)
  for uri, edits in pairs(changes) do
    local where = find(locate, uri)
    if where then
      local key = where.notebook.uri
      out[key] = vim.list_extend(out[key] or {}, M.to_client(edits, where, locate))
    else
      out[uri] = edits
    end
  end
  return out
end

--- WorkspaceEdit.documentChanges: the edits to a notebook's cells become one
--- TextDocumentEdit of its buffer, where the first of them was.
---@param changes any[]
---@param locate notebook_lsp.Locate
function M.document_changes(changes, locate)
  local out, merged = like(changes), {} ---@type any[], table<string, lsp.TextDocumentEdit>
  for _, change in ipairs(changes) do
    local translated = M.to_client(change, nil, locate)
    local where = change.edits and find(locate, change.textDocument.uri)
    local uri = where and where.notebook.uri
    if uri and merged[uri] then
      vim.list_extend(merged[uri].edits, translated.edits)
    else
      if uri then
        merged[uri] = translated
      end
      table.insert(out, translated)
    end
  end
  return out
end

-- The key under which an item's `data` records the cell it came from
local TAG = "notebook_lsp"

--- Records in `item`'s data the cell it came from, so that resolving it later
--- goes to that cell. `data` is the server's data for the item.
---@param item table
---@param cell_uri string
---@param data any
function M.tag(item, cell_uri, data)
  item.data = { [TAG] = cell_uri, data = data }
end

--- The cell `item` came from, if it records one, and the item as the server
--- gave it.
---@param item table
---@return string? cell_uri
---@return table item
function M.untag(item)
  local data = item.data
  if type(data) ~= "table" or type(data[TAG]) ~= "string" then
    return nil, item
  end
  local original = vim.deepcopy(item)
  original.data = data.data
  return data[TAG], original
end

return M
