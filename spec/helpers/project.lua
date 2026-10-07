-- Copies of the fixture projects in spec/fixtures/projects, so tests can edit them.
local tools = require("helpers.tools")

local M = {}

--- Copies the fixture project `name` to a new temporary directory, and returns
--- its real path (servers report real paths, and /tmp is a symlink on macOS).
---@param name string
---@return string
function M.copy(name)
  local source = tools.root .. "/spec/fixtures/projects/" .. name
  local target = vim.fn.tempname()
  vim.fn.mkdir(target, "p")
  for file, kind in vim.fs.dir(source) do
    assert(kind == "file", "fixture projects are flat: " .. file)
    vim.fn.writefile(vim.fn.readfile(source .. "/" .. file, "b"), target .. "/" .. file, "b")
  end
  return assert(vim.uv.fs_realpath(target))
end

return M
