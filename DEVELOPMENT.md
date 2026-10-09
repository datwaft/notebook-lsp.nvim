# Development

## Tools

- Neovim nightly
- [lux](https://github.com/lumen-oss/lux) 0.47.0 (`lx`), which runs the tests
  with [busted](https://lunarmodules.github.io/busted/) inside Neovim, through
  [nlua](https://codeberg.org/mfussenegger/nlua)
- [uv](https://docs.astral.sh/uv/), for the oracle and end-to-end tests
- [StyLua](https://github.com/JohnnyMorganz/StyLua) 2.5.2
- [lua-language-server](https://github.com/LuaLS/lua-language-server) 3.19.1

## Checks

```sh
lx test < /dev/null                 # unit and protocol tests: fast, no external tools
lx test -- --run=e2e < /dev/null    # oracle and end-to-end tests: need uv
stylua --check lua plugin spec
VIMRUNTIME="$(nvim --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c q < /dev/null)" \
  lua-language-server --check . --checklevel=Hint
```

Give the tests an empty stdin when it isn't a terminal, as when a tool or an
agent runs them: after the tests, nlua runs its stdin as Lua, and one that's
never closed hangs the run once they're done.

| Directory | What it tests |
|---|---|
| `spec/unit` | Pure modules, such as the jupytext cell reader |
| `spec/protocol` | The plugin between Neovim's LSP client and an in-process fake server (`spec/helpers/fake_server.lua`) |
| `spec/oracle` | That the reader's fixtures match what jupytext itself produces |
| `spec/e2e` | Real servers in a separate Neovim process |

The oracle and end-to-end tests run pinned versions of jupytext and the
language servers through `uvx` (see `spec/helpers/tools.lua`), with uv's cache
in `.tests/`.

CI runs the tests on Linux and macOS for changes to the code and the specs,
and every day, since Neovim nightly changes every day. It checks formatting and
types for every change.

## Rules

- Never change a server's behaviour outside notebooks. The plugin sits on the
  same clients `.py` files use, so everything about other documents passes
  through as it is.
- Each cell behaves as a buffer of its own would. When in doubt, do what clean
  Neovim nightly does for a buffer: the same answers, the same edits, the same
  messages. Stale answers and edits get the same treatment as Neovim gives
  them, and the plugin only handles what's specific to notebooks.
- Fail loudly: no `pcall`, and an input the plugin can't handle correctly is an
  error rather than a guess.
- No `setup()`: the plugin works once loaded, and is configured through
  `vim.g.notebook_lsp` and `vim.b.notebook_lsp`.

## How it works

### Attaching

`plugin/notebook_lsp.lua` calls `extend()` (in `lua/notebook_lsp/init.lua`) for
each server it knows, which adds to the server's `vim.lsp.config`:

- `filetypes`: `markdown`, besides the server's own
- `root_dir`: lets through only jupytext notebooks in the server's language.
  Neovim calls it synchronously as the buffer gets its filetype, before it
  attaches the client. That's where the plugin gets the client, with
  `vim.lsp.start(config, { attach = false })`, and puts itself between it and
  its server, before Neovim sends anything about the notebook.
- `get_language_id`: a notebook's is its cells' language, which Neovim matches
  the document selectors of the server's dynamic registrations against
- `capabilities`: `notebookDocument.synchronization`

### Notebooks and cells

`notebook.lua` reads a notebook buffer's code cells, in the kernel's language,
with the jupytext reader (`jupytext.lua`). Each cell has an id, which is an
extmark on its opening fence: it stays with the cell as lines are added or
removed around it, and goes when the fence is deleted.

The server knows the notebook as `<Markdown file>.ipynb`, and each cell as
`vscode-notebook-cell:<Markdown file>.ipynb#c<id>`. Only the plugin
makes those URIs. A cell's text is its lines, each ending with a line break:
the last one is the line break before its closing fence.

### Between the client and its server

`intercept()` replaces three things on the client, once per client:

- `client.rpc`: Neovim's messages about notebook buffers become
  `notebookDocument/*` messages, and requests about them go to the cells they
  concern. `targets()` decides which cells, from a request's position, its
  positions, its range or ranges, or every cell. Each cell's request has the
  cell's lines. `merge()` combines the answers of several cells into one for
  the notebook.
- `client._notification`: diagnostics the server publishes for cells are
  shown on their notebook buffer, where the cells are now.
- `client._server_request`: edits the server asks Neovim to apply, and
  documents it asks Neovim to show, are translated to the notebook.

`translate.lua` translates the server's values for Neovim. Positions in cells
become positions in their notebook buffer, and cell URIs become the buffer's.
Several cells' edits become one edit of the buffer. A value about a cell
that's gone is left out, up to the list it's in. `data` fields and command
arguments are the server's, and are never touched.

Edits that reach the end of a cell must leave its closing fence on a line of
its own. To see what they leave, the plugin applies them with Neovim's own
`vim.lsp.util.apply_text_edits` to the cell's lines and a fence, in a scratch
buffer of its own: the same result Neovim gets when it applies them to the
notebook buffer. The same buffer turns a cell's successive edits into one
batch of edits.

### Items the server gets back

Some items in answers go back to the server later, such as an item to resolve,
a hierarchy item, or a code action request's diagnostics. The server must get
them back as it gave them, in their cell's lines:

- **Code actions, code lenses, inlay hints, document links, hierarchy items and
  diagnostics** record their cell and the server's original item in their
  `data`, as `{ notebook_lsp = <cell URI>, item = <original> }`. The plugin
  sends the server the original.
- **Completion items** record only their cell and the row the cell started at,
  in a field of their own (`notebook_lsp`), apart from their `data`.
  Completion engines fill items in with the list's defaults, each in its own
  way. To resolve an item, the plugin sends the item as the engine made it,
  moved back to the cell's lines.

A record counts only if it names a cell URI, since a server's own data may
have the same key.

## The Neovim it needs

Tested with `NVIM v0.13.0-dev-1804+gfb1f321b0e`. The plugin relies on parts of
Neovim's LSP client that aren't public, and on how it behaves. When nightly
breaks the plugin, look at these first:

- Neovim sends every request and notification of a client through
  `client.rpc.request` and `client.rpc.notify`, with a `notify_reply` callback
  for requests.
- The RPC dispatchers look `client._notification` and `client._server_request`
  up on the client for each message.
- `root_dir` is called synchronously when a buffer gets its filetype, and
  `textDocument/didOpen` is sent as the client attaches, before `LspAttach`.
- `get_language_id` is what the document selectors of dynamic registrations
  are matched against.
- `Client:request` sends pending changes before a request, except when called
  for buffer 0 (the plugin sends them itself).
- `apply_workspace_edit` checks only the first document change's version, and
  only when it's above 0. The plugin versions a notebook's edits with the
  buffer's changedtick.
- `apply_text_edits`: how Neovim applies edits, which the plugin relies on to
  see what they leave.

The specs also use `client.requests`, `vim.lsp.completion._lsp_to_complete_items`
and `vim.lsp.get_clients({ _uninitialized = true })`.

## Adding an LSP method

Most methods work with no changes, as the request's shape decides where it
goes, and the translation is generic. Check:

1. **Routing** (`targets()`): a request about a position goes to its cell, one
   about a range to the cells it overlaps, one about the document to every
   cell.
2. **Merging** (`merge()`): lists are concatenated. Anything else needs its own
   case, as selection ranges, semantic tokens and pulled diagnostics have.
3. **Translation**: positions and URIs are found by their shape. Fields with
   another shape need their own case in `translate.to_client`, as
   `targetUri`, `fromRanges` or a `DocumentLink`'s `target` have. Opaque
   fields stay untouched.
4. **Items that come back** (`RESOLVE`, `RESOLVABLE`, `HIERARCHY` in
   `init.lua`): how they record their cell, and what the server gets back.
5. **Gone cells**: what an answer about a cell deleted since means, as Neovim
   would handle it for a buffer.
6. **Specs**: a protocol spec with the fake server, and an end-to-end one if a
   real server supports the method.

## The jupytext reader

`jupytext.lua` is a port of the parts of jupytext that decide which lines are
code cells, and in which language: `header.py`, `cell_reader.py`
(`MarkdownCellReader`), `cell_metadata.py`, `stringparser.py` and
`languages.py`. It matches jupytext 1.19.6, which the oracle tests check its
fixtures against.

To follow a newer jupytext:

1. Compare those modules between the two versions.
2. Port the changes, and add fixtures for them.
3. Pin the new version in `spec/helpers/tools.lua`.
4. Run the oracle tests, which compare the fixtures with what the new
   jupytext produces.
5. Update the version, here and in `jupytext.lua`'s header.

## Code layout

| File | What it has |
|---|---|
| `plugin/notebook_lsp.lua` | The options, and the servers the plugin extends |
| `lua/notebook_lsp/init.lua` | Attaching, synchronization, routing, merging, and the client's hooks |
| `lua/notebook_lsp/translate.lua` | Translating the server's values for Neovim |
| `lua/notebook_lsp/notebook.lua` | A notebook buffer's cells and their ids |
| `lua/notebook_lsp/jupytext.lua` | The jupytext reader |

`init.lua` is the largest file. Its per-client closure keeps each client's
state in one place. If it grows much, routing (`targets()`) and merging
(`merge()`) are the parts to move out first. Synchronization and the client's
hooks share that state, and should stay together.

## Workflow

- Version control with [jj](https://jj-vcs.github.io/jj/), and
  [Conventional Commits](https://www.conventionalcommits.org).
- Tests first: a failing spec, then the change that makes it pass.
- One commit per fix, with its spec.
- Known issues are listed in the README.
