local M = {}

function M.run(fetch)
  if require("fzf-pack.check").running then
    vim.notify("fzf-pack: A check is already running", vim.log.levels.WARN)
    return
  end
  local ok, plugins = pcall(require("fzf-pack.pack").list)
  if not ok then
    vim.notify("fzf-pack: " .. plugins, vim.log.levels.ERROR)
    return
  end
  if #plugins == 0 then
    vim.notify("fzf-pack: No installed plugins")
    return
  end
  local opts = vim.deepcopy(require("fzf-pack").options)
  if fetch then
    vim.notify("fzf-pack: Checking " .. #plugins .. " plugins…")
  end
  require("fzf-pack.check").start(plugins, opts, fetch, function(rows)
    local success, err = pcall(require("fzf-pack.picker").open, rows, opts, fetch)
    if not success then
      vim.notify("fzf-pack: " .. err, vim.log.levels.ERROR)
    end
  end)
end

function M.register()
  vim.api.nvim_create_user_command("Pack", function()
    M.run(false)
  end, { desc = "Browse vim.pack plugins using local refs" })
  vim.api.nvim_create_user_command("PackUpdate", function()
    M.run(true)
  end, { desc = "Check vim.pack updates asynchronously and review" })
end

return M
