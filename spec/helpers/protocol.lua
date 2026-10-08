-- Sets up protocol tests: a fake server registered with `vim.lsp.config`,
-- extended to notebooks, and a project directory to open files in.
local fake_server = require("helpers.fake_server")

local M = {}

M.header = {
  "---",
  "jupyter:",
  "  jupytext:",
  "    text_representation:",
  "      extension: .md",
  "      format_name: markdown",
  "      format_version: '1.3'",
  "      jupytext_version: 1.19.6",
  "  kernelspec:",
  "    display_name: Python 3",
  "    language: python",
  "    name: python3",
  "---",
}

--- A notebook with two Python cells around prose and a bash cell. The rows
--- (0-based) are what most protocol tests check positions against.
M.example = {
  body = {
    "", -- 13
    "# Title", -- 14
    "", -- 15
    "```python", -- 16
    "import os", -- 17: cell 1, line 0
    "x = 1", -- 18: cell 1, line 1
    "```", -- 19
    "", -- 20
    "Prose mentions x.", -- 21
    "", -- 22
    "```bash", -- 23
    "echo hi", -- 24
    "```", -- 25
    "", -- 26
    "```python", -- 27
    "def f():", -- 28: cell 2, line 0
    "    return x", -- 29: cell 2, line 1
    "```", -- 30
  },
  rows = { cell1 = 17, cell2 = 28, prose = 21, cell1_fence = 19 },
  texts = { "import os\nx = 1\n", "def f():\n    return x\n" },
}

--- Lines of a jupytext Markdown notebook with a Python kernel: the header, then `body`.
---@param body string[]
---@return string[]
function M.notebook(body)
  return vim.list_extend(vim.deepcopy(M.header), body)
end

---@class ProtocolEnv
---@field name string the `vim.lsp.config` name of the fake server
---@field server FakeServer
---@field dir string project directory, with a pyproject.toml as root marker

local current ---@type ProtocolEnv?

--- Starts the environment of a test: a fake Python server, configured the way
--- nvim-lspconfig would, extended to notebooks the way plugin/ extends the
--- servers it knows, and enabled. Stop it with M.stop() in after_each.
---@param opts? {capabilities?: lsp.ServerCapabilities, handlers?: table<string, fun(params: any): any>, enable?: boolean}
---@return ProtocolEnv
function M.start(opts)
  opts = opts or {}
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local env = {
    -- unique for the whole run: busted reloads this module for every spec file,
    -- and vim.lsp.config() would merge into an earlier file's config of the same name
    name = ("fake_%d"):format(vim.uv.hrtime()),
    server = fake_server.new(opts),
    dir = assert(vim.uv.fs_realpath(dir)),
  }
  current = env -- before anything can fail, so that M.stop() cleans up
  vim.fn.writefile({}, env.dir .. "/pyproject.toml")
  vim.lsp.config(env.name, { cmd = env.server.cmd, filetypes = { "python" }, root_markers = { "pyproject.toml" } })
  require("notebook_lsp").extend(env.name, { "python" })
  if opts.enable ~= false then
    vim.lsp.enable(env.name)
  end
  return env
end

--- Stops the environment of the running test, also when M.start() failed half-way.
function M.stop()
  local env = assert(current, "no test environment to stop")
  current = nil
  vim.lsp.enable(env.name, false)
  for _, client in ipairs(vim.lsp.get_clients({ name = env.name })) do
    client:stop(true)
  end
  vim.cmd("silent! %bwipeout!")
  vim.fn.delete(env.dir, "rf")
end

--- Writes `lines` to `filename` in the project, opens it and returns its buffer.
---@param env ProtocolEnv
---@param filename string
---@param lines string[]
---@return integer bufnr
function M.open(env, filename, lines)
  local path = env.dir .. "/" .. filename
  vim.fn.writefile(lines, path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

--- Waits until the fake server's client is attached to `bufnr` and initialized, and returns it.
---@param env ProtocolEnv
---@param bufnr integer
---@return vim.lsp.Client
function M.wait_attached(env, bufnr)
  local client
  local attached = vim.wait(1000, function()
    client = vim.lsp.get_clients({ bufnr = bufnr, name = env.name })[1]
    return client ~= nil and client.initialized == true
  end, 5)
  assert(attached, ("%s did not attach to buffer %d"):format(env.name, bufnr))
  return client
end

--- Opens the example notebook, waits for the server to receive it, and returns
--- the buffer and the URIs the server knows its two Python cells by.
---@param env ProtocolEnv
---@return integer bufnr, string[] cell_uris
function M.open_example(env)
  local bufnr = M.open(env, "notebook.md", M.notebook(M.example.body))
  M.wait_attached(env, bufnr)
  local opened = env.server:wait_for("notebookDocument/didOpen")
  local uris = vim.tbl_map(function(document)
    return document.uri
  end, opened.cellTextDocuments)
  return bufnr, uris
end

--- Applies LSP content changes (full or ranged, ASCII text) to `text`.
---@param text string
---@param changes lsp.TextDocumentContentChangeEvent[]
---@return string
function M.apply_changes(text, changes)
  for _, change in ipairs(changes) do
    if change.range then
      local lines = vim.split(text, "\n", { plain = true })
      local function offset(position)
        local before = 0
        for i = 1, position.line do
          before = before + #lines[i] + 1
        end
        return before + position.character
      end
      text = text:sub(1, offset(change.range.start)) .. change.text .. text:sub(offset(change.range["end"]) + 1)
    else
      text = change.text
    end
  end
  return text
end

--- A 0-based position: `row` and the column of `needle` in that row's text.
---@param bufnr integer
---@param row integer
---@param needle string
---@return lsp.Position
function M.position(bufnr, row, needle)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1]
  local col = assert(line:find(needle, 1, true), ("%q not found in row %d: %q"):format(needle, row, line))
  return { line = row, character = col - 1 }
end

---@param bufnr integer
---@return string[]
function M.lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
end

return M
