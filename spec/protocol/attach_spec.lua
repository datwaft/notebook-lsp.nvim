local fake_server = require("helpers.fake_server")
local protocol = require("helpers.protocol")

describe("attaching", function()
  local env ---@type ProtocolEnv

  after_each(function()
    protocol.stop()
  end)

  --- Whether the server received a textDocument/didOpen for `bufnr`.
  local function opened_as_text(bufnr)
    for _, params in ipairs(env.server:received("textDocument/didOpen")) do
      if params.textDocument.uri == vim.uri_from_bufnr(bufnr) then
        return true
      end
    end
    return false
  end

  --- Whether the server's client detaches from a buffer, from now on.
  local function watch_detaching()
    local detached = false
    vim.api.nvim_create_autocmd("LspDetach", {
      callback = function(event)
        detached = detached or vim.lsp.get_client_by_id(event.data.client_id).name == env.name
      end,
    })
    return function()
      return detached
    end
  end

  describe("to a server with notebook support", function()
    before_each(function()
      env = protocol.start()
    end)

    it("attaches to a jupytext notebook whose kernel language is one of the server's filetypes", function()
      local bufnr = protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body))
      protocol.wait_attached(env, bufnr)
    end)

    -- Negative cases: once a .py file opened afterwards is attached, the
    -- decision for the Markdown buffer opened before it has been made.

    it("doesn't let Markdown that isn't a jupytext notebook reach the server", function()
      local markdown = protocol.open(env, "plain.md", { "# Plain", "", "```python", "import os", "```" })
      protocol.wait_attached(env, protocol.open(env, "utils.py", { "x = 1" }))
      assert.same({}, vim.lsp.get_clients({ bufnr = markdown }))
      assert.is_false(opened_as_text(markdown))
    end)

    it("doesn't attach to a notebook whose kernel is in another language", function()
      local lines = protocol.notebook({ "", "```julia", "x = 1", "```" })
      lines[11] = "    language: julia"
      local markdown = protocol.open(env, "julia.md", lines)
      protocol.wait_attached(env, protocol.open(env, "utils.py", { "x = 1" }))
      assert.same({}, vim.lsp.get_clients({ bufnr = markdown }))
    end)

    describe("with vim.b.notebook_lsp", function()
      --- Sets `vim.b.notebook_lsp` to `value` in the next Markdown buffer read,
      --- before its filetype is set (see options_spec for after/ftplugin/).
      local function set_in_next_markdown(value)
        vim.api.nvim_create_autocmd("BufReadPre", {
          pattern = "*.md",
          once = true,
          callback = function(event)
            vim.b[event.buf].notebook_lsp = value
          end,
        })
      end

      it("doesn't attach to a notebook that opts out", function()
        set_in_next_markdown(false)
        local markdown = protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body))
        protocol.wait_attached(env, protocol.open(env, "utils.py", { "x = 1" }))
        assert.same({}, vim.lsp.get_clients({ bufnr = markdown }))
        assert.same({}, env.server:received("notebookDocument/didOpen"))
        assert.is_false(opened_as_text(markdown))
      end)

      it("fails on values other than false", function()
        set_in_next_markdown(true)
        assert.has_error(function()
          protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body))
        end, nil)
      end)
    end)

    it("serves .py files and notebooks of the same project with one client", function()
      local notebook =
        protocol.wait_attached(env, protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body)))
      local py = protocol.wait_attached(env, protocol.open(env, "utils.py", { "x = 1" }))
      assert.equal(notebook.id, py.id)
      assert.equal(1, #vim.lsp.get_clients({ name = env.name }))
    end)

    it("attaches to a client that .py files started", function()
      local py = protocol.wait_attached(env, protocol.open(env, "utils.py", { "x = 1" }))
      local notebook =
        protocol.wait_attached(env, protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body)))
      assert.equal(py.id, notebook.id)
    end)

    it("gives .py files the root of the server's root_markers", function()
      local client = protocol.wait_attached(env, protocol.open(env, "utils.py", { "x = 1" }))
      assert.equal(env.dir, client.root_dir)
    end)

    it("opens .py files as plain text documents", function()
      protocol.wait_attached(env, protocol.open(env, "utils.py", { "x = 1" }))
      local opened = env.server:wait_for("textDocument/didOpen")
      assert.equal(vim.uri_from_fname(env.dir .. "/utils.py"), opened.textDocument.uri)
      assert.equal("python", opened.textDocument.languageId)
    end)

    it("stays attached when the notebook's filetype is set again", function()
      local bufnr = protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body))
      local client = protocol.wait_attached(env, bufnr)
      local detached = watch_detaching()
      vim.bo[bufnr].filetype = "markdown"
      vim.wait(100)
      assert.is_false(detached())
      assert.equal(client.id, protocol.wait_attached(env, bufnr).id)
    end)

    it("starts the server with Neovim's capabilities, plus notebook synchronization", function()
      protocol.wait_attached(env, protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body)))
      local initialize = env.server:wait_for("initialize")
      local expected = vim.lsp.protocol.make_client_capabilities()
      expected.notebookDocument = { synchronization = { dynamicRegistration = false, executionSummarySupport = false } }
      assert.same(expected, initialize.capabilities)
    end)
  end)

  -- vim.lsp.enable() attaches to the buffers that are already open.
  it("attaches to notebooks that were open before the server was enabled", function()
    env = protocol.start({ enable = false })
    local bufnr = protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body))
    vim.lsp.enable(env.name)
    protocol.wait_attached(env, bufnr)
  end)

  -- Whether a server syncs notebooks is known only once it's initialized, after attaching.
  it("detaches from servers without notebook support, without opening the notebook", function()
    local capabilities = vim.deepcopy(fake_server.capabilities)
    capabilities.notebookDocumentSync = nil
    env = protocol.start({ capabilities = capabilities })
    local detached = watch_detaching()
    local markdown = protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body))
    assert.is_true(vim.wait(1000, detached, 5))
    assert.same({}, vim.lsp.get_clients({ bufnr = markdown }))
    assert.is_false(opened_as_text(markdown))
  end)

  describe("to a server whose notebook selector", function()
    --- Starts a server whose only notebook selector is `selector`, opens the
    --- example notebook and returns what the server opened, if anything.
    local function open(selector)
      local capabilities = vim.deepcopy(fake_server.capabilities)
      capabilities.notebookDocumentSync = { notebookSelector = { selector } }
      env = protocol.start({ capabilities = capabilities })
      local detached = watch_detaching()
      protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body))
      vim.wait(1000, function()
        return detached() or #env.server:received("notebookDocument/didOpen") > 0
      end, 5)
      return env.server:received("notebookDocument/didOpen")[1]
    end

    local python = { { language = "python" } }

    it("names any notebook", function()
      assert.is_not_nil(open({ notebook = "*", cells = python }))
    end)

    it("names jupyter notebooks", function()
      assert.is_not_nil(open({ notebook = "jupyter-notebook", cells = python }))
    end)

    it("names notebooks of another type", function()
      assert.is_nil(open({ notebook = "interactive", cells = python }))
    end)

    it("names jupyter notebooks on disk by a pattern", function()
      local filter = { notebookType = "jupyter-notebook", scheme = "file", pattern = "**/*.ipynb" }
      assert.is_not_nil(open({ notebook = filter, cells = python }))
    end)

    it("names notebooks with another scheme", function()
      assert.is_nil(open({ notebook = { scheme = "untitled" }, cells = python }))
    end)

    it("names notebooks elsewhere", function()
      assert.is_nil(open({ notebook = { pattern = "**/elsewhere/*.ipynb" }, cells = python }))
    end)

    -- That would be every cell, prose included: the plugin syncs the code cells in the kernel's language
    it("names no cells", function()
      local opened = assert(open({ notebook = "*" }))
      assert.same(protocol.example.texts, {
        opened.cellTextDocuments[1].text,
        opened.cellTextDocuments[2].text,
      })
      assert.equal(2, #opened.cellTextDocuments)
    end)
  end)
end)
