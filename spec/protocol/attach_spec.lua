local protocol = require("helpers.protocol")

describe("attaching", function()
  local env ---@type ProtocolEnv

  before_each(function()
    env = protocol.start()
  end)

  after_each(function()
    protocol.stop()
  end)

  it("attaches to a jupytext notebook whose kernel language is one of the server's filetypes", function()
    local bufnr = protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body))
    protocol.wait_attached(env, bufnr)
  end)

  -- Negative cases: once a .py file opened afterwards is attached, the
  -- decision for the Markdown buffer opened before it has been made.

  it("doesn't attach to Markdown that isn't a jupytext notebook", function()
    local markdown = protocol.open(env, "plain.md", { "# Plain", "", "```python", "import os", "```" })
    protocol.wait_attached(env, protocol.open(env, "utils.py", { "x = 1" }))
    assert.same({}, vim.lsp.get_clients({ bufnr = markdown }))
  end)

  it("doesn't attach to a notebook whose kernel is in another language", function()
    local lines = protocol.notebook({ "", "```julia", "x = 1", "```" })
    lines[11] = "    language: julia"
    local markdown = protocol.open(env, "julia.md", lines)
    protocol.wait_attached(env, protocol.open(env, "utils.py", { "x = 1" }))
    assert.same({}, vim.lsp.get_clients({ bufnr = markdown }))
  end)

  it("serves .py files and notebooks of the same project with one client", function()
    local notebook =
      protocol.wait_attached(env, protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body)))
    local py = protocol.wait_attached(env, protocol.open(env, "utils.py", { "x = 1" }))
    assert.equal(notebook.id, py.id)
    assert.equal(1, #vim.lsp.get_clients({ name = env.name }))
  end)

  it("opens .py files as plain text documents", function()
    protocol.wait_attached(env, protocol.open(env, "utils.py", { "x = 1" }))
    local opened = env.server:wait_for("textDocument/didOpen")
    assert.equal(vim.uri_from_fname(env.dir .. "/utils.py"), opened.textDocument.uri)
    assert.equal("python", opened.textDocument.languageId)
  end)

  it("tells the server that the client supports notebooks", function()
    protocol.wait_attached(env, protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body)))
    local initialize = env.server:wait_for("initialize")
    assert.is_table(initialize.capabilities.notebookDocument.synchronization)
  end)

  -- basedpyright answers pull requests for cells with no diagnostics, but pushes them correctly.
  it("asks the server to push diagnostics instead of answering pull requests", function()
    protocol.wait_attached(env, protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body)))
    local initialize = env.server:wait_for("initialize")
    assert.is_nil(initialize.capabilities.textDocument.diagnostic)
  end)
end)
