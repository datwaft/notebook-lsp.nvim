# notebook-lsp.nvim

LSP support for [jupytext](https://jupytext.readthedocs.io) Markdown notebooks
in Neovim, through the LSP notebook protocol (`notebookDocument/*`).

Neovim edits the notebook as one Markdown buffer. Your existing language
servers (basedpyright, ty, ruff, ...) see a notebook whose cells are exactly
the code cells jupytext would produce: diagnostics, completion, code actions,
formatting and rename work inside cells, and names are shared across cells.

> [!WARNING]
> Work in progress: nothing works yet.

## Requirements

- Neovim nightly
- Language servers that support the LSP notebook protocol

## Development

Tests run with [busted](https://lunarmodules.github.io/busted/) inside Neovim
(through [nlua](https://codeberg.org/mfussenegger/nlua)), managed by
[lux](https://github.com/lumen-oss/lux):

```sh
lx test                 # unit and protocol tests: fast, no external tools
lx test -- --run=e2e    # oracle and end-to-end tests: need uv
```

| Directory | What it tests |
|---|---|
| `spec/unit` | Pure modules, such as the jupytext cell reader |
| `spec/protocol` | The plugin between Neovim's LSP client and an in-process fake server |
| `spec/oracle` | That the reader's fixtures match what jupytext itself produces |
| `spec/e2e` | Real servers in a separate Neovim process |

The oracle and end-to-end tests run pinned versions of jupytext and the
language servers through `uvx` (see `spec/helpers/tools.lua`), with uv's cache
in `.tests/`.
