# Development guide

fzf-pack.nvim is an fzf-lua interface for the built-in vim.pack manager.
Keep the plugin standalone and keep plugin installation/configuration under
the user's control. The supported reference runtime is Neovim 0.12.6.

## Module responsibilities

- `pack.lua`: public vim.pack integration, lock preflight, native confirmation.
- `compat.lua`: capability checks and any version-specific compatibility handling.
- `git.lua`: asynchronous process execution and Git environment handling.
- `check.lua`: bounded checks, target resolution, stale-result validation.
- `live.lua` / `session.lua`: live picker refresh lifecycle and check sessions.
- `cache.lua`: bounded display-only result persistence.
- `changelog.lua`: incoming and removed commit history.
- `picker.lua`: fzf-lua rows, previews, and selection actions.
- `commands.lua` / `init.lua`: commands and validated configuration.

Prefer public APIs. Read the documentation and source bundled with the exact
tested Neovim version; online documentation may describe a different version.
The read-only resolver mirrors a small portion of vim.pack because no public
target-resolution API exists. Test any change against native resolution.

## Behavioral requirements

- `:FzfPack` is the sole command replacing `:Pack`, `:PackUpdate`, and
  `:PackCancel`; do not add aliases. Open cached or `not checked` rows immediately. Start bounded background checks
  after opening only when any result is missing or expired (refresh_interval
  seconds, default 3600; zero always checks). Ctrl-R bypasses the interval.
- Checks may fetch Git refs, but must never checkout code or write locks. Cache
  data never bypasses local HEAD, target, specification and lock validation;
  expired rows require refresh before review.
- Ctrl-R ignores duplicate refreshes. Ctrl-X stops queued checks while active
  workers drain. Esc closes the picker and stops queued checks.
- Keep Enter and Ctrl-A in the open picker with a wait message while checks run.
- Selected updates go through native vim.pack confirmation: write accepts,
  quit cancels. Preserve native PackChangedPre/PackChanged build events.
- Respect pins, tags, remote branches, and vim.version ranges.
- Keep fetch concurrency bounded, isolate failures, and reject duplicate work.
- Preview both incoming and removed commits, including bodies.
- Use fzf-lua, with hidden stable row identifiers and explicit custom previewer
  constructors. Do not treat plugin rows as file paths.
- Never rewrite user configuration, generate setup code, or install tools at runtime.
- Persist display cache under `stdpath("state")`; treat missing, mismatched,
  corrupt, or oversized data as a cache miss. Keep startup refresh disabled.

## Validation

```sh
stylua --check lua plugin tests/*.lua examples
sh tests/run.sh
nvim --headless -u NONE -i NONE -l tests/check.lua
FZF_LUA_PATH=/path/to/fzf-lua python3 tests/ui.py
```

Git fixtures must stay inside temporary directories. Test environments isolate
XDG directories and Git configuration. Test a behavioral regression before
fixing it; avoid tests that only repeat implementation details.

Picker changes require the real PTY test. A mocked previewer test does not
establish compatibility with fzf-lua. Report blocked/unexecuted validation
accurately. CI pins Neovim, fzf-lua, formatter versions, and third-party actions.

Regenerate `doc/tags` with `:helptags doc` when changing help tags. Keep README
examples installable, and keep README/help behavior consistent.

## Review and release

Track outstanding correctness and engineering findings in GitHub issues.
Remaining update-path limitations include external-lock-cache metadata that the
public API does not expose for active plugins and lock edits during native
confirmation. Read the open issues before changing the update path.

Do not add machine-specific paths, credentials, logs, local state, or copied
personal configuration. Use repository-local settings only. Commit, push,
publish, and create releases only when the user requests them. Tagged releases
must pass the reusable CI workflow before publication.
