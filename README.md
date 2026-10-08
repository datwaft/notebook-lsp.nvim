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
- Language servers that support the LSP notebook protocol: the plugin knows
  [ty](https://github.com/astral-sh/ty), [ruff](https://github.com/astral-sh/ruff),
  [basedpyright](https://github.com/DetachHead/basedpyright) and
  [pyright](https://github.com/microsoft/pyright), configured for example by
  [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)

## Usage

There is nothing to set up: enable the servers with `vim.lsp.enable()` as
usual. When you open a jupytext Markdown notebook, the ones for its kernel's
language attach to it, through the same clients that serve your `.py` files.

To do that, the plugin extends their `vim.lsp.config` entries:

- `filetypes` gets `markdown`, next to the server's own filetypes
- `root_dir` lets through only notebooks in the server's language, and gives
  every other buffer the root of the config's `root_markers`, as Neovim does
  when there is no `root_dir`
- `get_language_id` gives notebooks their cells' language, which Neovim
  matches the server's dynamic registrations against, and every other buffer
  its filetype, as Neovim does by default
- `capabilities` tells the server the client syncs notebooks

If your own config sets `filetypes`, `root_dir` or `get_language_id` for one of
these servers, it replaces the plugin's: keep `markdown` in `filetypes` and
leave the other two unset for notebooks to keep working. Outside notebooks,
servers behave as they would without the plugin.

## Known issues

- Servers only get a notebook's code cells in its kernel's language. A server
  whose notebook selector names no cells asks for all of them, prose included,
  and gets those too.
- A server's dynamic registration that selects documents only by a file
  pattern, such as `**/*.py`, doesn't apply to notebooks.
- Related reports about cells in pulled diagnostics (`relatedDocuments`) are
  ignored: a notebook's diagnostics are updated when the notebook itself is
  pulled. ty, ruff and basedpyright don't send related reports.

- basedpyright reports no diagnostics in notebooks: with Neovim's default
  capabilities it uses pull diagnostics, and it answers pulls for notebook
  cells with nothing.
- ty's call and type hierarchies don't work in notebooks: its items for code
  in cells name the notebook instead of the cell.

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

## License

[MIT](LICENSE). The notebook cell reader is ported from
[jupytext](https://github.com/mwouts/jupytext) (MIT, © Marc Wouts); see
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
