-- Parse every maintained Lua file and regenerate the published help tags.
for _, pattern in ipairs({ "lua/**/*.lua", "plugin/*.lua", "tests/*.lua", "examples/*.lua" }) do
  for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
    assert(loadfile(path))
  end
end
vim.cmd.helptags("doc")
print("PASS: Lua syntax and help tags")
vim.cmd.qa({ bang = true })
