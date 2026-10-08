-- A notebook buffer: its code cells in the kernel's language, as the jupytext
-- reader finds them, each with an id that stays with the cell while the buffer
-- changes around it. The id is an extmark on the cell's opening fence, so a
-- cell keeps it when lines are added or removed elsewhere, and loses it when
-- its fence is deleted.
local jupytext = require("notebook_lsp.jupytext")

local M = {}

local namespace = vim.api.nvim_create_namespace("notebook_lsp.cells")

---@class notebook_lsp.Cell
---@field id integer unique in the buffer, never reused
---@field start integer 0-based row of the cell's first line of code
---@field lines string[]
---@field text string what the server sees: the lines, each ending with a newline

---@class notebook_lsp.Notebook
---@field bufnr integer
---@field uri string the Markdown buffer's URI, which Neovim's messages about it carry
---@field notebook_uri string the notebook document's URI: a .ipynb file next to the Markdown file
---@field language string the kernel's language, as jupytext names it
---@field filetype string Neovim's filetype for it, which is also the cells' languageId
---@field private cells notebook_lsp.Cell[]
---@field private changedtick integer?
---@field private next_id integer
local Notebook = {}
Notebook.__index = Notebook

---@param bufnr integer
---@param language string
---@param filetype string
---@return notebook_lsp.Notebook
function M.new(bufnr, language, filetype)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  local uri = vim.uri_from_bufnr(bufnr)
  return setmetatable({
    bufnr = bufnr,
    uri = uri,
    notebook_uri = vim.uri_from_fname(vim.uri_to_fname(uri) .. ".ipynb"),
    language = language,
    filetype = filetype,
    cells = {},
    next_id = 1,
  }, Notebook)
end

--- The URI of the cell document with `id`.
---@param id integer
---@return string
function Notebook:cell_uri(id)
  return ("%s#c%d"):format((self.notebook_uri:gsub("^file:", "vscode-notebook-cell:")), id)
end

--- The cell that `uri` names, if it names one of this notebook's cells; false
--- if it names a cell that no longer exists.
---@param uri string
---@return notebook_lsp.Cell|false|nil
function Notebook:cell_of(uri)
  local id = tonumber(uri:match("#c(%d+)$"))
  if not id or self:cell_uri(id) ~= uri then
    return nil
  end
  for _, cell in ipairs(self:read()) do
    if cell.id == id then
      return cell
    end
  end
  return false
end

--- The cell whose code includes row `row`, if any.
---@param row integer 0-based
---@return notebook_lsp.Cell?
function Notebook:cell_at(row)
  for _, cell in ipairs(self:read()) do
    if row >= cell.start and row < cell.start + #cell.lines then
      return cell
    end
  end
end

--- The code cells in the buffer as it is now, in order.
---@return notebook_lsp.Cell[]
function Notebook:read()
  local changedtick = vim.api.nvim_buf_get_changedtick(self.bufnr)
  if changedtick == self.changedtick then
    return self.cells
  end
  self.changedtick = changedtick

  -- The cells' ids, by the row of their opening fence
  local ids = {} ---@type table<integer, integer>
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(self.bufnr, namespace, 0, -1, { details = true })) do
    local id, row, details = mark[1], mark[2], mark[4] or {}
    if details.invalid or ids[row] then
      vim.api.nvim_buf_del_extmark(self.bufnr, namespace, id)
    else
      ids[row] = id
    end
  end

  local notebook = jupytext.read(vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, true))
  local cells, kept = {}, {} ---@type notebook_lsp.Cell[], table<integer, true>
  for _, cell in ipairs(notebook and notebook.cells or {}) do
    if cell.language == self.language then
      local fence = cell.start - 1
      local id = ids[fence]
      if not id then
        local line = vim.api.nvim_buf_get_lines(self.bufnr, fence, fence + 1, true)[1]
        -- Covering the whole fence, so that deleting the fence invalidates it
        id = vim.api.nvim_buf_set_extmark(self.bufnr, namespace, fence, 0, {
          id = self.next_id,
          end_row = fence,
          end_col = #line,
          invalidate = true,
          undo_restore = false,
        })
        self.next_id = self.next_id + 1
      end
      kept[id] = true
      local text = #cell.lines == 0 and "" or table.concat(cell.lines, "\n") .. "\n"
      table.insert(cells, { id = id, start = cell.start, lines = cell.lines, text = text })
    end
  end
  for _, id in pairs(ids) do
    if not kept[id] then
      vim.api.nvim_buf_del_extmark(self.bufnr, namespace, id)
    end
  end

  self.cells = cells
  return cells
end

return M
