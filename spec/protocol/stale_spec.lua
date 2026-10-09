local protocol = require("helpers.protocol")

local rows = protocol.example.rows

---@return lsp.Range
local function range(line, character, length)
  return { start = { line = line, character = character }, ["end"] = { line = line, character = character + length } }
end

---@return lsp.TextEdit
local function edit(line, character, length, new_text)
  return { range = range(line, character, length), newText = new_text }
end

-- What Neovim prints when it skips the edits for an older version of a buffer
local function skipped(bufnr)
  return { "Buffer ", vim.uri_from_bufnr(bufnr), " newer than edits." }
end

describe("answers about cells that changed or are gone", function()
  local env ---@type ProtocolEnv
  local handlers ---@type table<string, fun(params: any): any>
  local printed ---@type string[][]
  local print = _G.print

  before_each(function()
    handlers = {}
    printed = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.print = function(...)
      table.insert(printed, { ... })
    end
    env = protocol.start({ handlers = handlers })
  end)

  after_each(function()
    _G.print = print
    protocol.stop()
  end)

  --- Deletes the second Python cell, with its fences and the blank line before it.
  local function delete_cell2(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, rows.cell2 - 2, rows.cell2 + 3, true, {})
  end

  --- Sends `method` from the notebook buffer and returns the result.
  local function request(bufnr, method, params)
    local client = protocol.wait_attached(env, bufnr)
    params = vim.tbl_extend("force", { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }, params)
    local response = client:request_sync(method, params, 1000, bufnr)
    assert(response and not response.err, vim.inspect(response))
    return response.result
  end

  --- Renames at row `row` of the notebook and waits for the server's edits to
  --- be applied or skipped.
  local function rename(row)
    vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
    vim.lsp.buf.rename("value", { name = env.name })
    env.server:wait_for("textDocument/rename")
    vim.wait(100) -- for the answer to be applied, if it is
  end

  it("answers nothing about a cell deleted while the server answered", function()
    local bufnr = protocol.open_example(env)
    handlers["textDocument/hover"] = function()
      vim.schedule(function()
        delete_cell2(bufnr)
      end)
      return { contents = "x: int", range = range(1, 11, 1) }
    end
    local position = protocol.position(bufnr, rows.cell2 + 1, "x")
    assert.is_nil(request(bufnr, "textDocument/hover", { position = position }))
  end)

  it("drops locations in a deleted cell and keeps the rest", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/references"] = function()
      vim.schedule(function()
        delete_cell2(bufnr)
      end)
      return { { uri = cells[1], range = range(1, 0, 1) }, { uri = cells[2], range = range(1, 11, 1) } }
    end
    local position = protocol.position(bufnr, rows.cell1 + 1, "x")
    local result = request(bufnr, "textDocument/references", { position = position, context = {} })
    assert.same({ { uri = vim.uri_from_bufnr(bufnr), range = range(rows.cell1 + 1, 0, 1) } }, result)
  end)

  it("drops a single location in a deleted cell", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/definition"] = function()
      vim.schedule(function()
        delete_cell2(bufnr)
      end)
      return { uri = cells[2], range = range(0, 4, 1) }
    end
    local position = protocol.position(bufnr, rows.cell1 + 1, "x")
    assert.is_nil(request(bufnr, "textDocument/definition", { position = position }))
  end)

  it("drops location links to a deleted cell", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/definition"] = function()
      vim.schedule(function()
        delete_cell2(bufnr)
      end)
      return {
        {
          originSelectionRange = range(1, 0, 1),
          targetUri = cells[2],
          targetRange = range(0, 0, 8),
          targetSelectionRange = range(0, 4, 1),
        },
      }
    end
    local position = protocol.position(bufnr, rows.cell1 + 1, "x")
    assert.same({}, request(bufnr, "textDocument/definition", { position = position }))
  end)

  it("drops document links to a deleted cell and resolves the rest as the server gave them", function()
    local bufnr, cells = protocol.open_example(env)
    local other = { range = range(1, 0, 1), target = "https://example.com", data = { link = 2 } }
    handlers["textDocument/documentLink"] = function(params)
      if params.textDocument.uri == cells[1] then
        vim.schedule(function()
          delete_cell2(bufnr)
        end)
        return { { range = range(0, 7, 2), target = cells[2], data = { link = 1 } }, other }
      end
    end
    local links = request(bufnr, "textDocument/documentLink", {})
    assert.equal(1, #links)
    assert.same(range(rows.cell1 + 1, 0, 1), links[1].range)
    local client = protocol.wait_attached(env, bufnr)
    assert(client:request_sync("documentLink/resolve", links[1], 1000, bufnr))
    assert.same(other, env.server:wait_for("documentLink/resolve"))
  end)

  it("drops related information in a deleted cell from a diagnostic", function()
    local bufnr, cells = protocol.open_example(env)
    delete_cell2(bufnr)
    env.server:notify("textDocument/publishDiagnostics", {
      uri = cells[1],
      diagnostics = {
        {
          range = range(1, 0, 1),
          message = "x is redefined",
          relatedInformation = { { location = { uri = cells[2], range = range(0, 4, 1) }, message = "here" } },
        },
      },
    })
    local shown = vim.diagnostic.get(bufnr)
    assert.equal(1, #shown)
    assert.same({}, shown[1].user_data.lsp.relatedInformation)
  end)

  it("resolves an item of a deleted cell to itself, without asking the server", function()
    local bufnr = protocol.open_example(env)
    handlers["textDocument/completion"] = function()
      return { { label = "xor", data = { opaque = true } } }
    end
    local position = protocol.position(bufnr, rows.cell2 + 1, "x")
    local item = request(bufnr, "textDocument/completion", { position = position })[1]
    delete_cell2(bufnr)
    local client = protocol.wait_attached(env, bufnr)
    local response = assert(client:request_sync("completionItem/resolve", item, 1000, bufnr))
    assert.same(item, response.result)
    assert.same({}, env.server:received("completionItem/resolve"))
  end)

  it("skips a notebook's edits when one of its cells was deleted, like Neovim", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/rename"] = function()
      vim.schedule(function()
        delete_cell2(bufnr)
      end)
      return {
        documentChanges = {
          { textDocument = { uri = cells[1], version = 1 }, edits = { edit(1, 0, 1, "value") } },
          { textDocument = { uri = cells[2], version = 1 }, edits = { edit(1, 11, 1, "value") } },
        },
      }
    end
    rename(rows.cell1 + 1)
    assert.equal("x = 1", protocol.lines(bufnr)[rows.cell1 + 2])
    assert.same({ skipped(bufnr) }, printed)
  end)

  it("skips a notebook's unversioned edits when one of its cells was deleted", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/rename"] = function()
      vim.schedule(function()
        delete_cell2(bufnr)
      end)
      return { changes = { [cells[1]] = { edit(1, 0, 1, "value") }, [cells[2]] = { edit(1, 11, 1, "value") } } }
    end
    rename(rows.cell1 + 1)
    assert.equal("x = 1", protocol.lines(bufnr)[rows.cell1 + 2])
    assert.same({ skipped(bufnr) }, printed)
  end)

  it("skips a notebook's edits when one of its cells changed since their version", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/rename"] = function()
      vim.schedule(function()
        vim.api.nvim_buf_set_lines(bufnr, rows.cell2 + 1, rows.cell2 + 2, true, { "    return x + 1" })
      end)
      return {
        documentChanges = {
          { textDocument = { uri = cells[1], version = 1 }, edits = { edit(1, 0, 1, "value") } },
          { textDocument = { uri = cells[2], version = 1 }, edits = { edit(1, 11, 1, "value") } },
        },
      }
    end
    rename(rows.cell1 + 1)
    assert.equal("x = 1", protocol.lines(bufnr)[rows.cell1 + 2])
    assert.equal("    return x + 1", protocol.lines(bufnr)[rows.cell2 + 2])
    assert.same({ skipped(bufnr) }, printed)
  end)

  it("still applies the edits to other documents", function()
    local bufnr, cells = protocol.open_example(env)
    local module = protocol.open(env, "module.py", { "from notebook import x" })
    vim.cmd.buffer(bufnr)
    handlers["textDocument/rename"] = function()
      vim.schedule(function()
        delete_cell2(bufnr)
      end)
      return {
        changes = {
          [cells[2]] = { edit(1, 11, 1, "value") },
          [vim.uri_from_bufnr(module)] = { edit(0, 21, 1, "value") },
        },
      }
    end
    rename(rows.cell1 + 1)
    assert.same({ "from notebook import value" }, protocol.lines(module))
    assert.same({ skipped(bufnr) }, printed)
  end)

  it("versions a notebook's edits with the buffer's, so Neovim skips them once it changes", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/codeAction"] = function()
      return {
        {
          title = "Rename x",
          edit = {
            documentChanges = {
              { textDocument = { uri = cells[1], version = 1 }, edits = { edit(1, 0, 1, "value") } },
            },
          },
        },
      }
    end
    local actions = request(bufnr, "textDocument/codeAction", {
      range = range(rows.cell1 + 1, 0, 1),
      context = { diagnostics = {} },
    })
    -- The user edits the notebook before choosing the action
    vim.api.nvim_buf_set_lines(bufnr, rows.prose, rows.prose + 1, true, { "Prose mentions x twice." })
    vim.lsp.util.apply_workspace_edit(actions[1].edit, "utf-16")
    assert.equal("x = 1", protocol.lines(bufnr)[rows.cell1 + 2])
    assert.same({ skipped(bufnr) }, printed)
  end)

  it("applies unversioned edits to a cell that changed, like Neovim", function()
    local bufnr, cells = protocol.open_example(env)
    vim.api.nvim_buf_set_lines(bufnr, rows.cell1, rows.cell1 + 1, true, { "import sys" })
    local result = env.server:request("workspace/applyEdit", {
      edit = { changes = { [cells[1]] = { edit(1, 0, 1, "value") } } },
    })
    assert.same({ applied = true }, result)
    assert.equal("value = 1", protocol.lines(bufnr)[rows.cell1 + 2])
  end)

  it("refuses an edit the server sends that touches a deleted cell", function()
    local bufnr, cells = protocol.open_example(env)
    delete_cell2(bufnr)
    local result = env.server:request("workspace/applyEdit", {
      edit = { changes = { [cells[1]] = { edit(1, 0, 1, "value") }, [cells[2]] = { edit(1, 11, 1, "value") } } },
    })
    assert.is_false(result.applied)
    assert.is_string(result.failureReason)
    assert.equal("x = 1", protocol.lines(bufnr)[rows.cell1 + 2])
    assert.same({}, printed)
  end)

  it("treats the cells of a wiped notebook as gone", function()
    local bufnr, cells = protocol.open_example(env)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    env.server:wait_for("notebookDocument/didClose")
    -- What the server sent before it saw the notebook close
    env.server:notify("textDocument/publishDiagnostics", {
      uri = cells[1],
      diagnostics = { { range = range(1, 0, 1), message = "x is unused" } },
    })
    assert.same({ success = false }, env.server:request("window/showDocument", { uri = cells[1] }))
  end)
end)
