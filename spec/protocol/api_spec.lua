local protocol = require("helpers.protocol")

local notebook_lsp = require("notebook_lsp")
local rows = protocol.example.rows

describe("the Lua API", function()
  local env ---@type ProtocolEnv

  before_each(function()
    env = protocol.start()
  end)

  after_each(function()
    protocol.stop()
  end)

  describe("is_notebook()", function()
    it("is true for a notebook the plugin serves", function()
      local bufnr = protocol.open_example(env)
      assert.is_true(notebook_lsp.is_notebook(bufnr))
      assert.is_true(notebook_lsp.is_notebook())
    end)

    it("is false for other buffers", function()
      local markdown = protocol.open(env, "plain.md", { "# Title", "", "```python", "x = 1", "```" })
      local py = protocol.open(env, "utils.py", { "x = 1" })
      assert.is_false(notebook_lsp.is_notebook(markdown))
      assert.is_false(notebook_lsp.is_notebook(py))
    end)

    -- Through vim.b.notebook_lsp = false, before the filetype is set
    it("is false for a notebook kept away from servers", function()
      vim.api.nvim_create_autocmd("BufReadPre", {
        pattern = "*.md",
        once = true,
        callback = function(args)
          vim.b[args.buf].notebook_lsp = false
        end,
      })
      local bufnr = protocol.open(env, "notebook.md", protocol.notebook(protocol.example.body))
      assert.is_false(notebook_lsp.is_notebook(bufnr))
    end)

    it("is false once the buffer is wiped", function()
      local bufnr = protocol.open_example(env)
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_false(notebook_lsp.is_notebook(bufnr))
    end)
  end)

  describe("cells()", function()
    it("gives each code cell's id, first row and lines, in order", function()
      local bufnr = protocol.open_example(env)
      assert.same({
        { id = 1, start = rows.cell1, lines = { "import os", "x = 1" } },
        { id = 2, start = rows.cell2, lines = { "def f():", "    return x" } },
      }, notebook_lsp.cells(bufnr))
    end)

    it("follows the cells as the buffer changes, each keeping its id", function()
      local bufnr = protocol.open_example(env)
      vim.api.nvim_buf_set_lines(bufnr, rows.prose, rows.prose, true, { "More", "prose." })
      vim.api.nvim_buf_set_lines(bufnr, rows.cell1 + 1, rows.cell1 + 2, true, { "x = 2" })
      assert.same({
        { id = 1, start = rows.cell1, lines = { "import os", "x = 2" } },
        { id = 2, start = rows.cell2 + 2, lines = { "def f():", "    return x" } },
      }, notebook_lsp.cells(bufnr))
    end)

    it("gives copies, which the plugin doesn't see changes to", function()
      local bufnr = protocol.open_example(env)
      local cells = notebook_lsp.cells(bufnr)
      cells[1].lines[1] = "changed"
      cells[1].start = 0
      assert.same({ id = 1, start = rows.cell1, lines = { "import os", "x = 1" } }, notebook_lsp.cells(bufnr)[1])
    end)

    it("fails for a buffer that isn't a notebook", function()
      local py = protocol.open(env, "utils.py", { "x = 1" })
      assert.error_matches(function()
        notebook_lsp.cells(py)
      end, "isn't a notebook")
    end)
  end)

  describe("cell_at()", function()
    it("gives the cell whose code has the row", function()
      local bufnr = protocol.open_example(env)
      assert.same(
        { id = 2, start = rows.cell2, lines = { "def f():", "    return x" } },
        notebook_lsp.cell_at(bufnr, rows.cell2 + 1)
      )
    end)

    it("gives nothing outside the cells' code, fences included", function()
      local bufnr = protocol.open_example(env)
      assert.is_nil(notebook_lsp.cell_at(bufnr, rows.prose))
      assert.is_nil(notebook_lsp.cell_at(bufnr, rows.cell1 - 1))
      assert.is_nil(notebook_lsp.cell_at(bufnr, rows.cell1_fence))
    end)

    it("fails for a buffer that isn't a notebook", function()
      local py = protocol.open(env, "utils.py", { "x = 1" })
      assert.error_matches(function()
        notebook_lsp.cell_at(py, 0)
      end, "isn't a notebook")
    end)
  end)
end)
