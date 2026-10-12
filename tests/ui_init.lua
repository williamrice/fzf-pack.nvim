vim.opt.runtimepath:prepend(assert(vim.env.FZF_PACK_TEST_ROOT))
vim.opt.runtimepath:prepend(assert(vim.env.FZF_LUA_PATH))
vim.opt.packpath:prepend(vim.fn.stdpath("data") .. "/site")
vim.opt.swapfile = false
local path = assert(vim.env.FZF_PACK_TEST_TMP) .. "/upstream"
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
git("commit", "-qm", "UI incoming subject", "-m", "UI incoming body")
vim.g.ui_lock_before = require("fzf-pack.pack").lock_bytes()
require("fzf-pack").setup()
vim.g.ui_ready = true
local timer = vim.uv.new_timer()
timer:start(
  100,
  100,
  vim.schedule_wrap(function()
    local screen = {}
    for r = 1, vim.o.lines do
      local line = {}
      for c = 1, vim.o.columns do
        line[#line + 1] = vim.fn.screenstring(r, c)
      end
      screen[#screen + 1] = table.concat(line)
    end
    local state = {
      ready = true,
      buftype = vim.bo.buftype,
      filetype = vim.bo.filetype,
      screen = screen,
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
