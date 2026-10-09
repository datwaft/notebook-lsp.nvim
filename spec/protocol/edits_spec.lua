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

  -- Like Neovim does for a document's: each applies to what the ones before it left
  describe("applies a cell's successive edits one after the other", function()
    it("inserting a line, then changing the line after it", function()
      local bufnr, uris = protocol.open_example(env)
      local result = env.server:request("workspace/applyEdit", {
        edit = {
          documentChanges = {
            { textDocument = { uri = uris[1], version = 1 }, edits = { edit(0, 0, 0, "new = 0\n") } },
            { textDocument = { uri = uris[1], version = 1 }, edits = { edit(1, 7, 2, "sys") } },
          },
        },
      })
      assert.same({ applied = true }, result)
      assert.same(
        { "new = 0", "import sys", "x = 1", "```" },
        vim.list_slice(protocol.lines(bufnr), rows.cell1 + 1, rows.cell1 + 4)
      )
    end)

    it("with another cell's edits in between", function()
      local bufnr, uris = protocol.open_example(env)
      local result = env.server:request("workspace/applyEdit", {
        edit = {
          documentChanges = {
            { textDocument = { uri = uris[1], version = 1 }, edits = { edit(0, 0, 0, "new = 0\n") } },
            { textDocument = { uri = uris[2], version = 1 }, edits = { edit(1, 11, 1, "y") } },
            { textDocument = { uri = uris[1], version = 1 }, edits = { edit(1, 7, 2, "sys") } },
          },
        },
      })
      assert.same({ applied = true }, result)
      local lines = protocol.lines(bufnr)
      assert.same({ "new = 0", "import sys", "x = 1", "```" }, vim.list_slice(lines, rows.cell1 + 1, rows.cell1 + 4))
      assert.equal("    return y", lines[rows.cell2 + 3])
    end)

    -- Neovim makes \r\n and \r line breaks before it applies an edit
    it("inserting a line ending with a carriage return, then changing the line after it", function()
      local bufnr, uris = protocol.open_example(env)
      local result = env.server:request("workspace/applyEdit", {
        edit = {
          documentChanges = {
            { textDocument = { uri = uris[1], version = 1 }, edits = { edit(0, 0, 0, "new = 0\r") } },
            { textDocument = { uri = uris[1], version = 1 }, edits = { edit(1, 7, 2, "sys") } },
          },
        },
      })
      assert.same({ applied = true }, result)
      assert.same(
        { "new = 0", "import sys", "x = 1", "```" },
        vim.list_slice(protocol.lines(bufnr), rows.cell1 + 1, rows.cell1 + 4)
      )
    end)

    -- Neovim asks before it applies a document's edits that need confirmation, and skips them if declined
    describe("with a change annotation that needs confirmation", function()
      local confirm = vim.fn.confirm
      local asked ---@type string[]
      local answer ---@type integer

      before_each(function()
        asked = {}
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.fn.confirm = function(message)
          table.insert(asked, message)
          return answer
        end
      end)

      after_each(function()
        vim.fn.confirm = confirm
      end)

      --- Applies two successive edits of the first cell, annotated with `first`
      --- and `second`, and returns the cell's lines with its closing fence.
      local function apply(first, second)
        local bufnr, uris = protocol.open_example(env)
        env.server:request("workspace/applyEdit", {
          edit = {
            changeAnnotations = {
              rename = { label = "Rename", needsConfirmation = true },
              imports = { label = "Sort imports", needsConfirmation = true },
            },
            documentChanges = {
              {
                textDocument = { uri = uris[1], version = 1 },
                edits = { vim.tbl_extend("force", edit(0, 0, 0, "new = 0\n"), { annotationId = first }) },
              },
              {
                textDocument = { uri = uris[1], version = 1 },
                edits = { vim.tbl_extend("force", edit(1, 7, 2, "sys"), { annotationId = second }) },
              },
            },
          },
        })
        return vim.list_slice(protocol.lines(bufnr), rows.cell1 + 1, rows.cell1 + 4)
      end

      it("applies them once confirmed", function()
        answer = 1
        assert.same({ "new = 0", "import sys", "x = 1", "```" }, apply("rename", "rename"))
        assert.equal(1, #asked)
        assert.truthy(asked[1]:find("Rename", 1, true))
      end)

      it("skips them once declined", function()
        answer = 2
        assert.same({ "import os", "x = 1", "```", "" }, apply("rename", "rename"))
        assert.equal(1, #asked)
      end)

      -- Once they're one batch, which of its edits are which annotation's isn't known
      it("fails on several annotations", function()
        answer = 1
        assert.has_error(function()
          apply("rename", "imports")
        end)
      end)
    end)
  end)

  it("inserts at the end of a cell before its closing fence", function()
    local bufnr, cells = protocol.open_example(env)
    env.server:request("workspace/applyEdit", { edit = { changes = { [cells[1]] = { edit(2, 0, 0, "y = 2\n") } } } })
    assert.same(
      { "import os", "x = 1", "y = 2", "```" },
      vim.list_slice(protocol.lines(bufnr), rows.cell1 + 1, rows.cell1 + 4)
    )
  end)

  -- The cell's text ends with a line break, the one before its closing fence:
  -- edits must leave the fence on its own line, or the cell would go on past it
  describe("at the end of a cell, keeps the closing fence on its line", function()
    --- Applies `edits` to the first cell, and checks that it then reads `cell`,
    --- followed by its closing fence, and that the rest of the notebook is untouched.
    ---@param edits lsp.TextEdit[]
    ---@param cell string[]
    local function apply(edits, cell)
      local bufnr, cells = protocol.open_example(env)
      local result = env.server:request("workspace/applyEdit", { edit = { changes = { [cells[1]] = edits } } })
      assert.same({ applied = true }, result)
      local lines = protocol.lines(bufnr)
      assert.same(
        vim.list_extend(vim.deepcopy(cell), { "```" }),
        vim.list_slice(lines, rows.cell1 + 1, rows.cell1 + #cell + 1)
      )
      local after = vim.list_slice(protocol.example.body, rows.cell1_fence - #protocol.header + 2)
      assert.same(after, vim.list_slice(lines, #lines - #after + 1))
    end

    ---@return lsp.TextEdit
    local function replace(start_line, start_character, end_line, end_character, new_text)
      return {
        range = {
          start = { line = start_line, character = start_character },
          ["end"] = { line = end_line, character = end_character },
        },
        newText = new_text,
      }
    end

    it("inserting text without a line break", function()
      apply({ edit(2, 0, 0, "y = 2") }, { "import os", "x = 1", "y = 2" })
    end)

    it("deleting the cell's last line break", function()
      apply({ replace(1, 5, 2, 0, "") }, { "import os", "x = 1" })
    end)

    it("deleting from the middle of a line to the end", function()
      apply({ replace(1, 1, 2, 0, "") }, { "import os", "x" })
    end)

    -- A position past the end of a document is its end
    it("deleting past the end of the cell", function()
      apply({ replace(1, 0, 9, 0, "") }, { "import os" })
    end)

    -- Edits are applied together: it's what they leave that must end with a line break
    it("deleting the last line break and inserting at the end together", function()
      apply({ replace(1, 5, 2, 0, ""), edit(2, 0, 0, " + 2") }, { "import os", "x = 1 + 2" })
    end)

    -- Neovim makes it a line break before it applies the edit
    it("inserting text ending with a carriage return", function()
      apply({ edit(2, 0, 0, "y = 2\r") }, { "import os", "x = 1", "y = 2" })
    end)
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
