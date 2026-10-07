-- The PoC's scenario with real servers: basedpyright and ruff on
-- spec/fixtures/projects/python/analysis.md, through Neovim's own LSP functions.
local child_process = require("helpers.child")
local project = require("helpers.project")

local SERVERS = { "basedpyright", "ruff" }

-- {text on the line, Lua pattern of the message}
local EXPECTED_DIAGNOSTICS = {
  { 'x: int = "oops"', "not assignable" }, -- basedpyright
  { "return x + Ordered", '"Ordered" is not defined' }, -- basedpyright
  { "return x + Ordered", "Undefined name `Ordered`" }, -- ruff
  { 'helper("not an int")', 'parameter "n"' }, -- basedpyright, needs utils.py's signature
  { "import os", "`os` imported but unused" }, -- ruff
}

describe("basedpyright and ruff on a notebook", function()
  local child ---@type Child
  local dir ---@type string

  before_each(function()
    dir = project.copy("python")
    child = child_process.start()
    child:call("setup", SERVERS)
    child:call("edit", dir .. "/analysis.md")
    -- generous: the first run downloads the servers
    assert(child:wait_for(120000, "attached_exactly", SERVERS), "servers did not attach to the notebook")
    -- every diagnostic the fixture is known to produce, so that checks for the
    -- absence of a diagnostic don't pass just because the servers are still busy
    for _, expected in ipairs(EXPECTED_DIAGNOSTICS) do
      assert(
        child:wait_for(30000, "has_diagnostic", expected[1], expected[2]),
        "no diagnostic: " .. vim.inspect(expected)
      )
    end
  end)

  after_each(function()
    child:stop()
    vim.fn.delete(dir, "rf")
  end)

  it("doesn't attach to Markdown that isn't a jupytext notebook", function()
    child:call("edit", dir .. "/utils.py")
    assert(child:wait_for(30000, "attached_exactly", SERVERS))
    child:call("edit", dir .. "/plain.md")
    assert.same({}, child:call("attached"))
  end)

  it("reports diagnostics on the lines of the cells", function()
    -- before_each waited for EXPECTED_DIAGNOSTICS; this checks nothing else is reported
    local rows = {}
    for _, diagnostic in ipairs(child:call("diagnostics")) do
      rows[diagnostic.line] = true
    end
    assert.same({
      ["import os"] = true,
      ['x: int = "oops"'] = true,
      ["def f():"] = true, -- basedpyright: return type is unknown
      ["    return x + Ordered"] = true,
      ['y = helper("not an int")'] = true,
    }, rows)
  end)

  it("shares names between cells", function()
    assert.is_false(child:call("has_diagnostic", "return x + Ordered", '"x" is not defined'))
  end)

  it("accepts IPython magics", function()
    assert.is_false(child:call("has_any_diagnostic", "%matplotlib inline"))
  end)

  it("ignores code blocks that aren't cells", function()
    assert.is_false(child:call("has_any_diagnostic", "undefined_in_region"))
    assert.is_false(child:call("has_any_diagnostic", "undefined_in_list"))
    assert.is_false(child:call("has_any_diagnostic", "echo $HOME"))
  end)

  it("shows hover information, including from other files", function()
    assert.matches("def helper%(n: int%) %-> str", child:call("hover", "basedpyright", 'helper("not'))
    assert.is_nil(child:call("hover", "basedpyright", "The prose mentions"))
  end)

  it("goes to definitions in other cells and in other files", function()
    local x_row = child:call("row", 'x: int = "oops"')
    assert.same({ { file = "analysis.md", row = x_row } }, child:call("definition", "basedpyright", "return x", 7))
    assert.same({ { file = "utils.py", row = 0 } }, child:call("definition", "basedpyright", 'helper("not'))
  end)

  it("puts auto-imports at the top of the cell being edited", function()
    child:call("complete", "basedpyright", "Ordered", "OrderedDict")
    local text = child:call("text")
    assert.matches("```python\nfrom typing import OrderedDict\n+def f%(%):\n    return x %+ OrderedDict\n", text)
  end)

  it("applies ruff's code actions inside the cell", function()
    -- on `os`: the diagnostic the action fixes covers only the module name
    child:call("code_action", "ruff", "import os", #"import ", "Remove unused import")
    local text = child:call("text")
    assert.is_nil(text:find("import os", 1, true))
    assert.matches("```python\n%%matplotlib inline\nfrom utils import helper\n", text)
  end)

  it("formats the cells with ruff and leaves everything else alone", function()
    local before = child:call("text")
    child:call("format", "ruff")
    local text = child:call("text")
    assert.matches("\nz = %[1, 2, 3%]\n", text)
    for _, untouched in ipairs({
      "The prose mentions helper and x too.",
      "```bash\necho $HOME\n```",
      "<!-- #region -->\n```python\nin_region = undefined_in_region\n```\n<!-- #endregion -->",
      "  ```python\n  indented = undefined_in_list\n  ```",
    }) do
      assert.truthy(before:find(untouched, 1, true))
      assert.truthy(text:find(untouched, 1, true), untouched)
    end
  end)

  it("renames across the notebook from a .py file, with one client per server", function()
    local notebook = dir .. "/analysis.md"
    child:call("edit", dir .. "/utils.py")
    assert(child:wait_for(30000, "attached_exactly", SERVERS))
    assert.equal(2, child:call("client_count"))
    child:call("rename", "basedpyright", "helper", "to_text", notebook)
    local text = child:call("text_of", notebook)
    assert.truthy(text:find("from utils import to_text", 1, true))
    assert.truthy(text:find('y = to_text("not an int")', 1, true))
    assert.truthy(text:find("The prose mentions helper", 1, true), "prose must not be renamed")
  end)

  it("keeps diagnostics on their lines while cells move, appear and disappear", function()
    child:call(
      "set_lines",
      child:call("row", "# Analysis") + 1,
      child:call("row", "# Analysis") + 1,
      { "", "New", "prose." }
    )
    assert.is_true(child:wait_for(10000, "has_diagnostic", 'x: int = "oops"', "not assignable"))
    assert.is_true(child:wait_for(10000, "has_diagnostic", "return x + Ordered", "Ordered"))

    local last = #child:call("lines")
    child:call("set_lines", last, last, { "", "```python", "new_cell = undefined_new", "```" })
    assert.is_true(child:wait_for(30000, "has_diagnostic", "undefined_new", "undefined_new"))

    child:call("set_lines", last, last + 4, {})
    assert.is_true(child:wait_for(30000, "has_no_diagnostic", "undefined_new"))
  end)
end)
