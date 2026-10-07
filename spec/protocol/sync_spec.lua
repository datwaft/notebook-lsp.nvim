local protocol = require("helpers.protocol")

local rows = protocol.example.rows

describe("notebook synchronization", function()
  local env ---@type ProtocolEnv

  before_each(function()
    env = protocol.start()
  end)

  after_each(function()
    protocol.stop()
  end)

  it("opens the notebook with one cell per code cell in the kernel's language", function()
    protocol.open_example(env)
    local opened = env.server:wait_for("notebookDocument/didOpen")
    assert.equal("jupyter-notebook", opened.notebookDocument.notebookType)
    assert.same(
      protocol.example.texts,
      vim.tbl_map(function(document)
        return document.text
      end, opened.cellTextDocuments)
    )
    for i, document in ipairs(opened.cellTextDocuments) do
      assert.equal("python", document.languageId)
      assert.same({ kind = 2, document = document.uri }, opened.notebookDocument.cells[i])
    end
  end)

  it("doesn't open the Markdown file itself as a text document", function()
    protocol.open_example(env)
    assert.same({}, env.server:received("textDocument/didOpen"))
  end)

  it("sends an edit inside a cell as a change to that cell only", function()
    local bufnr, cells = protocol.open_example(env)
    vim.api.nvim_buf_set_text(bufnr, rows.cell1 + 1, 4, rows.cell1 + 1, 5, { "2" }) -- x = 1 -> x = 2
    local change = env.server:wait_for("notebookDocument/didChange").change.cells
    assert.is_nil(change.structure)
    assert.equal(1, #change.textContent)
    assert.equal(cells[1], change.textContent[1].document.uri)
    assert.equal("import os\nx = 2\n", protocol.apply_changes(protocol.example.texts[1], change.textContent[1].changes))
  end)

  it("doesn't tell the server about edits outside cells", function()
    local bufnr = protocol.open_example(env)
    vim.api.nvim_buf_set_lines(bufnr, rows.prose, rows.prose + 1, true, { "Different prose." })
    vim.api.nvim_buf_set_lines(bufnr, rows.prose + 3, rows.prose + 4, true, { "echo bye" }) -- the bash cell
    -- Neovim sends pending changes before any request
    vim.lsp.buf_request_sync(bufnr, "textDocument/hover", {
      textDocument = { uri = vim.uri_from_bufnr(bufnr) },
      position = protocol.position(bufnr, rows.cell1, "os"),
    })
    assert.same({}, env.server:received("notebookDocument/didChange"))
  end)

  it("adds a cell with a structural change", function()
    local bufnr, cells = protocol.open_example(env)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, { "", "```python", "y = 2", "```" })
    local structure = env.server:wait_for("notebookDocument/didChange").change.cells.structure
    assert.equal(2, structure.array.start)
    assert.equal(0, structure.array.deleteCount)
    assert.equal(1, #structure.didOpen)
    assert.equal("y = 2\n", structure.didOpen[1].text)
    assert.same({ { kind = 2, document = structure.didOpen[1].uri } }, structure.array.cells)
    assert.is_false(vim.tbl_contains(cells, structure.didOpen[1].uri), "a new cell needs a new URI")
  end)

  it("removes a cell with a structural change", function()
    local bufnr, cells = protocol.open_example(env)
    vim.api.nvim_buf_set_lines(bufnr, rows.cell2 - 1, rows.cell2 + 3, true, {}) -- the second Python cell
    local structure = env.server:wait_for("notebookDocument/didChange").change.cells.structure
    assert.equal(1, structure.array.start)
    assert.equal(1, structure.array.deleteCount)
    assert.same({ { uri = cells[2] } }, structure.didClose)
  end)

  it("tells the server when the notebook is saved", function()
    local bufnr = protocol.open_example(env)
    local notebook = env.server:wait_for("notebookDocument/didOpen").notebookDocument.uri
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd.write()
    end)
    assert.equal(notebook, env.server:wait_for("notebookDocument/didSave").notebookDocument.uri)
  end)

  it("closes the notebook and its cells with the buffer", function()
    local bufnr, cells = protocol.open_example(env)
    local notebook = env.server:wait_for("notebookDocument/didOpen").notebookDocument.uri
    vim.api.nvim_buf_delete(bufnr, { force = true })
    local closed = env.server:wait_for("notebookDocument/didClose")
    assert.equal(notebook, closed.notebookDocument.uri)
    assert.same({ { uri = cells[1] }, { uri = cells[2] } }, closed.cellTextDocuments)
  end)
end)
