# fzf-pack.nvim

[![CI](https://github.com/williamrice/fzf-pack.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/williamrice/fzf-pack.nvim/actions/workflows/ci.yml)

Browse and review updates for Neovim's built-in `vim.pack` manager through
[fzf-lua](https://github.com/ibhagwan/fzf-lua).

- A compact plugin list with details that follow the selection.
- Asynchronous update checks with bounded concurrency and per-plugin errors.
- Commit subjects and bodies for incoming, rolled-back, and diverged changes.
- Multi-selection and a shortcut to review every available update.
- Native vim.pack confirmation and build-hook events.

## Requirements

- Neovim 0.12+, tested against **0.12.6**.
- fzf-lua and its required fzf executable.
- Git available on your PATH.

This is an MVP. See [known limitations](#known-limitations) before use.

## Installation

With `vim.pack`, add these specifications to your existing configuration:

```lua
vim.pack.add({
  { src = 'https://github.com/ibhagwan/fzf-lua' },
  { src = 'https://github.com/williamrice/fzf-pack.nvim' },
})
```

For another plugin manager, use `williamrice/fzf-pack.nvim` and declare
`ibhagwan/fzf-lua` as a dependency. Setup is optional; commands load automatically.
Your `vim.pack.add()` calls must run before using the commands.

## Usage

| Command | Behavior |
| --- | --- |
| `:Pack` | List installed plugins using local refs, without fetching |
| `:PackUpdate` | Fetch updates asynchronously, then open the review picker |

The list shows plugin name, active/inactive state, and update status. Move
through the list to see full installed and target revisions, the configured
branch/tag/commit or semver constraint, and commit history. Details appear on
the right in wide windows and below the list in narrow windows.

In the update picker:

| Key | Action |
| --- | --- |
| Tab / Shift-Tab | Select multiple plugins |
| Enter | Review selected available changes |
| Ctrl-A | Review all available changes, including filtered-out results |
| Esc | Close without applying changes |

Selected changes open **vim.pack's native confirmation buffer**. Run `:write`
to accept or `:quit` to cancel. Restart Neovim after updating to use the new code.
Existing `PackChangedPre` and `PackChanged` build hooks continue to run.

Checks download Git objects and refs, but do not checkout plugin code or write
the lock file. Failed fetches remain visible while successful results can still
be reviewed. A `cached` status in `:Pack` means local refs match; it does not
indicate that the remote was checked.

## Configuration

```lua
require('fzf-pack').setup({
  concurrency = 4,   -- maximum simultaneous plugin checks
  timeout = 30000,   -- milliseconds per checking Git process
  max_commits = 200, -- preview limit on each side of history
})
```

All options are positive integers. The timeout covers checking, not native
acceptance or build hooks. Git credential prompts are disabled during checks;
normal credential helpers still apply.

See `:help fzf-pack` and [examples/minimal.lua](examples/minimal.lua).

## Known limitations

- Restart Neovim after changing the lock file externally. vim.pack caches lock
  data, and accepting an update in the old session can overwrite external changes.
- Git `insteadOf` URL aliases are currently rejected by update checks.
- A disk/lock inconsistency or changed plugin source must be reconciled with
  vim.pack before opening the picker.
- Concurrent external Git operations are not locked out. Read the native
  confirmation as the final description of the changes being applied.

These are tracked in [GitHub issues](https://github.com/williamrice/fzf-pack.nvim/issues).
`PackSync`, optional startup synchronization, and `PackClean` are planned.
There is currently no startup synchronization or fetching.

## Development

```sh
stylua --check lua plugin tests/*.lua examples
sh tests/run.sh
nvim --headless -u NONE -i NONE -l tests/check.lua
FZF_LUA_PATH=/path/to/fzf-lua python3 tests/ui.py
```

Integration tests use temporary local repositories and isolated Neovim/Git
configuration. The PTY test needs Python 3 and an existing fzf-lua checkout;
it exercises the real picker and native cancellation. CI runs on Linux and
macOS with Neovim 0.12.6. Formatting uses StyLua 2.6.0.

See [AGENTS.md](AGENTS.md) for module boundaries and development requirements.
Tags matching `v*` run CI before publishing a GitHub release.

## License

[MIT](LICENSE).
