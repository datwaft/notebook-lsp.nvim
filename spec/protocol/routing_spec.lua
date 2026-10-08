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

  --- Sends `method` from the notebook buffer at `position` and returns the result.
  local function request(bufnr, method, position)
    local client = protocol.wait_attached(env, bufnr)
    local response = client:request_sync(method, {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = position,
    }, 1000, bufnr)
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

  it("passes requests for .py files through untouched", function()
    protocol.open_example(env)
    local py = protocol.open(env, "utils.py", { "def helper(): pass" })
    request(py, "textDocument/hover", { line = 0, character = 4 })
    local hover = env.server:wait_for("textDocument/hover")
    assert.equal(vim.uri_from_bufnr(py), hover.textDocument.uri)
    assert.same({ line = 0, character = 4 }, hover.position)
  end)
end)
