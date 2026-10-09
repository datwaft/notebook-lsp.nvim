# notebook-lsp.nvim

Language servers for [jupytext](https://jupytext.readthedocs.io) Markdown
notebooks in Neovim, through the LSP notebook protocol (`notebookDocument/*`).

You edit the notebook as one Markdown buffer. Your language servers (ty, ruff,
basedpyright, ...) see a notebook whose cells are the code cells jupytext would
produce, so diagnostics, completion, hover, code actions, formatting, rename
and the rest work inside cells, and names are shared across them.

Unlike [otter.nvim](https://github.com/jmbuhr/otter.nvim), there are no hidden
buffers for servers to attach to, and no extra clients: the servers that serve
your `.py` files serve your notebooks too, through the protocol editors such
as VS Code use for Jupyter notebooks.

> [!NOTE]
> Early, and used by its author for now: it isn't announced yet, and may change
> without notice.

## Requirements

- Neovim nightly
- Language servers that support the LSP notebook protocol: the plugin knows
  [ty](https://github.com/astral-sh/ty), [ruff](https://github.com/astral-sh/ruff),
  [basedpyright](https://github.com/DetachHead/basedpyright) and
  [pyright](https://github.com/microsoft/pyright), configured for example by
  [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)

## Installation

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/datwaft/notebook-lsp.nvim" })
```

Or with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "datwaft/notebook-lsp.nvim", lazy = false }
```

Don't lazy-load it: it must extend the servers' configs before they attach.
Loading it only does that.

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

## Configuration

### Servers

`vim.g.notebook_lsp.servers` adds servers to the ones the plugin extends, by
their `vim.lsp.config` name, and leaves out the ones set to `false`:

```lua
vim.g.notebook_lsp = {
  servers = {
    my_pyright = { "python" }, -- the server's own filetypes
    pyright = false,
  },
}
```

The filetypes replace the config's own (see [Usage](#usage)), and are the
kernel languages of the notebooks the server attaches to. The server must
support the LSP notebook protocol: one that doesn't is detached from
notebooks without seeing them.

The plugin reads `vim.g.notebook_lsp` when it loads, so set it before then:
early in your config, or in the `init` function of a lazy.nvim spec. Assign it
as a whole: Neovim can't change a field of a table in `vim.g`
(`vim.g.notebook_lsp.servers = ...` does nothing). Unknown options and invalid
values are errors.

To extend a server later, call the function the plugin uses:

```lua
require("notebook_lsp").extend("my_pyright", { "python" })
```

It affects the notebooks that attach afterwards.

### Notebooks

To keep the servers away from a notebook, set `vim.b.notebook_lsp = false` in
it before its filetype is set, for example in `after/ftplugin/markdown.lua`:

```lua
if vim.api.nvim_buf_get_name(0):match("/private/") then
  vim.b.notebook_lsp = false
end
```

Neovim enables filetype plugins before it loads your config, so they run
before `vim.lsp.enable()` attaches servers. Setting it later doesn't detach
servers that are already attached.

### Disabling the plugin

`vim.g.loaded_notebook_lsp = true` before the plugin loads disables it.

## Known issues

See the [open issues](https://github.com/datwaft/notebook-lsp.nvim/issues).

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) to work on it, and
[ARCHITECTURE.md](ARCHITECTURE.md) for how it works.

## License

[MIT](LICENSE). The notebook cell reader is ported from
[jupytext](https://github.com/mwouts/jupytext) (MIT, © Marc Wouts); see
[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
