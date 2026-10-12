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
- [fzf-lua](https://github.com/ibhagwan/fzf-lua) and its required `fzf` executable.
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

1. Run `:PackUpdate` to check for updates.
2. Move through the list to preview each plugin’s changes. Type to filter results.
3. Press Tab to select plugins, then Enter to review them. Use Ctrl-A to review
   all available changes, including results hidden by your filter.
4. In the confirmation buffer, run `:w` to apply the changes or `:q` to cancel.
5. Restart Neovim to load the updated plugins.

Checking for updates does not change installed plugin versions or the lock file.
Updates use vim.pack’s confirmation flow and preserve its build hooks.

### Commands

| Command | Action |
| --- | --- |
| `:Pack` | Browse plugins using local information, without fetching |
| `:PackUpdate` | Fetch updates and open the review picker |
| `:PackCancel` | Stop an update check that is still running |

`:PackCancel` also cancels a running local check. To cancel an update that has
already reached the confirmation buffer, use `:q`.

### Picker keys

| Key | Action |
| --- | --- |
| Tab / Shift-Tab | Mark or unmark plugins |
| Enter | Review selected changes in `:PackUpdate` |
| Ctrl-A | Review all available changes in `:PackUpdate` |
| Ctrl-O | Open the focused plugin’s repository in your default browser |
| Esc | Close the picker without applying changes |

Ctrl-O works in both pickers and keeps your filter and selections intact.
It supports HTTP(S) sources and common SSH URLs for GitHub, GitLab, and Codeberg.
Local paths, URLs containing credentials, and custom Git/SSH aliases or SSH ports
show a notice instead.

### Reading the preview

The preview shows installed and target revisions, version constraints, and
incoming or removed commits. Pins, tags, branches, and version ranges are respected.

Current plugins appear in green and available updates in red, depending on your
colorscheme. A `cached` status in `:Pack` reflects local information; run
`:PackUpdate` to check the remote. If a check fails, its error appears in the
preview and you can still review other plugins.

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
