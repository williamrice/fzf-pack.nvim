local M = {}
M.options = { concurrency = 4, timeout = 30000, max_commits = 200, max_log_bytes = 65536, refresh_interval = 3600 }

function M.setup(opts)
  opts = opts or {}
  for key, value in pairs(opts) do
    assert(M.options[key] ~= nil, "Unknown fzf-pack option: " .. key)
    local minimum = key == "refresh_interval" and 0 or 1
    assert(
      type(value) == "number" and value >= minimum and value < math.huge and value % 1 == 0,
      key .. (minimum == 0 and " must be a non-negative integer" or " must be a positive integer")
    )
  end
  M.options = vim.tbl_extend("force", M.options, opts)
  require("fzf-pack.commands").register()
end

return M
