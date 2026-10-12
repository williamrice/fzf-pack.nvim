local M = {}

function M.ensure()
  if
    vim.fn.has("nvim-0.12") ~= 1
    or not vim.pack
    or type(vim.pack.get) ~= "function"
    or type(vim.pack.update) ~= "function"
    or not vim.system
  then
    error("fzf-pack requires Neovim 0.12+ with vim.pack.get/update and vim.system")
  end
end

return M
