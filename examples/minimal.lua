-- Neovim 0.12.6; Git and fzf must already be available.
vim.pack.add({
  { src = "https://github.com/ibhagwan/fzf-lua" },
  { src = "https://github.com/williamrice/fzf-pack.nvim" },
})

require("fzf-pack").setup({ concurrency = 4, timeout = 30000, max_commits = 200 })
-- :Pack for local information; :PackUpdate to fetch and review updates.
