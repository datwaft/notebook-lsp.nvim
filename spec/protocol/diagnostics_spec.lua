local fake_server = require("helpers.fake_server")
local protocol = require("helpers.protocol")

local rows = protocol.example.rows

---@return lsp.Diagnostic
local function diagnostic(line, character, message)
  return {
    range = { start = { line = line, character = character }, ["end"] = { line = line, character = character + 1 } },
    message = message,
    severity = 1,
  }
end

--- Positions and messages of the buffer's diagnostics, sorted by position.
local function shown(bufnr)
  local list = vim.tbl_map(function(d)
    return { lnum = d.lnum, col = d.col, message = d.message }
  end, vim.diagnostic.get(bufnr))
  table.sort(list, function(a, b)
    return a.lnum < b.lnum
  end)
  return list
end

describe("diagnostics", function()
  local env ---@type ProtocolEnv

  before_each(function()
    env = protocol.start()
  end)

  after_each(function()
    protocol.stop()
  end)

  local function publish(uri, diagnostics)
    env.server:notify("textDocument/publishDiagnostics", { uri = uri, diagnostics = diagnostics })
  end

  it("shows a cell's diagnostics on the notebook lines of the cell", function()
    local bufnr, cells = protocol.open_example(env)
    publish(cells[2], { diagnostic(1, 11, "undefined") })
    assert.same({ { lnum = rows.cell2 + 1, col = 11, message = "undefined" } }, shown(bufnr))
  end)

  it("keeps the diagnostics of every cell", function()
    local bufnr, cells = protocol.open_example(env)
    publish(cells[1], { diagnostic(0, 7, "unused") })
    publish(cells[2], { diagnostic(1, 11, "undefined") })
    assert.same({
      { lnum = rows.cell1, col = 7, message = "unused" },
      { lnum = rows.cell2 + 1, col = 11, message = "undefined" },
    }, shown(bufnr))
  end)

  it("replaces only the diagnostics of the cell they are published for", function()
    local bufnr, cells = protocol.open_example(env)
    publish(cells[1], { diagnostic(0, 7, "unused") })
    publish(cells[2], { diagnostic(1, 11, "undefined") })
    publish(cells[2], {})
    assert.same({ { lnum = rows.cell1, col = 7, message = "unused" } }, shown(bufnr))
  end)

  it("moves diagnostics with their cell when lines are added above it", function()
    local bufnr, cells = protocol.open_example(env)
    publish(cells[2], { diagnostic(1, 11, "undefined") })
    vim.api.nvim_buf_set_lines(bufnr, rows.prose, rows.prose, true, { "More", "prose." })
    local moved = vim.wait(1000, function()
      return vim.deep_equal({ { lnum = rows.cell2 + 3, col = 11, message = "undefined" } }, shown(bufnr))
    end)
    assert.is_true(moved, vim.inspect(shown(bufnr)))
  end)

  it("drops the diagnostics of a removed cell", function()
    local bufnr, cells = protocol.open_example(env)
    publish(cells[1], { diagnostic(0, 7, "unused") })
    publish(cells[2], { diagnostic(1, 11, "undefined") })
    vim.api.nvim_buf_set_lines(bufnr, rows.cell2 - 1, rows.cell2 + 3, true, {})
    local dropped = vim.wait(1000, function()
      return vim.deep_equal({ { lnum = rows.cell1, col = 7, message = "unused" } }, shown(bufnr))
    end)
    assert.is_true(dropped, vim.inspect(shown(bufnr)))
  end)

  it("maps related information in other cells to the notebook", function()
    local bufnr, cells = protocol.open_example(env)
    local d = diagnostic(1, 11, "redefined")
    d.relatedInformation = {
      { location = { uri = cells[1], range = diagnostic(1, 0).range }, message = "first defined here" },
    }
    publish(cells[2], { d })
    local related = vim.diagnostic.get(bufnr)[1].user_data.lsp.relatedInformation[1].location
    assert.equal(vim.uri_from_bufnr(bufnr), related.uri)
    assert.equal(rows.cell1 + 1, related.range.start.line)
  end)

  -- The server may publish for a cell before it hears that the cell is gone.
  it("ignores diagnostics published for a removed cell", function()
    local bufnr, cells = protocol.open_example(env)
    vim.api.nvim_buf_set_lines(bufnr, rows.cell2 - 1, rows.cell2 + 3, true, {})
    env.server:wait_for("notebookDocument/didChange")
    publish(cells[2], { diagnostic(1, 11, "undefined") })
    vim.wait(100)
    assert.same({}, shown(bufnr))
  end)
end)

describe("pulled diagnostics", function()
  local env ---@type ProtocolEnv

  before_each(function()
    local capabilities = vim.deepcopy(fake_server.capabilities)
    capabilities.diagnosticProvider = { interFileDependencies = false, workspaceDiagnostics = false }
    env = protocol.start({
      capabilities = capabilities,
      handlers = {
        ["textDocument/diagnostic"] = function(params)
          local items = {
            ["1"] = { diagnostic(0, 7, "unused") },
            ["2"] = { diagnostic(1, 11, "undefined") },
          }
          return { kind = "full", resultId = "r", items = items[params.textDocument.uri:match("#c(%d+)$")] }
        end,
      },
    })
  end)

  after_each(function()
    protocol.stop()
  end)

  local function wait_shown(bufnr, expected)
    local found = vim.wait(1000, function()
      return vim.deep_equal(expected, shown(bufnr))
    end)
    assert.is_true(found, vim.inspect(shown(bufnr)))
  end

  it("combines the diagnostics of every cell", function()
    local bufnr = protocol.open_example(env)
    wait_shown(bufnr, {
      { lnum = rows.cell1, col = 7, message = "unused" },
      { lnum = rows.cell2 + 1, col = 11, message = "undefined" },
    })
  end)

  -- The cells' reports can't be compared to a report of the whole notebook.
  it("pulls full reports again when cells move", function()
    local bufnr = protocol.open_example(env)
    wait_shown(bufnr, {
      { lnum = rows.cell1, col = 7, message = "unused" },
      { lnum = rows.cell2 + 1, col = 11, message = "undefined" },
    })
    vim.api.nvim_buf_set_lines(bufnr, rows.prose, rows.prose, true, { "More", "prose." })
    wait_shown(bufnr, {
      { lnum = rows.cell1, col = 7, message = "unused" },
      { lnum = rows.cell2 + 3, col = 11, message = "undefined" },
    })
    for _, params in ipairs(env.server:received("textDocument/diagnostic")) do
      assert.is_nil(params.previousResultId)
    end
  end)

  -- ruff does both for notebook cells, which would show each of its diagnostics twice.
  it("ignores diagnostics the server also pushes", function()
    local bufnr, cells = protocol.open_example(env)
    env.server:notify(
      "textDocument/publishDiagnostics",
      { uri = cells[1], diagnostics = { diagnostic(0, 7, "unused") } }
    )
    wait_shown(bufnr, {
      { lnum = rows.cell1, col = 7, message = "unused" },
      { lnum = rows.cell2 + 1, col = 11, message = "undefined" },
    })
    vim.wait(100)
    assert.equal(2, #vim.diagnostic.get(bufnr))
  end)
end)
