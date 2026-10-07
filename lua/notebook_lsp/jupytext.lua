-- Reads jupytext Markdown notebooks the way jupytext does
-- (jupytext/cell_reader.py, MarkdownCellReader).
local M = {}

---@class notebook_lsp.jupytext.Cell
---@field language string the language written on the fence, e.g. "python" or "bash"
---@field start integer 0-based row of the cell's first line of code
---@field lines string[]

---@class notebook_lsp.jupytext.Notebook
---@field language string the kernel's language
---@field cells notebook_lsp.jupytext.Cell[] code cells, in order

--- Returns nil when `lines` are not a jupytext Markdown notebook, and errors when
--- they are a jupytext notebook in a format this plugin doesn't support.
---@param lines string[]
---@return notebook_lsp.jupytext.Notebook?
function M.read(lines)
  error("notebook-lsp: jupytext.read() is not implemented yet")
end

return M
