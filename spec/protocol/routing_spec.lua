local fake_server = require("helpers.fake_server")
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

  -- The server gets an item back as from a .py file: with the list's defaults, as the completion engine applies them
  describe("resolves completion items with the list's defaults", function()
    --- Neovim's completion: the items of a completion `result`, as it resolves them.
    local function neovim(result, client_id)
      return vim.tbl_map(function(candidate)
        return candidate.user_data.nvim.lsp.completion_item
      end, vim.lsp.completion._lsp_to_complete_items(result, "", client_id))
    end

    --- blink.cmp's: it fills in the defaults it knows, replacing, and makes
    --- the default edit range an edit of the insert text, even an empty one.
    local function blink(result)
      local defaults = result.itemDefaults or {}
      local items = result.items or result
      for _, item in ipairs(items) do
        for _, key in ipairs({ "commitCharacters", "insertTextFormat", "insertTextMode", "data" }) do
          item[key] = item[key] or defaults[key]
        end
        local edit_range = defaults.editRange
        if edit_range and item.textEdit == nil then
          local new_text = item.textEditText or item.insertText or item.label
          if edit_range.replace ~= nil then
            item.textEdit = { replace = edit_range.replace, insert = edit_range.insert, newText = new_text }
          else
            item.textEdit = { range = edit_range, newText = new_text }
          end
        end
      end
      return items
    end

    --- What the server gets back for each item of `list`, by label, when the
    --- completion `engine` resolves it from `bufnr` at `position`.
    local function resolved(list, bufnr, position, engine)
      handlers["textDocument/completion"] = function()
        return vim.deepcopy(list)
      end
      local client = protocol.wait_attached(env, bufnr)
      local result = request(bufnr, "textDocument/completion", position)
      local items = {}
      for _, item in ipairs(engine(result, client.id)) do
        local count = #env.server:received("completionItem/resolve")
        assert(client:request_sync("completionItem/resolve", item, 1000, bufnr))
        items[item.label] = env.server:wait_for("completionItem/resolve", count + 1)
      end
      return items
    end

    --- What the server gets back from a notebook, and from a .py file, for a
    --- list of `items` with `defaults`, which apply to them as `apply_kind` says,
    --- through the completion `engine` (Neovim's by default).
    local function from_both(defaults, apply_kind, items, engine)
      engine = engine or neovim
      local list = { itemDefaults = defaults, applyKind = apply_kind, items = items }
      local bufnr = protocol.open_example(env)
      local notebook = resolved(list, bufnr, protocol.position(bufnr, rows.cell2 + 1, "x"), engine)
      -- The same code as the cell's, at the same position in it
      local py = protocol.open(env, "utils.py", vim.split(vim.trim(protocol.example.texts[2]), "\n"))
      return notebook, resolved(list, py, protocol.position(py, 1, "x"), engine)
    end

    local items = { { label = "a" }, { label = "b", data = { specific = 7 } } }

    it("with default data replacing the items' own", function()
      local notebook, py = from_both({ data = { shared = 42 } }, nil, items)
      assert.same({ shared = 42 }, notebook.a.data)
      assert.same({ specific = 7 }, notebook.b.data)
      assert.same(py, notebook)
    end)

    it("with default data merged into the items' own", function()
      local merge = vim.lsp.protocol.ApplyKind.Merge
      local notebook, py = from_both({ data = { shared = 42 } }, { data = merge }, items)
      assert.same({ shared = 42 }, notebook.a.data)
      assert.same({ shared = 42, specific = 7 }, notebook.b.data)
      assert.same(py, notebook)
    end)

    it("with every default", function()
      local defaults = {
        editRange = range(1, 11, 1),
        insertTextFormat = 2,
        insertTextMode = 1,
        commitCharacters = { "(" },
        data = { shared = 42 },
      }
      local notebook, py = from_both(defaults, nil, {
        { label = "a" },
        { label = "b", insertText = "bee", insertTextFormat = 1, commitCharacters = { "." } },
      })
      assert.same({ range = range(1, 11, 1), newText = "a" }, notebook.a.textEdit)
      assert.same({ "(" }, notebook.a.commitCharacters)
      assert.same(py, notebook)
    end)

    it("with an insert and a replace range, and commit characters merged", function()
      local defaults =
        { editRange = { insert = range(1, 11, 0), replace = range(1, 11, 1) }, commitCharacters = { "(" } }
      local merge = vim.lsp.protocol.ApplyKind.Merge
      local notebook, py = from_both(defaults, { commitCharacters = merge }, {
        { label = "a", commitCharacters = { "." } },
      })
      assert.same({ insert = range(1, 11, 0), replace = range(1, 11, 1), newText = "a" }, notebook.a.textEdit)
      assert.same({ ".", "(" }, notebook.a.commitCharacters)
      assert.same(py, notebook)
    end)

    it("as another completion engine applies them", function()
      local merge = vim.lsp.protocol.ApplyKind.Merge
      local notebook, py = from_both({ editRange = range(1, 11, 1), data = { shared = 42 } }, { data = merge }, {
        { label = "a", insertText = "" },
        { label = "b", data = { specific = 7 } },
      }, blink)
      assert.same({ range = range(1, 11, 1), newText = "" }, notebook.a.textEdit)
      assert.same({ specific = 7 }, notebook.b.data)
      assert.same(py, notebook)
    end)

    it("as another completion engine applies an insert and a replace range", function()
      local defaults = { editRange = { insert = range(1, 11, 0), replace = range(1, 11, 1) } }
      local notebook, py = from_both(defaults, nil, { { label = "a" } }, blink)
      assert.same({ insert = range(1, 11, 0), replace = range(1, 11, 1), newText = "a" }, notebook.a.textEdit)
      assert.same(py, notebook)
    end)
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

  -- Neovim's transport ends a cancelled request when the server acknowledges it, without an answer
  it("ends a request to several cells once the server acknowledges its cancellation", function()
    local bufnr = protocol.open_example(env)
    local client = protocol.wait_attached(env, bufnr)
    env.server.unanswered["textDocument/formatting"] = true
    local answered = false
    local sent, id = client:request("textDocument/formatting", {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      options = { tabSize = 4, insertSpaces = true },
    }, function()
      answered = true
    end, bufnr)
    assert.is_true(sent)
    assert.is_not_nil(client.requests[id])
    client:cancel_request(assert(id))
    assert.is_true(vim.wait(1000, function()
      return client.requests[id] == nil
    end, 5))
    assert.equal(2, #env.server:received("$/cancelRequest"))
    assert.is_false(answered)
  end)

  describe("in a notebook of many cells", function()
    -- A request about every cell would send dozens at once, which a server may
    -- not handle: ty 0.0.84 stops answering at all if 41 arrive as it starts
    local LIMIT = 16

    --- Opens a notebook of `count` one-line cells, and returns its buffer and client.
    local function open_cells(count)
      local body = {}
      for i = 1, count do
        vim.list_extend(body, { "", "```python", ("x%d = %d"):format(i, i), "```" })
      end
      local bufnr = protocol.open(env, "many.md", protocol.notebook(body))
      local client = protocol.wait_attached(env, bufnr)
      env.server:wait_for("notebookDocument/didOpen")
      return bufnr, client
    end

    local function format(client, bufnr, callback)
      return client:request("textDocument/formatting", {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        options = { tabSize = 4, insertSpaces = true },
      }, callback or function() end, bufnr)
    end

    it("sends the server only so many requests at a time, and the others as they're answered", function()
      local bufnr, client = open_cells(40)
      handlers["textDocument/formatting"] = function()
        return { { range = range(0, 0, 0), newText = "# formatted\n" } }
      end
      env.server.held["textDocument/formatting"] = true
      local result
      format(client, bufnr, function(_, edits)
        result = edits
      end)
      vim.wait(100)
      assert.equal(LIMIT, #env.server:received("textDocument/formatting"))

      env.server:release("textDocument/formatting")
      assert.is_true(vim.wait(1000, function()
        return result ~= nil
      end, 5))
      assert.equal(40, #env.server:received("textDocument/formatting"))
      assert.equal(40, #result)
    end)

    it("sends a request about one cell once the server has room for it", function()
      local bufnr, client = open_cells(40)
      env.server.held["textDocument/formatting"] = true
      format(client, bufnr)
      local hovered = false
      client:request("textDocument/hover", {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = { line = #protocol.header + 2, character = 0 },
      }, function()
        hovered = true
      end, bufnr)
      vim.wait(100)
      assert.same({}, env.server:received("textDocument/hover"))

      env.server:release("textDocument/formatting")
      assert.is_true(vim.wait(1000, function()
        return hovered
      end, 5))
    end)

    -- Cancelling a request cancels what the server has of it, and drops the rest
    it("doesn't send the requests of a cancelled request that were still waiting", function()
      local bufnr, client = open_cells(40)
      env.server.unanswered["textDocument/formatting"] = true
      local _, id = format(client, bufnr)
      vim.wait(100)
      client:cancel_request(assert(id))
      assert.is_true(vim.wait(1000, function()
        return client.requests[id] == nil
      end, 5))
      assert.equal(LIMIT, #env.server:received("$/cancelRequest"))
      assert.equal(LIMIT, #env.server:received("textDocument/formatting"))

      -- Their room is the next request's
      env.server.unanswered["textDocument/formatting"] = nil
      local answered = false
      format(client, bufnr, function()
        answered = true
      end)
      assert.is_true(vim.wait(1000, function()
        return answered
      end, 5))
    end)
  end)

  it("combines the answers of a server that answers before returning", function()
    local bufnr = protocol.open_example(env)
    handlers["textDocument/formatting"] = function()
      return { { range = range(0, 0, 0), newText = "# formatted\n" } }
    end
    protocol.wait_attached(env, bufnr)
    env.server.synchronous = true
    assert.same({
      { range = range(rows.cell1, 0, 0), newText = "# formatted\n" },
      { range = range(rows.cell2, 0, 0), newText = "# formatted\n" },
    }, request(bufnr, "textDocument/formatting", nil, { options = { tabSize = 4, insertSpaces = true } }))
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

  -- The server's own data, which only looks like what the plugin records in items
  it("resolves items of .py files whose data has the plugin's key", function()
    protocol.open_example(env)
    local py = protocol.open(env, "utils.py", { "x = 1" })
    local client = protocol.wait_attached(env, py)
    local item = { label = "x", data = { notebook_lsp = "mine" } }
    assert(client:request_sync("completionItem/resolve", item, 1000, py))
    assert.same(item, env.server:wait_for("completionItem/resolve"))
  end)

  -- Other items record their cell in their data, with the item as the server gave it
  it("resolves code actions of .py files whose data has the plugin's key and an item", function()
    protocol.open_example(env)
    local py = protocol.open(env, "utils.py", { "x = 1" })
    local client = protocol.wait_attached(env, py)
    local action = { title = "Fix", data = { notebook_lsp = "mine", item = { title = "Other" } } }
    assert(client:request_sync("codeAction/resolve", action, 1000, py))
    assert.same(action, env.server:wait_for("codeAction/resolve"))
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

    it("prepares an item in the notebook from a .py file and asks for its calls with the server's item", function()
      local bufnr, cells = protocol.open_example(env)
      handlers["textDocument/prepareCallHierarchy"] = function()
        return { item("f", cells[2], 0) }
      end
      local py = protocol.open(env, "utils.py", { "f()" })
      local client = protocol.wait_attached(env, py)
      local prepared = request(py, "textDocument/prepareCallHierarchy", { line = 0, character = 0 })
      assert.equal(vim.uri_from_bufnr(bufnr), prepared[1].uri)
      assert(client:request_sync("callHierarchy/incomingCalls", { item = prepared[1] }, 1000, py))
      assert.same(item("f", cells[2], 0), env.server:wait_for("callHierarchy/incomingCalls").item)
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

  -- What Neovim was given goes back: the server gets its own diagnostics, each location in its document
  it("gives the server its diagnostics back in a code action request", function()
    local bufnr, cells = protocol.open_example(env)
    local published = {
      range = range(1, 11, 1),
      message = "x is redefined",
      relatedInformation = {
        { location = { uri = cells[1], range = range(1, 0, 1) }, message = "in another cell" },
        {
          location = { uri = vim.uri_from_fname(env.dir .. "/utils.py"), range = range(3, 0, 1) },
          message = "in a file",
        },
      },
    }
    env.server:notify("textDocument/publishDiagnostics", { uri = cells[2], diagnostics = { published } })
    local shown = vim.diagnostic.get(bufnr)[1].user_data.lsp
    request(bufnr, "textDocument/codeAction", nil, {
      range = range(rows.cell2 + 1, 11, 1),
      context = { diagnostics = { shown } },
    })
    assert.same({ published }, env.server:wait_for("textDocument/codeAction").context.diagnostics)
  end)

  it("gives the server its diagnostics back with related locations in another notebook", function()
    local bufnr, cells = protocol.open_example(env)
    protocol.wait_attached(env, protocol.open(env, "other.md", protocol.notebook(protocol.example.body)))
    local other = env.server:wait_for("notebookDocument/didOpen", 2).cellTextDocuments
    local published = {
      range = range(1, 11, 1),
      message = "x is redefined",
      relatedInformation = { { location = { uri = other[2].uri, range = range(1, 0, 1) }, message = "elsewhere" } },
    }
    env.server:notify("textDocument/publishDiagnostics", { uri = cells[2], diagnostics = { published } })
    local shown = vim.diagnostic.get(bufnr)[1].user_data.lsp
    vim.cmd.buffer(bufnr)
    request(bufnr, "textDocument/codeAction", nil, {
      range = range(rows.cell2 + 1, 11, 1),
      context = { diagnostics = { shown } },
    })
    assert.same({ published }, env.server:wait_for("textDocument/codeAction").context.diagnostics)
  end)

  -- Neovim keeps the diagnostic as the plugin gave it, while the other notebook's cells move
  it("gives the server its diagnostics back after the cells of their related locations move", function()
    local bufnr, cells = protocol.open_example(env)
    local other_bufnr = protocol.open(env, "other.md", protocol.notebook(protocol.example.body))
    protocol.wait_attached(env, other_bufnr)
    local other = env.server:wait_for("notebookDocument/didOpen", 2).cellTextDocuments
    local published = {
      range = range(1, 11, 1),
      message = "x is redefined",
      relatedInformation = { { location = { uri = other[2].uri, range = range(1, 0, 1) }, message = "elsewhere" } },
    }
    env.server:notify("textDocument/publishDiagnostics", { uri = cells[2], diagnostics = { published } })
    vim.api.nvim_buf_set_lines(other_bufnr, rows.prose, rows.prose, true, { "More", "prose." })
    local shown = vim.diagnostic.get(bufnr)[1].user_data.lsp
    vim.cmd.buffer(bufnr)
    request(bufnr, "textDocument/codeAction", nil, {
      range = range(rows.cell2 + 1, 11, 1),
      context = { diagnostics = { shown } },
    })
    assert.same({ published }, env.server:wait_for("textDocument/codeAction").context.diagnostics)
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

  it("maps the target of document links to a cell to the notebook", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/documentLink"] = function(params)
      if params.textDocument.uri == cells[1] then
        return { { range = range(0, 7, 2), target = cells[2] } }
      end
    end
    local links = request(bufnr, "textDocument/documentLink")
    assert.equal(1, #links)
    assert.same(range(rows.cell1, 7, 2), links[1].range)
    assert.equal(vim.uri_from_bufnr(bufnr), links[1].target)
  end)

  -- Each cell gets the parts of the ranges in it, as for a single range.
  it("formats several ranges, each cell with its parts of them", function()
    local bufnr, cells = protocol.open_example(env)
    handlers["textDocument/rangesFormatting"] = function(params)
      return vim.tbl_map(function(r)
        return { range = { start = r.start, ["end"] = r.start }, newText = "# " }
      end, params.ranges)
    end
    local edits = request(bufnr, "textDocument/rangesFormatting", nil, {
      ranges = {
        range(rows.prose, 0, 5),
        range(rows.cell2 + 1, 4, 6),
      },
      options = { tabSize = 4, insertSpaces = true },
    })
    local by_cell = {}
    for _, params in ipairs(env.server:received("textDocument/rangesFormatting")) do
      by_cell[params.textDocument.uri] = params.ranges
    end
    assert.same({ [cells[2]] = { range(1, 4, 6) } }, by_cell)
    assert.same({ { range = range(rows.cell2 + 1, 4, 0), newText = "# " } }, edits)
  end)

  it("clips ranges to the cells they overlap", function()
    local bufnr, cells = protocol.open_example(env)
    request(bufnr, "textDocument/rangesFormatting", nil, {
      ranges = { { start = { line = rows.cell1 + 1, character = 0 }, ["end"] = { line = rows.cell2, character = 3 } } },
      options = { tabSize = 4, insertSpaces = true },
    })
    local by_cell = {}
    for _, params in ipairs(env.server:received("textDocument/rangesFormatting")) do
      by_cell[params.textDocument.uri] = params.ranges
    end
    assert.same({
      [cells[1]] = { { start = { line = 1, character = 0 }, ["end"] = { line = 2, character = 0 } } },
      [cells[2]] = { { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 3 } } },
    }, by_cell)
  end)

  -- A range ends before its end: one that ends where a cell starts has nothing of it
  it("leaves out the cell a range ends at the start of", function()
    local bufnr, cells = protocol.open_example(env)
    request(bufnr, "textDocument/rangeFormatting", nil, {
      range = { start = { line = rows.cell1, character = 0 }, ["end"] = { line = rows.cell2, character = 0 } },
      options = { tabSize = 4, insertSpaces = true },
    })
    local requests = env.server:received("textDocument/rangeFormatting")
    assert.same(
      { cells[1] },
      vim.tbl_map(function(params)
        return params.textDocument.uri
      end, requests)
    )
  end)

  -- Such as a code action's, at the cursor
  it("sends a range that's a position at the start of a cell to the cell", function()
    local bufnr, cells = protocol.open_example(env)
    local position = { line = rows.cell2, character = 0 }
    request(bufnr, "textDocument/codeAction", nil, {
      range = { start = position, ["end"] = position },
      context = { diagnostics = {} },
    })
    local action = env.server:wait_for("textDocument/codeAction")
    assert.equal(cells[2], action.textDocument.uri)
    assert.same({ start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }, action.range)
  end)

  -- The notebook protocol saves cells through their notebook: there is no "will save" for them
  it("answers willSaveWaitUntil for a notebook without asking the server", function()
    local bufnr = protocol.open_example(env)
    assert.is_nil(request(bufnr, "textDocument/willSaveWaitUntil", nil, { reason = 1 }))
    assert.same({}, env.server:received("textDocument/willSaveWaitUntil"))
  end)

  it("shows a document the server names by a cell in the notebook", function()
    local bufnr, cells = protocol.open_example(env)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local result = env.server:request("window/showDocument", { uri = cells[2], selection = range(1, 11, 1) })
    assert.same({ success = true }, result)
    assert.equal(bufnr, vim.api.nvim_get_current_buf())
    assert.same({ rows.cell2 + 2, 11 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("doesn't show a document the server names by a cell that's gone", function()
    local bufnr, cells = protocol.open_example(env)
    vim.api.nvim_buf_set_lines(bufnr, rows.cell2 - 2, rows.cell2 + 3, true, {})
    local result = env.server:request("window/showDocument", { uri = cells[2], selection = range(1, 11, 1) })
    assert.is_false(result.success)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      assert.is_nil(vim.api.nvim_buf_get_name(buf):match("^vscode%-notebook%-cell:"))
    end
  end)

  -- Neovim matches a registration's documentSelector against the buffer's language id
  it("matches registrations for the cells' language to the notebook", function()
    protocol.stop()
    local capabilities = vim.deepcopy(fake_server.capabilities)
    capabilities.documentFormattingProvider = nil
    env = protocol.start({ capabilities = capabilities, handlers = handlers })
    local bufnr = protocol.open_example(env)
    env.server:request("client/registerCapability", {
      registrations = {
        {
          id = "formatting",
          method = "textDocument/formatting",
          registerOptions = { documentSelector = { { language = "python" } } },
        },
      },
    })
    vim.lsp.buf.format({ bufnr = bufnr, name = env.name, timeout_ms = 1000 })
    assert.equal(2, #env.server:received("textDocument/formatting"))
  end)

  it("keeps the language id of other buffers", function()
    protocol.open_example(env)
    local py = protocol.open(env, "utils.py", { "x = 1" })
    local client = protocol.wait_attached(env, py)
    assert.equal("python", client.get_language_id(py, "python"))
    local md = vim.api.nvim_create_buf(true, false)
    assert.equal("markdown", client.get_language_id(md, "markdown"))
  end)
end)
