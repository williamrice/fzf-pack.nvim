local M = {}

function M.run()
  local ok, err = pcall(require("fzf-pack.session").open, vim.deepcopy(require("fzf-pack").options))
  if not ok then
    local current = require("fzf-pack.session").current
    if current then
      current:close()
    end
    vim.notify("fzf-pack: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.register()
  vim.api.nvim_create_user_command("FzfPack", M.run, { desc = "Browse plugins and refresh update information" })
end

return M
