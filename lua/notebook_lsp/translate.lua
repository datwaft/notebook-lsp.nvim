-- Translates LSP values between notebook buffers and the cells servers know.
-- A cell's lines are the buffer's rows from the cell's start, column for
-- column, so translating a position only moves its line. Opaque `data` fields
-- and command arguments are the server's own and are never touched.
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
---@field encoding fun(): 'utf-8'|'utf-16'|'utf-32' the server's, which positions count characters in

local function is_position(value)
  return type(value.line) == "number" and type(value.character) == "number"
end

--- Whether `value` is a FoldingRange, which has lines instead of positions.
local function is_folding_range(value)
  return type(value.startLine) == "number" and type(value.endLine) == "number"
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
  if is_folding_range(value) then
    local moved = vim.deepcopy(value)
    moved.startLine, moved.endLine = value.startLine + lines, value.endLine + lines
    return moved
  end
  local out = like(value)
  for key, item in pairs(value) do
    out[key] = key == "data" and item or M.shift(item, lines)
  end
  return out
end

--- The diagnostics among `diagnostics`, Neovim's of a notebook buffer (as in
--- a code action request), that are in `where`'s cell, for the server. Those
--- the plugin gave Neovim are the server's own, as it gave them. Others are
--- moved to the cell's lines, with their related locations in cells (of any
--- notebook) in those cells' lines; related locations in a notebook but in no
--- cell are left out.
---@param diagnostics lsp.Diagnostic[]
---@param where notebook_lsp.Where
---@param notebook_of fun(uri: string): notebook_lsp.Notebook? the notebook of the buffer with `uri`, if any
---@return lsp.Diagnostic[]
function M.cell_diagnostics(diagnostics, where, notebook_of)
  local cell = where.cell
  local out = like(diagnostics)
  for _, diagnostic in ipairs(diagnostics) do
    local cell_uri, original = M.untag(diagnostic)
    local line = diagnostic.range.start.line
    if cell_uri then
      if cell_uri == where.notebook:cell_uri(cell.id) then
        table.insert(out, original)
      end
    elseif line >= cell.start and line <= cell.start + #cell.lines then
      local moved = M.shift(diagnostic, -cell.start)
      if diagnostic.relatedInformation then
        moved.relatedInformation = like(diagnostic.relatedInformation)
        for _, related in ipairs(diagnostic.relatedInformation) do
          local location = related.location
          local notebook = notebook_of(location.uri)
          if not notebook then
            table.insert(moved.relatedInformation, related)
          else
            local other = notebook:cell_at(location.range.start.line)
            if other then
              local range = M.shift(location.range, -other.start)
              local uri = notebook:cell_uri(other.id)
              table.insert(
                moved.relatedInformation,
                vim.tbl_extend("force", related, { location = { uri = uri, range = range } })
              )
            end
          end
        end
      end
      table.insert(out, moved)
    end
  end
  return out
end

--- DocumentDiagnosticReport.relatedDocuments: the reports about other files.
--- Those about cells are left out: each would replace all the diagnostics of
--- its notebook buffer with the cell's.
---@param reports table<string, any>
---@param context notebook_lsp.Context
local function related_documents(reports, context)
  local out = like(reports)
  for uri, report in pairs(reports) do
    if context.locate(uri) == nil then
      out[uri] = M.to_client(report, nil, context)
    end
  end
  return out
end

--- Whether `value` is a TextEdit (or an AnnotatedTextEdit).
local function is_text_edit(value)
  return type(value) == "table" and type(value.range) == "table" and type(value.newText) == "string"
end

