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

- **Supported:** Neovim 0.12.6.
- **Best effort:** Other stable Neovim versions 0.12 or newer, with a warning
  once per session. Prerelease/development builds, versions below 0.12, and
  versions missing `vim.pack.get`, `vim.pack.update`, or `vim.system` are rejected.
  Build metadata does not make a stable version a prerelease.
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
| `:PackCancel` | Cancel an active `:Pack` or `:PackUpdate` check |

The list shows plugin name, active/inactive state, and update status. Move
through the list to see full installed and target revisions, the configured
branch/tag/commit or semver constraint, and commit history. Details appear on
the right in wide windows and below the list in narrow windows.

Status text uses the `FzfPackCurrent`, `FzfPackUpdate`, `FzfPackRollback`,
`FzfPackDiverged`, and `FzfPackError` highlight groups. Current defaults to
green and update to red; rollback/diverged use the warning color and errors use
red. These groups link to Neovim's diagnostic highlights, so themes control
their colors. Reopen the picker after changing colorschemes to refresh colors.
Override a status highlight with `vim.api.nvim_set_hl(0, "FzfPackUpdate", { fg = "#ff0000" })`.

`:PackUpdate` reports completed and total plugin checks. `:PackCancel` stops
queued work, signals active Git processes, and prevents canceled results from
opening the picker. It does not cancel native confirmation or update handoff
validation.

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
  max_log_bytes = 65536, -- history output byte limit per side and plugin
})
```

All options are positive integers. The timeout covers checking, not native
acceptance or build hooks. Git credential prompts are disabled during checks;
normal credential helpers still apply. History bodies are streamed into a
bounded capture; each incoming and removed side is limited independently.
Section labels and truncation notices are outside the byte limit. History is
collected during checks; each row's formatted preview is cached on first display.

See `:help fzf-pack` and [examples/minimal.lua](examples/minimal.lua).

## Known limitations

- Restart Neovim after changing the lock file externally. Before checks and
  review, fzf-pack compares disk revisions with vim.pack's cached revisions and
  refuses mismatches without repairing the lock. The public API does not expose
  all cached metadata for active plugins, so source/version-only cache changes
  cannot always be detected.
- A disk/lock inconsistency or changed plugin source must be reconciled with
  vim.pack before opening the picker.
- Changes made after the native confirmation opens cannot be checked again
  before vim.pack writes the lock, so external lock edits during that window
  may be overwritten by the native write.
- `:PackCancel` signals the direct Git process with SIGTERM. A transport child
  may keep inherited pipes open after Git exits; its late result is ignored,
  and a new check can start while those pipes drain. Cancellation does not
  guarantee termination of the whole transport process tree.
- Concurrent external Git operations are not locked out.

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
macOS with supported Neovim 0.12.6. Formatting uses StyLua 2.6.0.

The real-PTY CI matrix is configured to exercise fzf-lua's current upstream snapshot
(`48d7c3db291a2c7c1825905c227a6bc81c83b837`) and the older `0.7` compatibility
snapshot (`47b85a25c0c0b2c20b4e75199ed01bb71e7814f5`). fzf-lua has no GitHub
releases, so CI pins both refs to exact commits. The older snapshot is extra
compatibility coverage, not a recommendation or a change to the Neovim support
contract above.

When maintaining this matrix, recheck upstream refs, update the `current` pin
from upstream `main`, and retain the compatibility snapshot. Change pins only
after the real PTY suite passes on both Linux and macOS. Picker diagnostic
artifacts include the OS and fzf-lua matrix label.

See [AGENTS.md](AGENTS.md) for module boundaries and development requirements.
Tags matching `v*` run CI before publishing a GitHub release.

## License

[MIT](LICENSE).
