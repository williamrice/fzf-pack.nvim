local M = {}
local compat = require("fzf-pack.compat")

function M.lock_bytes()
  local path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local bytes = file:read("*a")
  file:close()
  return bytes
end

function M.confirm_open()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "nvim-pack" and vim.bo[buf].buftype == "acwrite" then
      return true
    end
  end
  return false
end

-- The first public vim.pack call can install/repair the lock. Refuse that
-- situation instead of allowing a read-only picker to cause installations.
function M.list()
  compat.ensure()
  local bytes = M.lock_bytes()
  local lock = bytes and vim.json.decode(bytes) or { plugins = {} }
  assert(type(lock.plugins) == "table", "Invalid vim.pack lock file; initialize vim.pack first")
  local dir = vim.fs.joinpath(vim.fn.stdpath("data"), "site", "pack", "core", "opt")
  local installed = {}
  if vim.uv.fs_stat(dir) then
    for name, kind in vim.fs.dir(dir) do
      assert(
        kind == "directory" and lock.plugins[name],
        "vim.pack needs lock repair; initialize vim.pack before opening fzf-pack"
      )
      installed[name] = true
    end
  end
  for name, data in pairs(lock.plugins) do
    assert(
      installed[name] and type(data) == "table" and type(data.rev) == "string" and type(data.src) == "string",
      "vim.pack needs installation/lock repair; initialize vim.pack before opening fzf-pack"
    )
  end
  local plugins = vim.pack.get(nil, { info = false })
  local cached = {}
  for _, p in ipairs(plugins) do
    local name = p.spec.name
    local data = lock.plugins[name]
    assert(data, "vim.pack needs installation/lock repair; initialize vim.pack before opening fzf-pack")
    assert(
      p.rev == data.rev,
      "vim.pack's cached lock revisions differ from the lock file; restart Neovim before using fzf-pack"
    )
    cached[name] = true
    p.locked_src = data.src
    p.lock_bytes = bytes
  end
  for name in pairs(lock.plugins) do
    assert(cached[name], "vim.pack needs installation/lock repair; initialize vim.pack before opening fzf-pack")
  end
  return plugins
end

function M.review(rows)
  assert(not M.confirm_open(), "Close the existing vim.pack confirmation before reviewing updates")
  local current = {}
  for _, p in ipairs(M.list()) do
    current[p.spec.name] = p
  end
  local names = {}
  for _, row in ipairs(rows) do
    if row.target and row.head ~= row.target and not row.error then
      assert(
        row.plugin.spec.src == row.plugin.locked_src,
        "Source changed; use vim.pack directly to reconcile it first"
      )
      assert(row.plugin.lock_bytes == M.lock_bytes(), "Lock file changed since checking; run :PackUpdate again")
      local fresh = current[row.plugin.spec.name]
      assert(
        fresh
          and fresh.spec.src == row.plugin.spec.src
          and tostring(fresh.spec.version) == tostring(row.plugin.spec.version),
        "Plugin specification changed since checking; run :PackUpdate again"
      )
      names[#names + 1] = row.plugin.spec.name
    end
  end
  if #names == 0 then
    vim.notify("fzf-pack: No available updates selected", vim.log.levels.INFO)
    return
  end
  -- Native confirmation owns checkout, lock writing, stashing, help tags,
  -- submodules and PackChangedPre/PackChanged build hooks.
  vim.pack.update(names, { offline = true, force = false, target = "version" })
end

return M
