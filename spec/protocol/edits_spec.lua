local protocol = require("helpers.protocol")

local rows = protocol.example.rows

---@return lsp.TextEdit
local function edit(line, character, length, new_text)
  return {
    range = {
      start = { line = line, character = character },
      ["end"] = { line = line, character = character + length },
    },
    newText = new_text,
  }
end

--- Deletes line `line`, including its line break.
---@return lsp.TextEdit
local function delete_line(line)
  return {
    range = { start = { line = line, character = 0 }, ["end"] = { line = line + 1, character = 0 } },
    newText = "",
  }
end

describe("edits from the server", function()
  local env ---@type ProtocolEnv
  local handlers ---@type table<string, fun(params: any): any>

  before_each(function()
    handlers = {}
    env = protocol.start({ handlers = handlers })
  end)

  after_each(function()
    protocol.stop()
  end)

  --- Waits until row `row` of `bufnr` reads `text`.
  local function wait_row(bufnr, row, text)
    local changed = vim.wait(1000, function()
      return protocol.lines(bufnr)[row + 1] == text
    end)
    assert.equal(text, protocol.lines(bufnr)[row + 1], changed and nil or "the edit was not applied")
  end

  it("applies a rename that changes several cells (documentChanges)", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/rename"] = function()
      return {
        documentChanges = {
          { textDocument = { uri = cells[1], version = 1 }, edits = { edit(1, 0, 1, "value") } },
          { textDocument = { uri = cells[2], version = 1 }, edits = { edit(1, 11, 1, "value") } },
        },
      }
    end
    vim.api.nvim_win_set_cursor(0, { rows.cell1 + 2, 0 })
    vim.lsp.buf.rename("value", { name = env.name })
    wait_row(bufnr, rows.cell2 + 1, "    return value")
    assert.equal("value = 1", protocol.lines(bufnr)[rows.cell1 + 2])
    assert.equal("Prose mentions x.", protocol.lines(bufnr)[rows.prose + 1])
  end)

  it("applies a rename that changes several cells (changes)", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/rename"] = function()
      return { changes = { [cells[1]] = { edit(1, 0, 1, "value") }, [cells[2]] = { edit(1, 11, 1, "value") } } }
    end
    vim.api.nvim_win_set_cursor(0, { rows.cell1 + 2, 0 })
    vim.lsp.buf.rename("value", { name = env.name })
    wait_row(bufnr, rows.cell2 + 1, "    return value")
    assert.equal("value = 1", protocol.lines(bufnr)[rows.cell1 + 2])
  end)

  it("applies edits the server sends with workspace/applyEdit", function()
    local bufnr, cells = protocol.open_example(env)
    local result = env.server:request("workspace/applyEdit", {
      edit = { changes = { [cells[1]] = { edit(0, 0, 9, "import sys") } } },
    })
    assert.same({ applied = true }, result)
    assert.equal("import sys", protocol.lines(bufnr)[rows.cell1 + 1])
  end)

  it("inserts at the end of a cell before its closing fence", function()
    local bufnr, cells = protocol.open_example(env)
    env.server:request("workspace/applyEdit", { edit = { changes = { [cells[1]] = { edit(2, 0, 0, "y = 2\n") } } } })
    assert.same(
      { "import os", "x = 1", "y = 2", "```" },
      vim.list_slice(protocol.lines(bufnr), rows.cell1 + 1, rows.cell1 + 4)
    )
  end)

  it("applies a code action's edit inside its cell", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/codeAction"] = function()
      return { { title = "Remove unused import", edit = { changes = { [cells[1]] = { delete_line(0) } } } } }
    end
    vim.api.nvim_win_set_cursor(0, { rows.cell1 + 1, 7 })
    vim.lsp.buf.code_action({ apply = true })
    wait_row(bufnr, rows.cell1, "x = 1")
  end)

  it("resolves a code action in the cell it came from", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/codeAction"] = function()
      return { { title = "Remove unused import", data = { opaque = true } } }
    end
    handlers["codeAction/resolve"] = function(action)
      return vim.tbl_extend("force", action, { edit = { changes = { [cells[1]] = { delete_line(0) } } } })
    end
    vim.api.nvim_win_set_cursor(0, { rows.cell1 + 1, 7 })
    vim.lsp.buf.code_action({ apply = true })
    wait_row(bufnr, rows.cell1, "x = 1")
    assert.same({ opaque = true }, env.server:wait_for("codeAction/resolve").data)
  end)

  -- Neovim resolves an action with data even when it has an edit already, as ruff's have.
  it("resolves a code action that has an edit as the server gave it", function()
    local bufnr, cells = protocol.open_example(env)
    local action = {
      title = "Remove unused import",
      data = cells[1],
      edit = { changes = { [cells[1]] = { delete_line(0) } } },
    }
    handlers["textDocument/codeAction"] = function()
      return { action }
    end
    vim.api.nvim_win_set_cursor(0, { rows.cell1 + 1, 7 })
    vim.lsp.buf.code_action({ apply = true })
    wait_row(bufnr, rows.cell1, "x = 1")
    assert.same(action, env.server:wait_for("codeAction/resolve"))
  end)
end)
