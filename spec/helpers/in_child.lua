-- Runs inside the child Neovim of the end-to-end tests (see helpers.child).
-- Everything acts on the current buffer and goes through Neovim's own LSP
-- functions (vim.lsp.buf.*), the way a user would.
local tools = require("helpers.tools")

local M = {}

--- Loads the plugin the way Neovim does at startup, configures the pinned
--- servers the way nvim-lspconfig does (lsp/<name>.lua on the runtimepath),
--- and enables them.
---@param servers string[]
function M.setup(servers)
  vim.cmd("filetype on")
  -- An error must fail the test (see M.errors), not wait at a prompt
  vim.o.more = false
  vim.cmd.runtime("plugin/notebook_lsp.lua")
  local runtime = vim.fn.tempname()
  vim.fn.mkdir(runtime .. "/lsp", "p")
  for _, name in ipairs(servers) do
    local config = {
      cmd = tools.servers[name],
      cmd_env = tools.env,
      filetypes = { "python" },
      root_markers = { "pyproject.toml" },
    }
    local lines = vim.split("return " .. vim.inspect(config), "\n", { plain = true })
    vim.fn.writefile(lines, ("%s/lsp/%s.lua"):format(runtime, name))
  end
  vim.opt.runtimepath:append(runtime)
  vim.lsp.enable(servers)
end

--- Errors printed so far, such as those of callbacks, which no call returns.
---@return string[]
function M.errors()
  local messages = vim.split(vim.fn.execute("messages"), "\n", { plain = true })
  return vim.tbl_filter(function(line)
    return line:match("^E%d+:") ~= nil or line:find("stack traceback", 1, true) ~= nil
  end, messages)
end

---@param path string
function M.edit(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
end

--- Names of the initialized clients attached to the current buffer, sorted.
---@return string[]
function M.attached()
  local names = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
    if client.initialized then
      table.insert(names, client.name)
    end
  end
  table.sort(names)
  return names
end

--- Whether exactly the clients `names` (sorted) are attached and initialized.
---@param names string[]
function M.attached_exactly(names)
  return vim.deep_equal(M.attached(), names)
end

--- Number of LSP clients running in the whole session.
function M.client_count()
  return #vim.lsp.get_clients()
end

---@return string[]
function M.lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, true)
end

---@return string
function M.text()
  return table.concat(M.lines(), "\n")
end

--- Diagnostics of the current buffer, with the text of the line they are on.
---@return {line: string, row: integer, source: string, message: string}[]
function M.diagnostics()
  local lines = M.lines()
  return vim.tbl_map(function(diagnostic)
    return {
      line = lines[diagnostic.lnum + 1] or "",
      row = diagnostic.lnum,
      source = diagnostic.source,
      message = diagnostic.message,
    }
  end, vim.diagnostic.get(0))
end

--- Whether a diagnostic whose message contains `pattern` is on the line containing `needle`.
---@param needle string plain text
---@param pattern string Lua pattern
function M.has_diagnostic(needle, pattern)
  for _, diagnostic in ipairs(M.diagnostics()) do
    if diagnostic.line:find(needle, 1, true) and diagnostic.message:find(pattern) then
      return true
    end
  end
  return false
end

--- Whether any diagnostic is on the line containing `needle`.
---@param needle string plain text
function M.has_any_diagnostic(needle)
  return M.has_diagnostic(needle, "")
end

--- Whether no diagnostic is on the line containing `needle` (or the line is gone).
---@param needle string plain text
function M.has_no_diagnostic(needle)
  return not M.has_any_diagnostic(needle)
end

--- 0-based row and column of the first occurrence of `needle` in the buffer.
local function find(needle)
  for i, line in ipairs(M.lines()) do
    local col = line:find(needle, 1, true)
    if col then
      return i - 1, col - 1
    end
  end
  error(("not found in the buffer: %q"):format(needle))
end

--- Puts the cursor at `needle` plus `offset` columns.
---@param needle string
---@param offset? integer
function M.cursor(needle, offset)
  local row, col = find(needle)
  vim.api.nvim_win_set_cursor(0, { row + 1, col + (offset or 0) })
end

