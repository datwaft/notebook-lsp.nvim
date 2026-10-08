-- vim.g.notebook_lsp is read when the plugin loads, at startup: each test
-- loads it in a fresh Neovim.
local child_process = require("helpers.child")

describe("options", function()
  local child ---@type Child

  before_each(function()
    child = child_process.start()
  end)

  after_each(function()
    child:stop()
  end)

  --- Sets `vim.g` options and loads the plugin as Neovim does at startup.
  ---@param globals table<string, any>
  local function load(globals)
    child:lua(
      [[
        for name, value in pairs(...) do
          vim.g[name] = value
        end
        vim.cmd.runtime("plugin/notebook_lsp.lua")
      ]],
      globals
    )
  end

  --- Whether the plugin extended the config named `name` to notebooks.
  ---@param name string
  local function extended(name)
    return child:lua(
      [[
        local config = vim.lsp.config[...]
        return config ~= nil and vim.list_contains(config.filetypes or {}, "markdown")
      ]],
      name
    )
  end

  it("extends the servers known to support notebooks", function()
    load({})
    for _, name in ipairs({ "basedpyright", "pyright", "ruff", "ty" }) do
      assert.is_true(extended(name), name)
    end
  end)

  it("extends other servers, with their filetypes", function()
    load({ notebook_lsp = { servers = { mine = { "python", "cython" } } } })
    assert.same({ "python", "cython", "markdown" }, child:lua("return vim.lsp.config.mine.filetypes"))
    assert.is_true(extended("ty"))
  end)

  it("leaves out the servers set to false", function()
    load({ notebook_lsp = { servers = { pyright = false } } })
    assert.is_false(extended("pyright"))
    assert.is_true(extended("basedpyright"))
  end)

  it("does nothing when the plugin is disabled", function()
    load({ loaded_notebook_lsp = 1 })
    assert.is_false(extended("ty"))
  end)

  -- Neovim enables filetype plugins before it loads the user's config, so their
  -- FileType autocmds run before the one of vim.lsp.enable(), which attaches
  it("lets a notebook opt out from after/ftplugin/markdown.lua", function()
    local attached = child:lua([[
      vim.cmd("filetype plugin on")
      local root = vim.fn.tempname()
      vim.fn.mkdir(root .. "/after/ftplugin", "p")
      vim.fn.writefile({
        'if vim.fs.basename(vim.api.nvim_buf_get_name(0)) == "private.md" then',
        "  vim.b.notebook_lsp = false",
        "end",
      }, root .. "/after/ftplugin/markdown.lua")
      vim.opt.runtimepath:append(root .. "/after")
      vim.cmd.runtime("plugin/notebook_lsp.lua")

      local protocol = require("helpers.protocol")
      local server = require("helpers.fake_server").new()
      vim.lsp.config("fake", { cmd = server.cmd, filetypes = { "python" }, root_markers = { "pyproject.toml" } })
      require("notebook_lsp").extend("fake", { "python" })
      vim.lsp.enable("fake")

      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile({}, dir .. "/pyproject.toml")
      local attached = {}
      for _, name in ipairs({ "private.md", "public.md" }) do
        vim.fn.writefile(protocol.notebook(protocol.example.body), dir .. "/" .. name)
        vim.cmd.edit(dir .. "/" .. name)
        local bufnr = vim.api.nvim_get_current_buf()
        attached[name] = vim.wait(1000, function()
          return #vim.lsp.get_clients({ bufnr = bufnr, name = "fake" }) > 0
        end, 5)
      end
      return attached
    ]])
    assert.same({ ["private.md"] = false, ["public.md"] = true }, attached)
  end)

  it("fails on unknown options", function()
    assert.has_error(function()
      load({ notebook_lsp = { server = { mine = { "python" } } } })
    end)
  end)

  it("fails on servers that aren't lists of filetypes or false", function()
    for _, value in ipairs({ "python", true, {}, { 1 } }) do
      assert.has_error(function()
        load({ notebook_lsp = { servers = { mine = value } } })
      end, nil, vim.inspect(value))
    end
  end)
end)
