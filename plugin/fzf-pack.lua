if vim.g.loaded_fzf_pack then
  return
end
vim.g.loaded_fzf_pack = true
require("fzf-pack.commands").register()
