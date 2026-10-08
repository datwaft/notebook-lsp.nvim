local protocol = require("helpers.protocol")

local rows = protocol.example.rows

---@param line integer
---@param character integer
---@param length integer
---@return lsp.Range
local function range(line, character, length)
  return { start = { line = line, character = character }, ["end"] = { line = line, character = character + length } }
end

describe("request routing", function()
  local env ---@type ProtocolEnv
  local handlers ---@type table<string, fun(params: any): any>

  before_each(function()
    handlers = {}
    env = protocol.start({ handlers = handlers })
  end)

  after_each(function()
    protocol.stop()
  end)

  --- Sends `method` from the notebook buffer at `position`, with `extra`
  --- params, and returns the result.
  local function request(bufnr, method, position, extra)
    local client = protocol.wait_attached(env, bufnr)
    local response = client:request_sync(
      method,
      vim.tbl_extend("force", {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = position,
      }, extra or {}),
      1000,
      bufnr
    )
    assert(response and not response.err, vim.inspect(response))
    return response.result
  end

  it("sends position requests to the cell, in the cell's coordinates", function()
    local bufnr, cells = protocol.open_example(env)
    request(bufnr, "textDocument/hover", protocol.position(bufnr, rows.cell2 + 1, "x"))
    local hover = env.server:wait_for("textDocument/hover")
    assert.equal(cells[2], hover.textDocument.uri)
    assert.same({ line = 1, character = 11 }, hover.position)
  end)

  -- Neovim flushes its pending changes before a request, but not for buffer 0, the current one
  it("tells the server about pending changes before a request", function()
    local bufnr = protocol.open_example(env)
    local client = protocol.wait_attached(env, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { "", "```python", "new = 1", "```" })
    client:request_sync("textDocument/hover", {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = { line = #protocol.lines(bufnr) - 2, character = 0 },
    }, 1000, 0)
    env.server:wait_for("textDocument/hover")
    local methods = vim.tbl_map(function(message)
      return message.method
    end, env.server.messages)
    local hovered = assert(vim.iter(ipairs(methods)):find(function(_, method)
      return method == "textDocument/hover"
    end))
    assert.equal("notebookDocument/didChange", methods[hovered - 1])
  end)

  it("answers requests outside cells without asking the server", function()
    local bufnr = protocol.open_example(env)
    assert.is_nil(request(bufnr, "textDocument/hover", protocol.position(bufnr, rows.prose, "x")))
    assert.same({}, env.server:received("textDocument/hover"))
  end)

  it("maps locations in other cells back to the notebook", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/definition"] = function()
      return { { uri = cells[1], range = range(1, 0, 1) } }
    end
    local result = request(bufnr, "textDocument/definition", protocol.position(bufnr, rows.cell2 + 1, "x"))
    assert.same({ { uri = vim.uri_from_bufnr(bufnr), range = range(rows.cell1 + 1, 0, 1) } }, result)
  end)

  it("maps the origin of location links to the requesting cell", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/definition"] = function()
      return {
        {
          originSelectionRange = range(1, 11, 1),
          targetUri = cells[1],
          targetRange = range(1, 0, 5),
          targetSelectionRange = range(1, 0, 1),
        },
      }
    end
    local result = request(bufnr, "textDocument/definition", protocol.position(bufnr, rows.cell2 + 1, "x"))
    assert.same({
      {
        originSelectionRange = range(rows.cell2 + 1, 11, 1),
        targetUri = vim.uri_from_bufnr(bufnr),
        targetRange = range(rows.cell1 + 1, 0, 5),
        targetSelectionRange = range(rows.cell1 + 1, 0, 1),
      },
    }, result)
  end)

  it("leaves locations in other files untouched", function()
    local bufnr = protocol.open_example(env)
    local utils = vim.uri_from_fname(env.dir .. "/utils.py")
    handlers["textDocument/definition"] = function()
      return { { uri = utils, range = range(3, 4, 6) } }
    end
    local result = request(bufnr, "textDocument/definition", protocol.position(bufnr, rows.cell2 + 1, "x"))
    assert.same({ { uri = utils, range = range(3, 4, 6) } }, result)
  end)

  it("maps completion edits without a URI to the requesting cell", function()
    local bufnr = protocol.open_example(env)
    handlers["textDocument/completion"] = function()
      return {
        isIncomplete = false,
        items = {
          {
            label = "OrderedDict",
            textEdit = { range = range(1, 11, 1), newText = "OrderedDict" },
            additionalTextEdits = { { range = range(0, 0, 0), newText = "from collections import OrderedDict\n" } },
          },
        },
      }
    end
    local item = request(bufnr, "textDocument/completion", protocol.position(bufnr, rows.cell2 + 1, "x")).items[1]
    assert.same(range(rows.cell2 + 1, 11, 1), item.textEdit.range)
    assert.same(range(rows.cell2, 0, 0), item.additionalTextEdits[1].range)
  end)

  it("maps resolved completion items to the cell of the completion", function()
    local bufnr = protocol.open_example(env)
    handlers["textDocument/completion"] = function()
      return { { label = "OrderedDict", data = { opaque = true } } }
    end
    handlers["completionItem/resolve"] = function(params)
      return vim.tbl_extend("force", params, {
        additionalTextEdits = { { range = range(0, 0, 0), newText = "from collections import OrderedDict\n" } },
      })
    end
    local client = protocol.wait_attached(env, bufnr)
    local item = request(bufnr, "textDocument/completion", protocol.position(bufnr, rows.cell2 + 1, "x"))[1]
    local resolved = assert(client:request_sync("completionItem/resolve", item, 1000, bufnr)).result
    assert.same(range(rows.cell2, 0, 0), resolved.additionalTextEdits[1].range)
    assert.same({ opaque = true }, env.server:wait_for("completionItem/resolve").data)
  end)

  -- A position in a cell doesn't say which cell: the items must
  it("resolves items from several cells, each in its own cell", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/codeLens"] = function(params)
      return { { range = range(0, 0, 1), data = { cell = params.textDocument.uri } } }
    end
    handlers["codeLens/resolve"] = function(lens)
      return vim.tbl_extend("force", lens, { command = { title = lens.data.cell, command = "" } })
    end
    local client = protocol.wait_attached(env, bufnr)
    local lenses = request(bufnr, "textDocument/codeLens")
    assert.same({ range(rows.cell1, 0, 1), range(rows.cell2, 0, 1) }, {
      lenses[1].range,
      lenses[2].range,
    })
    local resolved = assert(client:request_sync("codeLens/resolve", lenses[2], 1000, bufnr)).result
    assert.same(range(rows.cell2, 0, 1), resolved.range)
    assert.equal(cells[2], resolved.command.title)
  end)

  it("formats every cell and applies the edits to the notebook only", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/formatting"] = function(params)
      local cell = assert(vim.iter(ipairs(cells)):find(function(_, uri)
        return uri == params.textDocument.uri
      end))
      return { { range = range(0, 0, 0), newText = ("# formatted cell %d\n"):format(cell) } }
    end
    local before = protocol.lines(bufnr)
    vim.lsp.buf.format({ bufnr = bufnr, name = env.name, timeout_ms = 1000 })
    local expected = vim.deepcopy(before)
    table.insert(expected, rows.cell2 + 1, "# formatted cell 2")
    table.insert(expected, rows.cell1 + 1, "# formatted cell 1")
    assert.same(expected, protocol.lines(bufnr))
  end)

  -- Tokens are encoded relative to the token before them, so they can't simply be put together.
  -- Without a result id, Neovim asks for all the tokens again instead of the changes since then.
  it("combines the semantic tokens of every cell, without a result id", function()
    local bufnr = protocol.open_example(env)
    handlers["textDocument/semanticTokens/full"] = function(params)
      local data = {
        ["1"] = { 0, 0, 6, 0, 0, 1, 0, 1, 1, 0 }, -- `import` in `import os`, `x` in `x = 1`
        ["2"] = { 0, 4, 1, 2, 0 }, -- `f` in `def f():`
      }
      return { resultId = "r", data = data[params.textDocument.uri:match("#c(%d+)$")] }
    end
    assert.same({
      data = {
        rows.cell1,
        0,
        6,
        0,
        0,
        1,
        0,
        1,
        1,
        0,
        rows.cell2 - rows.cell1 - 1,
        4,
        1,
        2,
        0,
      },
    }, request(bufnr, "textDocument/semanticTokens/full"))
  end)

  it("maps locations in cells in answers about .py files", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/references"] = function()
      return { { uri = cells[2], range = range(1, 11, 1) } }
    end
    local py = protocol.open(env, "utils.py", { "x = 1" })
    local result = request(py, "textDocument/references", { line = 0, character = 0 })
    assert.same({ { uri = vim.uri_from_bufnr(bufnr), range = range(rows.cell2 + 1, 11, 1) } }, result)
  end)

  it("passes requests for .py files through untouched", function()
    protocol.open_example(env)
    local py = protocol.open(env, "utils.py", { "def helper(): pass" })
    request(py, "textDocument/hover", { line = 0, character = 4 })
    local hover = env.server:wait_for("textDocument/hover")
    assert.equal(vim.uri_from_bufnr(py), hover.textDocument.uri)
    assert.same({ line = 0, character = 4 }, hover.position)
  end)

  -- Each position goes to its cell; the answer has one range per position, in their order.
  it("sends each position of a selection range request to its cell", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/selectionRange"] = function(params)
      return vim.tbl_map(function(position)
        return { range = range(position.line, 0, 3), parent = { range = range(0, 0, 9) } }
      end, params.positions)
    end
    local client = protocol.wait_attached(env, bufnr)
    local result = assert(client:request_sync("textDocument/selectionRange", {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      positions = { { line = rows.cell2 + 1, character = 11 }, { line = rows.cell1 + 1, character = 0 } },
    }, 1000, bufnr)).result
    assert.same({
      { range = range(rows.cell2 + 1, 0, 3), parent = { range = range(rows.cell2, 0, 9) } },
      { range = range(rows.cell1 + 1, 0, 3), parent = { range = range(rows.cell1, 0, 9) } },
    }, result)
    local requests = env.server:received("textDocument/selectionRange")
    table.sort(requests, function(a, b)
      return a.textDocument.uri < b.textDocument.uri
    end)
    assert.same({ { line = 1, character = 0 } }, requests[1].positions)
    assert.equal(cells[1], requests[1].textDocument.uri)
    assert.same({ { line = 1, character = 11 } }, requests[2].positions)
    assert.equal(cells[2], requests[2].textDocument.uri)
  end)

  -- The spec asks for one range per position: outside cells, the position itself.
  it("answers a selection range outside cells with the position itself", function()
    local bufnr = protocol.open_example(env)
    handlers["textDocument/selectionRange"] = function(params)
      return vim.tbl_map(function(position)
        return { range = range(position.line, 0, 3) }
      end, params.positions)
    end
    local client = protocol.wait_attached(env, bufnr)
    local prose = { line = rows.prose, character = 5 }
    local result = assert(client:request_sync("textDocument/selectionRange", {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      positions = { prose, { line = rows.cell1 + 1, character = 0 } },
    }, 1000, bufnr)).result
    assert.same({ { range = { start = prose, ["end"] = prose } }, { range = range(rows.cell1 + 1, 0, 3) } }, result)
  end)

  it("answers nothing for a selection range only outside cells, without asking the server", function()
    local bufnr = protocol.open_example(env)
    local client = protocol.wait_attached(env, bufnr)
    local result = assert(client:request_sync("textDocument/selectionRange", {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      positions = { { line = rows.prose, character = 5 } },
    }, 1000, bufnr)).result
    assert.is_nil(result)
    assert.same({}, env.server:received("textDocument/selectionRange"))
  end)

  it("maps the lines of folding ranges to the notebook", function()
    local bufnr = protocol.open_example(env)
    handlers["textDocument/foldingRange"] = function()
      return { { startLine = 0, endLine = 1, kind = "region" } }
    end
    assert.same({
      { startLine = rows.cell1, endLine = rows.cell1 + 1, kind = "region" },
      { startLine = rows.cell2, endLine = rows.cell2 + 1, kind = "region" },
    }, request(bufnr, "textDocument/foldingRange"))
  end)

  -- The item of a hierarchy is the server's: the requests that follow it must get it as it was.
  describe("call and type hierarchies", function()
    ---@return lsp.CallHierarchyItem
    local function item(name, uri, line)
      return {
        name = name,
        kind = 12,
        uri = uri,
        range = range(line, 0, 8),
        selectionRange = range(line, 4, 1),
        data = { name = name },
      }
    end

    it("prepares an item in the notebook and asks for its calls with the server's item", function()
      local bufnr, cells = protocol.open_example(env)
      handlers["textDocument/prepareCallHierarchy"] = function()
        return { item("f", cells[2], 0) }
      end
      handlers["callHierarchy/incomingCalls"] = function()
        return { { from = item("g", cells[1], 1), fromRanges = { range(1, 4, 1) } } }
      end
      local client = protocol.wait_attached(env, bufnr)
      local prepared = request(bufnr, "textDocument/prepareCallHierarchy", protocol.position(bufnr, rows.cell2, "f"))
      assert.equal(vim.uri_from_bufnr(bufnr), prepared[1].uri)
      assert.same(range(rows.cell2, 0, 8), prepared[1].range)

      local calls =
        assert(client:request_sync("callHierarchy/incomingCalls", { item = prepared[1] }, 1000, bufnr)).result
      assert.same(item("f", cells[2], 0), env.server:wait_for("callHierarchy/incomingCalls").item)
      assert.equal(vim.uri_from_bufnr(bufnr), calls[1].from.uri)
      assert.same(range(rows.cell1 + 1, 0, 8), calls[1].from.range)
      -- in the caller's cell
      assert.same({ range(rows.cell1 + 1, 4, 1) }, calls[1].fromRanges)
    end)

    it("maps outgoing calls, whose ranges are in the item's cell, and follows them", function()
      local bufnr, cells = protocol.open_example(env)
      handlers["textDocument/prepareCallHierarchy"] = function()
        return { item("f", cells[2], 0) }
      end
      handlers["callHierarchy/outgoingCalls"] = function()
        return { { to = item("g", cells[1], 1), fromRanges = { range(1, 11, 1) } } }
      end
      local client = protocol.wait_attached(env, bufnr)
      local prepared = request(bufnr, "textDocument/prepareCallHierarchy", protocol.position(bufnr, rows.cell2, "f"))
      local calls =
        assert(client:request_sync("callHierarchy/outgoingCalls", { item = prepared[1] }, 1000, bufnr)).result
      assert.same(range(rows.cell1 + 1, 0, 8), calls[1].to.range)
      assert.same({ range(rows.cell2 + 1, 11, 1) }, calls[1].fromRanges)

      assert(client:request_sync("callHierarchy/outgoingCalls", { item = calls[1].to }, 1000, bufnr))
      assert.same(item("g", cells[1], 1), env.server:wait_for("callHierarchy/outgoingCalls", 2).item)
    end)

    it("asks for the supertypes and subtypes of an item with the server's item", function()
      local bufnr, cells = protocol.open_example(env)
      handlers["textDocument/prepareTypeHierarchy"] = function()
        return { item("B", cells[2], 0) }
      end
      handlers["typeHierarchy/supertypes"] = function()
        return { item("A", cells[1], 1) }
      end
      local client = protocol.wait_attached(env, bufnr)
      local prepared = request(bufnr, "textDocument/prepareTypeHierarchy", protocol.position(bufnr, rows.cell2, "f"))
      local supertypes =
        assert(client:request_sync("typeHierarchy/supertypes", { item = prepared[1] }, 1000, bufnr)).result
      assert.same(item("B", cells[2], 0), env.server:wait_for("typeHierarchy/supertypes").item)
      assert.equal(vim.uri_from_bufnr(bufnr), supertypes[1].uri)
      assert.same(range(rows.cell1 + 1, 4, 1), supertypes[1].selectionRange)

      assert(client:request_sync("typeHierarchy/subtypes", { item = supertypes[1] }, 1000, bufnr))
      assert.same(item("A", cells[1], 1), env.server:wait_for("typeHierarchy/subtypes").item)
    end)
  end)

  it("gives each cell only its own diagnostics in a code action request", function()
    local bufnr, cells = protocol.open_example(env)
    local function diagnostic(line, message)
      return { range = range(line, 0, 1), message = message }
    end
    request(bufnr, "textDocument/codeAction", nil, {
      range = { start = { line = rows.cell1, character = 0 }, ["end"] = { line = rows.cell2 + 1, character = 0 } },
      context = { diagnostics = { diagnostic(rows.cell1, "in cell 1"), diagnostic(rows.cell2 + 1, "in cell 2") } },
    })
    local by_cell = {}
    for _, params in ipairs(env.server:received("textDocument/codeAction")) do
      by_cell[params.textDocument.uri] = params.context.diagnostics
    end
    assert.same({
      [cells[1]] = { diagnostic(0, "in cell 1") },
      [cells[2]] = { diagnostic(1, "in cell 2") },
    }, by_cell)
  end)

  -- Arguments are the server's, as data is: Neovim sends them back as they are.
  it("leaves the arguments of commands untouched", function()
    local bufnr, cells = protocol.open_example(env)
    local arguments = { { uri = cells[1], range = range(1, 0, 1) } }
    handlers["textDocument/codeLens"] = function(params)
      if params.textDocument.uri == cells[1] then
        return { { range = range(1, 0, 1), command = { title = "run", command = "run", arguments = arguments } } }
      end
    end
    local lenses = request(bufnr, "textDocument/codeLens")
    assert.same(range(rows.cell1 + 1, 0, 1), lenses[1].range)
    assert.same(arguments, lenses[1].command.arguments)
  end)
end)
