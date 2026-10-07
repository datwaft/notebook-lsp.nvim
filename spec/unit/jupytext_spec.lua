local jupytext = require("notebook_lsp.jupytext")
local expected = require("fixtures.jupytext.expected")

local function read(file)
  return jupytext.read(vim.fn.readfile("spec/fixtures/jupytext/" .. file))
end

describe("jupytext.read", function()
  for _, case in ipairs(expected) do
    it(case.description .. " (" .. case.file .. ")", function()
      assert.same(case.notebook, read(case.file))
    end)
  end

  it("returns nil for Markdown without front matter", function()
    assert.is_nil(read("plain.md"))
  end)

  it("returns nil for front matter without jupytext metadata", function()
    assert.is_nil(read("front_matter_without_jupyter.md"))
  end)

  it("rejects jupytext formats other than Markdown", function()
    assert.error_matches(function()
      read("myst.md")
    end, "unsupported jupytext format: myst")
  end)

  it("rejects Markdown format versions before 1.2, which split cells differently", function()
    assert.error_matches(function()
      read("old_format_version.md")
    end, "unsupported jupytext Markdown format version 1.1")
  end)

  it("rejects notebooks without a kernel language", function()
    assert.error_matches(function()
      read("no_language.md")
    end, "the notebook has no kernel language")
  end)
end)
