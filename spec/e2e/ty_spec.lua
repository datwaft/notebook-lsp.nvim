-- ty on the same notebook: a second type checker, to keep the plugin from
-- depending on one server's behaviour.
local child_process = require("helpers.child")
local project = require("helpers.project")

describe("ty on a notebook", function()
  local child ---@type Child
  local dir ---@type string

  before_each(function()
    dir = project.copy("python")
    child = child_process.start()
    child:call("setup", { "ty" })
    child:call("edit", dir .. "/analysis.md")
    -- generous: the first run downloads the server
    assert(child:wait_for(120000, "attached_exactly", { "ty" }), "ty did not attach to the notebook")
    assert(child:wait_for(30000, "has_diagnostic", "return x + Ordered", "Ordered"), "no diagnostics arrived")
    assert(child:wait_for(30000, "has_diagnostic", 'x: int = "oops"', "not assignable"), "no diagnostics arrived")
  end)

  after_each(function()
    child:stop()
    vim.fn.delete(dir, "rf")
  end)

  it("reports diagnostics on the lines of the cells", function()
    assert.is_false(child:call("has_any_diagnostic", "%matplotlib inline"))
    assert.is_false(child:call("has_any_diagnostic", "undefined_in_region"))
  end)

  it("shows hover information from other files", function()
    assert.matches("def helper%(n: int%) %-> str", child:call("hover", "ty", 'helper("not'))
  end)

  it("goes to definitions in other cells", function()
    local x_row = child:call("row", 'x: int = "oops"')
    assert.same({ { file = "analysis.md", row = x_row } }, child:call("definition", "ty", "return x", 7))
  end)
end)
