vim.opt.runtimepath:prepend(assert(vim.env.FZF_PACK_TEST_ROOT))
vim.opt.runtimepath:prepend(assert(vim.env.FZF_LUA_PATH))
vim.opt.packpath:prepend(vim.fn.stdpath("data") .. "/site")
vim.opt.swapfile = false
vim.opt.termguicolors = true
vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = "#11aa22" })
vim.api.nvim_set_hl(0, "DiagnosticError", { fg = "#dd2233" })
vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = "#eeaa00" })
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
  vim.split("UI incoming subject\n\nUI incoming body\n" .. string.rep("UI payload界\n", 80), "\n"),
  message_path
)
git("commit", "-q", "-F", message_path)
vim.g.ui_lock_before = require("fzf-pack.pack").lock_bytes()
require("fzf-pack").setup({ max_log_bytes = 128 })
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
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
      unchanged = require("fzf-pack.pack").lock_bytes() == vim.g.ui_lock_before,
      confirmed = require("fzf-pack.pack").confirm_open(),
      old = vim.g.ui_old,
    }
    local state_path = vim.env.FZF_PACK_TEST_TMP .. "/ui-state.json"
    vim.fn.writefile({ vim.json.encode(state) }, state_path .. ".tmp")
    vim.uv.fs_rename(state_path .. ".tmp", state_path)
  end)
)
