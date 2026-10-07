-- Pinned external tools for the oracle and end-to-end tests, run through uvx.
local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

-- uv's cache lives in the project: lux gives tests a fresh HOME on every run,
-- which would otherwise download every tool again each time.
M.env = {
  UV_CACHE_DIR = M.root .. "/.tests/uv/cache",
  UV_PYTHON_INSTALL_DIR = M.root .. "/.tests/uv/python",
}

M.jupytext = { "uvx", "--from", "jupytext==1.19.6", "jupytext" }

M.servers = {
  basedpyright = { "uvx", "--from", "basedpyright==1.40.2", "basedpyright-langserver", "--stdio" },
  ruff = { "uvx", "ruff@0.16.10", "server" },
  ty = { "uvx", "ty@0.0.84", "server" },
}

return M
