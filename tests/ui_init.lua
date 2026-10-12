vim.opt.runtimepath:prepend(assert(vim.env.FZF_PACK_TEST_ROOT))
vim.opt.runtimepath:prepend(assert(vim.env.FZF_LUA_PATH))
vim.opt.packpath:prepend(vim.fn.stdpath("data") .. "/site")
vim.opt.swapfile = false
vim.opt.termguicolors = true
vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = "#11aa22" })
vim.api.nvim_set_hl(0, "DiagnosticError", { fg = "#dd2233" })
vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = "#eeaa00" })
vim.api.nvim_set_hl(0, "Identifier", { fg = "#2468ac", ctermfg = 25 })
local test_tmp = assert(vim.env.FZF_PACK_TEST_TMP)
local path = test_tmp .. "/upstream"
local source = "file://" .. path
vim.fn.mkdir(path, "p")
local function git(...)
  local args = { "git", "-C", path }
  vim.list_extend(args, { ... })
  local out = vim.system(args, { text = true }):wait()
  assert(out.code == 0, out.stderr)
  return out.stdout:gsub("\n+$", "")
end
git("init", "-q", "-b", "main")
git("config", "user.name", "UI fixture")
git("config", "user.email", "fixture@example.invalid")
vim.fn.writefile({ "initial" }, path .. "/content")
git("add", ".")
git("commit", "-qm", "initial")
vim.g.ui_old = git("rev-parse", "HEAD")
vim.pack.add({
  { src = source, name = "alpha", version = "main" },
  { src = source, name = "beta", version = "main" },
  { src = source, name = "pinned", version = vim.g.ui_old },
}, { confirm = false, load = false })
vim.fn.writefile({ "new" }, path .. "/content")
git("add", ".")
local message_path = test_tmp .. "/commit-message"
vim.fn.writefile(
  vim.list_extend(
    { "chore(ui): UI normal subject", "", "UI normal body" },
    vim.split(string.rep("UI payload界\n", 80), "\n")
  ),
  message_path
)
git("commit", "-q", "-F", message_path)
vim.fn.writefile({ "new breaking" }, path .. "/content")
git("add", ".")
vim.fn.writefile({
  "feat(ui)!: UI incoming subject",
  "",
  "UI incoming body",
  "",
  "BREAKING CHANGE: UI API changes",
  "  Migrate callers",
}, message_path)
git("commit", "-q", "-F", message_path)
vim.g.ui_new = git("rev-parse", "HEAD")
vim.g.ui_lock_before = require("fzf-pack.pack").lock_bytes()
require("fzf-pack").setup({ max_log_bytes = 300 })
-- Give only the browser action synthetic web sources. Update review must keep
-- using the original local Git sources and snapshots.
local browser_calls = {}
local browser_notices = {}
local original_notify = vim.notify
vim.notify = function(message, level, options)
  if message:find("fzf-pack: Could not open repository:", 1, true) then
    browser_notices[#browser_notices + 1] = message
    return
  end
  return original_notify(message, level, options)
end
vim.ui.open = function(url)
  browser_calls[#browser_calls + 1] = url
  if vim.fn.filereadable(test_tmp .. "/browser-fails") == 1 then
    return nil, "fixture has no browser opener"
  end
  return {}
end
local check = require("fzf-pack.check")
local original_review = check.review
check.review = function(chosen, ...)
  for _, row in ipairs(chosen) do
    row.plugin.spec.src = source
  end
  return original_review(chosen, ...)
end
local picker = require("fzf-pack.picker")
local open_picker = picker.open
picker.open = function(rows, options, checked)
  local browser_rows = vim.deepcopy(rows)
  for _, row in ipairs(browser_rows) do
    row.plugin.spec.src = "https://github.com/fixture/" .. row.plugin.spec.name .. ".git"
  end
  return open_picker(browser_rows, options, checked)
end
vim.g.ui_ready = true
local timer = vim.uv.new_timer()
local stopped = false
local function stop_observer()
  if stopped then
    return
  end
  stopped = true
  timer:stop()
  timer:close()
  vim.fn.writefile({}, test_tmp .. "/observer-stopped")
end
vim.api.nvim_create_autocmd("VimLeavePre", { callback = stop_observer })
timer:start(
  100,
  100,
  vim.schedule_wrap(function()
    -- Closing a timer does not cancel callbacks already queued by schedule_wrap.
    if stopped then
      return
    end
    if vim.fn.filereadable(test_tmp .. "/stop-observer") == 1 then
      stop_observer()
      -- Quit from the editor callback: injected :qa! keys depend on UI mode.
      vim.cmd("qa!")
      -- fzf-lua's ExitPre closes its floating windows and can abort that quit.
      -- Finish exiting after its window-close callbacks have run.
      vim.schedule(function()
        vim.cmd("qa!")
      end)
      return
    end
    local screen = {}
    local attributes = {}
    for r = 1, vim.o.lines do
      local line = {}
      local row_attributes = {}
      for c = 1, vim.o.columns do
        line[#line + 1] = vim.fn.screenstring(r, c)
        row_attributes[#row_attributes + 1] = vim.fn.screenattr(r, c)
      end
      screen[#screen + 1] = table.concat(line)
      attributes[#attributes + 1] = row_attributes
    end
    local state = {
      ready = true,
      buftype = vim.bo.buftype,
      filetype = vim.bo.filetype,
      screen = screen,
      attributes = attributes,
      browser_calls = browser_calls,
      browser_notices = browser_notices,
      commit_highlight = vim.api.nvim_get_hl(0, { name = "FzfPackCommit" }),
      breaking_highlight = vim.api.nvim_get_hl(0, { name = "FzfPackBreakingChange" }),
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
      unchanged = require("fzf-pack.pack").lock_bytes() == vim.g.ui_lock_before,
      confirmed = require("fzf-pack.pack").confirm_open(),
      old = vim.g.ui_old,
      new = vim.g.ui_new,
    }
    local state_path = vim.env.FZF_PACK_TEST_TMP .. "/ui-state.json"
    vim.fn.writefile({ vim.json.encode(state) }, state_path .. ".tmp")
    vim.uv.fs_rename(state_path .. ".tmp", state_path)
  end)
)
