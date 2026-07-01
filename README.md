# git-monitor.nvim

A floating **multi-repo git panel** for Neovim — monitor *and* control a parent
repo plus every nested git sub-repo (the polyrepo layout) from one place.

```
 Repo                    |  Branch  |  Local  |  Upstream
-----------------------------------------------------------
 root *                  |  main    |  1      |  0
 core                    |  main    |  0      |  2
 adapter-http (fetch)    |  dev     |  0      |  0
 backoffice              |  main    |  0      |  0
 p:pull  P:push  \p:pull-all  \P:push-all   r:fetch  q:close
```

- **Local** = commits ahead (unpushed) · **Upstream** = commits behind (unpulled)
- `*` after a repo name = uncommitted local changes
- `(fetch)`/`(pull)`/`(push)` = an operation is running on that repo

Unlike gitsigns / fugitive / neogit (single-repo tools), this gives a
**parent + nested-repos** overview and lets you fetch / pull / push each repo —
or all of them — without leaving the panel.

## Features

- Opens **instantly** with `...` placeholders, then fills each row
  asynchronously (`vim.system`) — never blocks, even with dozens of repos.
- One `git status --porcelain=v2 --branch` per repo → branch + ahead/behind +
  dirty in a single call.
- **Actions in the panel**: `r` fetch all, `p`/`P` pull/push the repo under the
  cursor (push confirms), `\p`/`\P` pull/push all (each confirms).
  `pull` = stash-if-dirty → pull → stash pop.
- Clear **cursorline highlight**; the cursor is clamped to repo rows so `j`/`k`
  moves repo-to-repo.
- git runs list-form / direct (no shell) — works even when `'shell'` is
  PowerShell. Network ops set `GIT_TERMINAL_PROMPT=0` so a missing credential
  fails fast instead of hanging.
- Zero hard dependencies. Works on Neovim **0.10+** (`vim.system`).

## Install

**lazy.nvim**

```lua
{
  "mudiadamz/git-monitor.nvim",
  keys = { { "<leader>gm", function() require("gitmonitor").open() end, desc = "Git monitor" } },
  opts = {},   -- calls require("gitmonitor").setup({})
}
```

**packer.nvim**

```lua
use({ "mudiadamz/git-monitor.nvim", config = function() require("gitmonitor").setup({}) end })
```

**Native packages** — clone into `pack/*/start`, then `:GitMonitor` just works
(call `setup{}` only if you want a keymap / custom root / colour).

## Usage

- `:GitMonitor` — open the panel (rooted at the cwd by default).
- Panel keys:

  | key | action |
  |-----|--------|
  | `r` | `git fetch` **all** repos, then refresh counts |
  | `p` | pull the repo under the cursor (stash → pull → stash pop) |
  | `P` | push the repo under the cursor (**confirms** first) |
  | `<leader>p` / `<leader>P` | pull / push **all** repos (each confirms) |
  | `j` / `k` | move between repos (highlighted) |
  | `q` / `<Esc>` | close |

## Configuration

```lua
require("gitmonitor").setup({
  keymap = "<leader>gm",                     -- nil = no keymap (default)
  highlight = { bg = "#2f5b8c", bold = true }, -- selected-row highlight
  root = nil,                                -- function(): string dir; nil = default
})
```

**`root`** decides which directory to scan (its immediate git sub-dirs, plus
itself if it's a repo). The default uses an **open NERDTree window's root** if
present, otherwise Neovim's cwd. To always use the cwd, or wire your own logic:

```lua
require("gitmonitor").setup({
  root = function() return vim.fn.getcwd() end,
})
```

## Tests

```bash
bash tests/run.sh            # or:  powershell -File tests\run.ps1
nvim --headless -u tests/minimal_init.lua -c "luafile tests/gitmonitor_spec.lua"
```

The suite is self-contained (creates temp git fixtures incl. a bare remote) and
covers rendering, async open, the cursor highlight/clamp, the push confirm, and
live fetch / pull / push. Exit code 0 = all pass.

## License

MIT