--- Sends `method` with the position of `needle` (plus `offset` columns) to the
--- client named `client_name`, and returns the result.
---@return any
local function request(client_name, method, needle, offset)
  local row, col = find(needle)
  local client = assert(vim.lsp.get_clients({ bufnr = 0, name = client_name })[1], client_name .. " not attached")
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(0) },
    position = { line = row, character = col + (offset or 0) },
  }
  local response = assert(client:request_sync(method, params, 10000, 0), method .. " timed out")
  assert(not response.err, vim.inspect(response.err))
  return response.result
end

--- Hover text at `needle`, or nil.
function M.hover(client_name, needle, offset)
  local result = request(client_name, "textDocument/hover", needle, offset)
  return result and result.contents.value
end

--- Where the definition of the symbol at `needle` is: file name and 0-based row.
---@return {file: string, row: integer}[]
function M.definition(client_name, needle, offset)
  local result = request(client_name, "textDocument/definition", needle, offset)
  return vim.tbl_map(function(location)
    return {
      file = vim.fs.basename(vim.uri_to_fname(location.targetUri or location.uri)),
      row = (location.targetSelectionRange or location.range).start.line,
    }
  end, vim.islist(result) and result or { result })
end

--- Completes at the end of `needle` with the item labelled `label`, applying
--- its edits the way a completion plugin would (resolving it first if needed).
function M.complete(client_name, needle, label)
  local result = request(client_name, "textDocument/completion", needle, #needle)
  local item
  for _, candidate in ipairs(result.items or result) do
    if candidate.label == label then
      item = candidate
      break
    end
  end
  assert(item, "no completion item " .. label)
  local client = vim.lsp.get_clients({ bufnr = 0, name = client_name })[1]
  if not item.additionalTextEdits then
    item = assert(client:request_sync("completionItem/resolve", item, 10000, 0)).result
  end
  local edit = item.textEdit
  if not edit then
    -- Without a text edit, the item replaces the word being typed
    local row, col = find(needle)
    local finish = { line = row, character = col + #needle }
    local start = { line = row, character = finish.character - #needle:match("[%w_]*$") }
    edit = { range = { start = start, ["end"] = finish }, newText = item.insertText or item.label }
  end
  local edits = { { range = edit.range or edit.replace, newText = edit.newText } }
  vim.list_extend(edits, item.additionalTextEdits or {})
  vim.lsp.util.apply_text_edits(edits, vim.api.nvim_get_current_buf(), client.offset_encoding)
end

--- Applies the code action of `client_name` whose title matches `pattern`, with
--- the cursor at `needle` plus `offset` columns, through vim.lsp.buf.code_action().
--- Returns the titles offered.
---@return string[]
function M.code_action(client_name, needle, offset, pattern)
  M.cursor(needle, offset)
  local before, offered = M.text(), {}
  vim.lsp.buf.code_action({
    apply = true,
    filter = function(action, client_id)
      local name = vim.lsp.get_client_by_id(client_id).name
      table.insert(offered, name .. ": " .. action.title)
      return name == client_name and action.title:find(pattern) ~= nil
    end,
  })
  vim.wait(10000, function()
    return M.text() ~= before
  end)
  return offered
end

--- Formats the buffer with `client_name` through vim.lsp.buf.format().
function M.format(client_name)
  vim.lsp.buf.format({ name = client_name, timeout_ms = 10000 })
end

--- Renames the symbol at `needle` through vim.lsp.buf.rename(), and waits for
--- the buffer `wait_path` (default: current) to change.
function M.rename(client_name, needle, new_name, wait_path)
  M.cursor(needle)
  local bufnr = wait_path and vim.fn.bufnr(wait_path) or vim.api.nvim_get_current_buf()
  local before = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
  vim.lsp.buf.rename(new_name, {
    filter = function(client)
      return client.name == client_name
    end,
  })
  vim.wait(10000, function()
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n") ~= before
  end)
end

--- Text of the buffer of `path`.
function M.text_of(path)
  return table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr(path), 0, -1, true), "\n")
end

--- Replaces 0-based rows [start, end_) with `lines`.
function M.set_lines(start, end_, lines)
  vim.api.nvim_buf_set_lines(0, start, end_, true, lines)
end

--- 0-based row of the first line containing `needle`.
function M.row(needle)
  return (find(needle))
end

return M
