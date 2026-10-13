-- Neovim 0.12.6; Git and fzf must already be available.
vim.pack.add({
  { src = "https://github.com/ibhagwan/fzf-lua" },
  { src = "https://github.com/williamrice/fzf-pack.nvim" },
})

require("fzf-pack").setup({ concurrency = 4, timeout = 30000, max_commits = 200 })
-- Run :FzfPack to browse immediately; use Ctrl-R to refresh the check.
