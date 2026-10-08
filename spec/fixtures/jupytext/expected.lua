-- What reading each fixture notebook must return. `start` is the 0-based row of
-- the cell's first line of code. spec/oracle checks the cells against jupytext
-- itself, so these expectations are jupytext's behaviour, not our guess.
return {
  {
    file = "basic.md",
    description = "reads Python cells and where they start",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 17, lines = { "import os", "x = 1" } },
        { language = "python", start = 24, lines = { "y = x + 1" } },
      },
    },
  },
  {
    file = "other_languages.md",
    description = "reads cells in other Jupyter languages under their own language, and the kernel's language case-insensitively",
    notebook = {
      language = "python",
      cells = {
        { language = "bash", start = 15, lines = { "echo hi" } },
        { language = "python3", start = 19, lines = { "three = 3" } },
        { language = "R", start = 23, lines = { "r <- 1" } },
        { language = "python", start = 27, lines = { "upper = 1" } },
      },
    },
  },
  {
    file = "indented_fence.md",
    description = "ignores fences that don't start at column 0",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 21, lines = { "last = 1" } },
      },
    },
  },
  {
    file = "regions.md",
    description = "ignores code inside region, md and raw comments",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 33, lines = { "last = 1" } },
      },
    },
  },
  {
    file = "noeval.md",
    description = "ignores cells marked .noeval",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 19, lines = { "last = 1" } },
      },
    },
  },
  {
    file = "non_jupyter_fence.md",
    description = "ignores code blocks in non-Jupyter languages, including fences inside them",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 20, lines = { "last = 1" } },
      },
    },
  },
  {
    file = "indented_code_block.md",
    description = "ignores indented code blocks, including fences inside them",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 21, lines = { "last = 1" } },
      },
    },
  },
  {
    file = "myst_directive.md",
    description = "ignores MyST directives",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 19, lines = { "last = 1" } },
      },
    },
  },
  {
    file = "four_backticks.md",
    description = "ends a cell only at a fence with as many backticks as it opened with",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 15, lines = { 'four = """', "```", '"""' } },
      },
    },
  },
  {
    file = "fence_options.md",
    description = "reads cells with metadata after the language",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 15, lines = { "alpha = 0.1" } },
      },
    },
  },
  {
    file = "empty_cell.md",
    description = "reads empty cells",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 15, lines = {} },
      },
    },
  },
  {
    file = "blank_lines.md",
    description = "keeps blank lines inside cells",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 15, lines = { "def f():", "", "    return 1" } },
      },
    },
  },
  {
    file = "unterminated.md",
    description = "reads an unterminated cell up to the end of the file",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 15, lines = { "first = 1" } },
        { language = "python", start = 19, lines = { "unterminated = 1" } },
      },
    },
  },
  {
    file = "main_language.md",
    description = "uses jupytext's main_language when there is no kernelspec",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 12, lines = { "from_main_language = 1" } },
      },
    },
  },
  {
    file = "main_language_over_kernel.md",
    description = "prefers jupytext's main_language over the kernel's language, as multi-language kernels need",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 16, lines = { "x = 1" } },
        { language = "R", start = 20, lines = { "r <- 1" } },
      },
    },
  },
  {
    file = "fence_in_string.md",
    description = "doesn't end a cell at a fence inside a multi-line string",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 15, lines = { 'doc = """', "```", '"""' } },
        { language = "python", start = 21, lines = { "last = 1" } },
      },
    },
  },
  {
    file = "inactive.md",
    description = "ignores cells that are not active in notebooks",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 23, lines = { "in_notebooks = 1" } },
      },
    },
  },
  {
    file = "hidden_header.md",
    description = "reads a header hidden in an HTML comment",
    notebook = {
      language = "python",
      cells = {
        { language = "python", start = 20, lines = { "hidden = 1" } },
      },
    },
  },
}
