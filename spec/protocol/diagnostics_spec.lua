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
  -- The related reports the server adds to its report for a document, if any
  local related ---@type (fun(uri: string): table<string, lsp.FullDocumentDiagnosticReport>?)?

  before_each(function()
    related = nil
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
          local uri = params.textDocument.uri
          return {
            kind = "full",
            resultId = "r",
            items = items[uri:match("#c(%d+)$")] or {},
            relatedDocuments = related and related(uri),
          }
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

  -- As for pushed diagnostics: the server gets its own back, though the other notebook's cells moved
  it("gives the server its pulled diagnostics back in a code action request", function()
    local other_cell = (vim.uri_from_fname(env.dir .. "/other.md.ipynb"):gsub("^file:", "vscode-notebook-cell:"))
      .. "#c2"
    local pulled = diagnostic(1, 11, "x is redefined")
    pulled.relatedInformation = {
      { location = { uri = other_cell, range = diagnostic(1, 0, "").range }, message = "elsewhere" },
    }
    env.server.handlers["textDocument/diagnostic"] = function(params)
      return {
        kind = "full",
        items = vim.endswith(params.textDocument.uri, "/notebook.md.ipynb#c2") and { pulled } or {},
      }
    end
    local other_bufnr = protocol.open(env, "other.md", protocol.notebook(protocol.example.body))
    protocol.wait_attached(env, other_bufnr)
    local bufnr = protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body))
    local client = protocol.wait_attached(env, bufnr)
    wait_shown(bufnr, { { lnum = rows.cell2 + 1, col = 11, message = "x is redefined" } })
    vim.api.nvim_buf_set_lines(other_bufnr, rows.prose, rows.prose, true, { "More", "prose." })

    local position = { line = rows.cell2 + 1, character = 11 }
    assert(client:request_sync("textDocument/codeAction", {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      range = { start = position, ["end"] = position },
      context = { diagnostics = { vim.diagnostic.get(bufnr)[1].user_data.lsp } },
    }, 1000, bufnr))
    assert.same({ pulled }, env.server:wait_for("textDocument/codeAction").context.diagnostics)
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

  --- Whether Neovim has a buffer for a cell, which only the plugin knows about.
  local function has_cell_buffer()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.startswith(vim.api.nvim_buf_get_name(buf), "vscode-notebook-cell:") then
        return true
      end
    end
    return false
  end

  -- Related reports about cells are left out: replacing the notebook's diagnostics with a
  -- cell's would lose the other cells'. Those about other files are Neovim's to show.
  it("keeps the related reports of a cell's report that are about other files", function()
    local utils = vim.uri_from_fname(env.dir .. "/utils.py")
    related = function(uri)
      if uri:match("#c1$") then
        return {
          [(uri:gsub("#c1$", "#c2"))] = { kind = "full", items = { diagnostic(0, 0, "related to cell 2") } },
          [utils] = { kind = "full", items = { diagnostic(0, 0, "in utils") } },
        }
      end
    end
    local bufnr = protocol.open_example(env)
    wait_shown(bufnr, {
      { lnum = rows.cell1, col = 7, message = "unused" },
      { lnum = rows.cell2 + 1, col = 11, message = "undefined" },
    })
    wait_shown(vim.uri_to_bufnr(utils), { { lnum = 0, col = 0, message = "in utils" } })
    assert.is_false(has_cell_buffer())
  end)

  it("leaves out related reports about cells from the reports of other files", function()
    local bufnr, cells = protocol.open_example(env)
    wait_shown(bufnr, {
      { lnum = rows.cell1, col = 7, message = "unused" },
      { lnum = rows.cell2 + 1, col = 11, message = "undefined" },
    })
    related = function(uri)
      if vim.endswith(uri, "utils.py") then
        return { [cells[1]] = { kind = "full", items = { diagnostic(1, 0, "related to cell 1") } } }
      end
    end
    -- A diagnostic of its own, to see once the report is shown
    local pull = env.server.handlers["textDocument/diagnostic"]
    env.server.handlers["textDocument/diagnostic"] = function(params)
      local report = pull(params)
      if vim.endswith(params.textDocument.uri, "utils.py") then
        report.items = { diagnostic(0, 0, "in utils") }
      end
      return report
    end
    local utils = protocol.open(env, "utils.py", { "x = 1" })
    protocol.wait_attached(env, utils)
    wait_shown(utils, { { lnum = 0, col = 0, message = "in utils" } })
    assert.is_false(has_cell_buffer())
    assert.same({
      { lnum = rows.cell1, col = 7, message = "unused" },
      { lnum = rows.cell2 + 1, col = 11, message = "undefined" },
    }, shown(bufnr))
  end)
end)