--- `edits`, TextEdits of `cell` applied together, such that the cell's text
--- still ends with a line break once they're applied: in the notebook buffer,
--- the closing fence comes right after it, and must stay on a line of its own.
--- A position past the end of the cell is its end, as for any document, and
--- if the edits leave the text without its last line break, one more edit
--- puts it back, after all of them.
---@param edits lsp.TextEdit[]
---@param cell notebook_lsp.Cell
---@param encoding 'utf-8'|'utf-16'|'utf-32' the server's, which positions count characters in
---@return lsp.TextEdit[]
---@return string text the cell's text once they're applied
local function keep_fence(edits, cell, encoding)
  local last = #cell.lines -- the line after the cell's last line break: the fence's
  local finish = { line = last, character = 0 }
  local function clamp(position)
    return position.line < last and position or finish
  end
  --- The byte of the cell's text where `position`, clamped, is.
  local function offset(position)
    local bytes = 0
    for i = 1, position.line do
      bytes = bytes + #cell.lines[i] + 1
    end
    if position.line < last then
      bytes = bytes + vim.str_byteindex(cell.lines[position.line + 1], encoding, position.character, false)
    end
    return bytes
  end

  local out, spans = like(edits), {}
  for i, edit in ipairs(edits) do
    local range = { start = clamp(edit.range.start), ["end"] = clamp(edit.range["end"]) }
    out[i] = vim.tbl_extend("force", edit, { range = range })
    table.insert(spans, { from = offset(range.start), to = offset(range["end"]), text = edit.newText, index = i })
  end
  -- The text they leave: applied in the order of where they start, then in theirs
  table.sort(spans, function(a, b)
    return a.from < b.from or (a.from == b.from and a.index < b.index)
  end)
  local text, done = {}, 0
  for _, span in ipairs(spans) do
    table.insert(text, cell.text:sub(done + 1, span.from))
    table.insert(text, span.text)
    done = math.max(done, span.to)
  end
  table.insert(text, cell.text:sub(done + 1))
  local result = table.concat(text)
  if result ~= "" and not vim.endswith(result, "\n") then
    table.insert(out, { range = { start = finish, ["end"] = finish }, newText = "\n" })
    result = result .. "\n"
  end
  return out, result
end

--- The lines of a cell's `text`, which ends with a line break unless it's empty.
---@param text string
---@return string[]
local function lines_of(text)
  return text == "" and {} or vim.split(text:sub(1, -2), "\n", { plain = true })
end

