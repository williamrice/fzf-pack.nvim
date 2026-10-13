# fzf-pack.nvim

[![CI](https://github.com/williamrice/fzf-pack.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/williamrice/fzf-pack.nvim/actions/workflows/ci.yml)

Browse installed plugins, preview changes, and choose what to update with
Neovim’s built-in `vim.pack` manager and [fzf-lua](https://github.com/ibhagwan/fzf-lua).

- Search your plugins and check for updates.
- Read commit messages before updating, with breaking changes highlighted in red.
- Update individual plugins or review all available changes.
- Open a plugin’s repository in your browser with Ctrl-O.

## Requirements

- Neovim 0.12+ (stable).
- [fzf-lua](https://github.com/ibhagwan/fzf-lua) and `fzf` 0.71 or newer.
- Git on your `PATH`.

## Installation

Add the plugin and fzf-lua to your Neovim configuration:

```lua
vim.pack.add({
  { src = 'https://github.com/ibhagwan/fzf-lua' },
  { src = 'https://github.com/williamrice/fzf-pack.nvim' },
})
```

No setup call is required. Register the plugins you want to manage with
`vim.pack.add()` before running the commands below.

If you install fzf-pack.nvim through another plugin manager, include fzf-lua as
a dependency. fzf-pack.nvim manages plugins registered with `vim.pack`.

## Updating plugins

Run `:FzfPack` to open the picker. It shows the last saved results immediately,
or `not checked` when no usable cache is available, then starts bounded
background checks. Checks fetch Git refs but never check out code or write the
lock file. Nothing refreshes at startup.

Press Ctrl-R to request a refresh; duplicate checks are ignored. Press Ctrl-X
to stop queued checks while active workers finish, or Esc to close the picker
and stop queued checks. Enter and Ctrl-A wait in the open picker while checks
are running. Once complete, select plugins with Tab, then press Enter to review
the selection or Ctrl-A to review all available updates, including filtered
rows. Stale results cannot be selected for update.

Marks stay selected when you filter or refresh. The header shows the selection
count, including marked plugins hidden by the current filter.

The confirmation buffer uses vim.pack’s native flow: `:w` applies updates and
`:q` cancels. Native build hooks are preserved. Restart Neovim to load updated
plugins.

### Commands

| Command | Action |
| --- | --- |
| `:FzfPack` | Open the plugin picker and check for updates in the background |

### Picker keys

| Key | Action |
| --- | --- |
| Tab / Shift-Tab | Mark or unmark plugins |
| Ctrl-R | Refresh; duplicate checks are ignored |
| Ctrl-X | Stop queued checks; active workers drain |
| Enter | Review selected changes, or wait while checks run |
| Ctrl-A | Review all available changes, or wait while checks run |
| Ctrl-O | Open the focused plugin’s repository in your default browser |
| Esc | Close the picker and stop queued checks |

Ctrl-O keeps your filter and selections intact.
It supports HTTP(S) sources and common SSH URLs for GitHub, GitLab, and Codeberg.
Local paths, URLs containing credentials, and custom Git/SSH aliases or SSH ports
show a notice instead.

### Reading the preview

The preview shows installed and target revisions, version constraints, the
check time, and incoming or removed commits. Pins, tags, branches, and version
ranges are respected. Cached results are display-only until a fresh check
completes; stale rows cannot be updated.

Current plugins appear in green and available updates in red, depending on your
colorscheme. If a check fails, its error appears in the preview while other
plugins continue checking.

Commits marked as breaking changes use bold red text and a `[BREAKING CHANGE]`
label. This recognizes the Conventional Commits `!` marker and breaking-change
footers. Large histories show a truncation notice; warnings only cover the
commit messages included in the preview.

## Configuration

Setup is optional. These are the defaults:

```lua
require('fzf-pack').setup({
  concurrency = 4,       -- plugins checked at the same time
  timeout = 30000,       -- timeout per Git command, in milliseconds
  max_commits = 200,     -- commits per incoming or removed history
  max_log_bytes = 65536, -- history size limit per side, in bytes
})
```

All options must be positive integers. The timeout applies to checks, not to
applying updates or running build hooks.

### Colors

Override these highlight groups to customize the picker:

| Highlight group | Used for |
| --- | --- |
| `FzfPackCurrent` | Up-to-date plugins |
| `FzfPackUpdate` | Available updates |
| `FzfPackRollback` | Rollbacks |
| `FzfPackDiverged` | Histories with both incoming and removed commits |
| `FzfPackError` | Failed checks |
| `FzfPackCommit` | Commit headers |
| `FzfPackBreakingChange` | Breaking-change warnings and explanations |

For example, set these after loading your colorscheme:

```lua
vim.api.nvim_set_hl(0, 'FzfPackCommit', { fg = '#66ccff', bold = true })
vim.api.nvim_set_hl(0, 'FzfPackBreakingChange', { fg = '#ff3030', bold = true })
```

Reopen the picker after changing colorschemes to refresh its colors.

## Notes

- The display-only cache is stored under `stdpath("state")`. Mismatched,
  corrupt, or oversized cache data is ignored; if the cache is unavailable,
  rows start as `not checked`.
- Nothing is fetched or synchronized automatically at startup.
- If you edit the lock file outside Neovim, restart Neovim before checking for
  updates. Resolve inconsistent plugin installations with `vim.pack` first.
- Avoid changing the lock file or running another plugin update while reviewing
  changes; vim.pack may overwrite external lock edits when you confirm.

See `:help fzf-pack` for more detail and [examples/minimal.lua](examples/minimal.lua)
for a minimal configuration. Report problems in [GitHub issues](https://github.com/williamrice/fzf-pack.nvim/issues).

## Contributing

See [AGENTS.md](AGENTS.md) for development guidelines and test commands.

## License

[MIT](LICENSE).
