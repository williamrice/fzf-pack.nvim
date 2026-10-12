vim.opt.runtimepath:prepend(assert(vim.env.FZF_PACK_TEST_ROOT))
vim.opt.packpath:prepend(vim.fn.stdpath("data") .. "/site")
local pack = require("fzf-pack.pack")
local before = pack.lock_bytes()
for _ = 1, 2 do
  local plugins = pack.list()
  assert(#plugins == 9)
  for _, p in ipairs(plugins) do
    assert(not p.active)
  end
  local done
  require("fzf-pack.check").start(plugins, { concurrency = 2, timeout = 10000, max_commits = 20 }, false, function(rows)
    for _, row in ipairs(rows) do
      assert(not row.error, row.error)
    end
    done = true
  end)
  assert(vim.wait(20000, function()
    return done
  end))
  assert(pack.lock_bytes() == before)
end
vim.cmd.qa({ bang = true })