--- One batch of edits of `cell` that does what `batches` do one after the
--- other, each to the text the ones before it left: the lines that differ
--- between the cell's text and what they leave.
---@param batches lsp.TextEdit[][]
---@param cell notebook_lsp.Cell
---@param encoding 'utf-8'|'utf-16'|'utf-32' the server's, which positions count characters in
---@return lsp.TextEdit[]
local function in_sequence(batches, cell, encoding)
  local text = cell.text
  for _, batch in ipairs(batches) do
    local current = { id = cell.id, start = cell.start, lines = lines_of(text), text = text }
    text = select(2, keep_fence(batch, current, encoding))
  end
  local lines, edits = lines_of(text), {}
  for _, hunk in
    ipairs(vim.text.diff(cell.text, text, { result_type = "indices" }) --[[@as integer[][] ]])
  do
    local old_start, old_count, new_start, new_count = unpack(hunk)
    -- Lines are 1-based, and a hunk that removes none adds its lines after old_start
    local first = old_count == 0 and old_start or old_start - 1
    table.insert(edits, {
      range = { start = { line = first, character = 0 }, ["end"] = { line = first + old_count, character = 0 } },
      newText = new_count == 0 and "" or table.concat(lines, "\n", new_start, new_start + new_count - 1) .. "\n",
    })
  end
  return edits
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
  if is_position(value) or is_folding_range(value) then
    return where and M.shift(value, where.cell.start) or value
  end
  if vim.islist(value) then
    if where and #value > 0 and vim.iter(value):all(is_text_edit) then
      value = keep_fence(value, where.cell, context.encoding())
    end
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
  -- The document it links to (a LocationLink, a DocumentLink)
  local target = nil ---@type notebook_lsp.Where|false|nil
  local target_uri = value.targetUri or value.target
  if type(target_uri) == "string" then
    target = context.locate(target_uri)
  end
  if inner == false or target == false then
    return nil
  end

  local out = like(value)
  for key, item in pairs(value) do
    if key == "data" or (key == "arguments" and type(value.command) == "string") then
      out[key] = item -- the server's own, which Neovim sends back as it is
    elseif key == "fromRanges" and type(value.from) == "table" then
      -- The ranges of an incoming call are in its caller's document
      local caller = context.locate(value.from.uri)
      out[key] = caller ~= false and M.to_client(item, caller or nil, context) or nil
    elseif key == "uri" then
      out[key] = inner and inner.notebook.uri or item
    elseif key == "targetUri" or (key == "target" and type(item) == "string") then
      out[key] = target and target.notebook.uri or item
    elseif key == "targetRange" or key == "targetSelectionRange" then
      out[key] = M.to_client(item, target, context)
    elseif key == "originSelectionRange" then
      out[key] = M.to_client(item, where, context)
    elseif key == "changes" and type(item) == "table" and not vim.islist(item) then
      out[key] = M.changes(item, context)
    elseif key == "documentChanges" then
      out[key] = M.document_changes(item, context)
    elseif key == "relatedDocuments" and type(item) == "table" then
      out[key] = related_documents(item, context)
    elseif key == "textEdit" and inner and is_text_edit(item) then
      -- A completion item's, which can't become two edits
      local edits = keep_fence({ item }, inner.cell, context.encoding())
      local edit = #edits == 1 and edits[1] or vim.tbl_extend("force", edits[1], { newText = edits[1].newText .. "\n" })
      out[key] = M.to_client(edit, inner, context)
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
--- buffer, where the first of them was. A cell's successive edits, each for
--- the text the ones before left, become one batch that does the same. If the
--- server versioned the cells', it has the buffer's version (its
--- changedtick), which Neovim checks as it applies it.
---
--- Like Neovim does with the edits for an older version of a document, a
--- notebook's are skipped if one of its cells is gone, or changed since the
--- version the server made them for.
---@param changes any[]
---@param context notebook_lsp.Context
---@return any[]
local function notebook_edits(changes, context)
  local out, merged, stale = {}, {}, {} ---@type any[], table<string, lsp.TextDocumentEdit>, table<string, true>
  -- The edits to each notebook's cells, in the order the server sent them: a
  -- cell's may come in several batches, each for what the ones before left
  local edited = {} ---@type table<string, {where: notebook_lsp.Where, batches: lsp.TextEdit[][]}[]>
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
        edited[uri] = {}
        table.insert(out, merged[uri])
      end
      if where then
        if versioned then
          -- Not Neovim's version of it, which is 0 until it changes and never checked then
          merged[uri].textDocument.version = vim.api.nvim_buf_get_changedtick(where.notebook.bufnr)
        end
        local cell = nil
        for _, other in ipairs(edited[uri]) do
          if other.where.cell.id == where.cell.id then
            cell = other
          end
        end
        if not cell then
          cell = { where = where, batches = {} }
          table.insert(edited[uri], cell)
        end
        table.insert(cell.batches, change.edits)
      end
    end
  end

  -- The cells' edits apply together, each cell's to its own lines
  for uri, cells in pairs(edited) do
    for _, cell in ipairs(cells) do
      local edits = cell.batches[1]
      if #cell.batches > 1 then
        local texts = vim.iter(cell.batches):all(function(batch)
          return vim.iter(batch):all(is_text_edit)
        end)
        assert(texts, "notebook-lsp: successive edits of a cell that aren't all text edits")
        edits = in_sequence(cell.batches, cell.where.cell, context.encoding())
      end
      vim.list_extend(merged[uri].edits, M.to_client(edits, cell.where, context) --[[@as lsp.TextEdit[] ]])
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
--- records them. Only the plugin makes cell URIs: a server's own data that
--- happens to have the key doesn't name one.
---@param item table
---@return string? cell_uri
---@return table? original
function M.untag(item)
  local data = item.data
  if type(data) ~= "table" or type(data.item) ~= "table" or type(data[TAG]) ~= "string" then
    return nil, nil
  end
  if not data[TAG]:match("^vscode%-notebook%-cell:.*#c%d+$") then
    return nil, nil
  end
  return data[TAG], data.item
end

return M
