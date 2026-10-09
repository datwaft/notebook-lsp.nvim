# Development

How to work on notebook-lsp.nvim. For how it works, see
[ARCHITECTURE.md](ARCHITECTURE.md).

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

CI runs the tests on Linux for changes to the code and the specs, and every
day, since Neovim nightly changes every day. It checks formatting and types for
every change. The plugin has no system-specific code; run the tests locally on
other systems.

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

## Workflow

- Version control with [jj](https://jj-vcs.github.io/jj/), and
  [Conventional Commits](https://www.conventionalcommits.org).
- Tests first: a failing spec, then the change that makes it pass.
- One commit per fix, with its spec.
- Known issues are GitHub issues, written with the issue template, in plain
  language (ISO 24495-1).
