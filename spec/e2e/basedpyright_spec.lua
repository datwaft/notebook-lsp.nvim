-- basedpyright on the same notebook: a second type checker, to keep the plugin
-- from depending on one server's behaviour. Its diagnostics are left out: it
-- answers pull requests for notebook cells with nothing (a known issue).
local child_process = require("helpers.child")
local project = require("helpers.project")

describe("basedpyright on a notebook", function()
  local child ---@type Child
  local dir ---@type string

  before_each(function()
    dir = project.copy("python")
    child = child_process.start()
    child:call("setup", { "basedpyright" })
    child:call("edit", dir .. "/analysis.md")
    -- generous: the first run downloads the server
    assert(child:wait_for(120000, "attached_exactly", { "basedpyright" }), "basedpyright did not attach")
    -- answers about utils.py once basedpyright has analysed the project
    assert(child:wait_for(30000, "hover", "basedpyright", 'helper("not'), "basedpyright did not answer hovers")
  end)

  after_each(function()
    local errors = child:call("errors")
    child:stop()
    vim.fn.delete(dir, "rf")
    assert.same({}, errors, "errors were printed")
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

  -- ty has call hierarchies too, but its items for cells name the notebook instead (a known issue)
  it("follows the call hierarchy across cells", function()
    local last = #vim.split(child:call("text"), "\n")
    child:call("set_lines", last, last, { "", "```python", "def g():", "    return f()", "```" })
    assert.same({
      {
        name = "g",
        file = "analysis.md",
        row = child:call("row", "def g():"),
        calls = { child:call("row", "return f()") },
      },
    }, child:call("incoming_calls", "basedpyright", "def f():", 4))
  end)

  it("renames across the notebook from a .py file", function()
    local notebook = dir .. "/analysis.md"
    child:call("edit", dir .. "/utils.py")
    assert(child:wait_for(30000, "attached_exactly", { "basedpyright" }))
    child:call("rename", "basedpyright", "helper", "to_text", notebook)
    local text = child:call("text_of", notebook)
    assert.truthy(text:find("from utils import to_text", 1, true))
    assert.truthy(text:find('y = to_text("not an int")', 1, true))
    assert.truthy(text:find("The prose mentions helper", 1, true), "prose must not be renamed")
  end)
end)
