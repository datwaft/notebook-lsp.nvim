-- Checks the reader's expected cells (spec/fixtures/jupytext/expected.lua)
-- against what jupytext itself produces, so the unit tests encode jupytext's
-- behaviour rather than our reading of its source.
local expected = require("fixtures.jupytext.expected")
local tools = require("helpers.tools")

--- Sources of the code cells jupytext produces for `file`.
local function jupytext_code_cells(file)
  local command = vim.list_extend(vim.deepcopy(tools.jupytext), { "--to", "ipynb", "--output", "-", file })
  local result = vim.system(command, { env = tools.env, text = true }):wait()
  assert(result.code == 0, result.stderr)
  local sources = {}
  for _, cell in ipairs(vim.json.decode(result.stdout).cells) do
    if cell.cell_type == "code" then
      table.insert(sources, type(cell.source) == "table" and table.concat(cell.source) or cell.source)
    end
  end
  return sources
end

describe("jupytext agrees with the expected cells", function()
  for _, case in ipairs(expected) do
    it("for " .. case.file, function()
      -- jupytext keeps cells in other languages as code cells of the kernel's
      -- language, with a cell magic such as %%bash in front
      local sources = vim.tbl_map(function(cell)
        local magic = cell.language ~= case.notebook.language and ("%%" .. cell.language .. "\n") or ""
        return magic .. table.concat(cell.lines, "\n")
      end, case.notebook.cells)
      assert.same(sources, jupytext_code_cells("spec/fixtures/jupytext/" .. case.file))
    end)
  end
end)
