-- Parse every maintained Lua file and regenerate the published help tags.
for _, pattern in ipairs({ "lua/**/*.lua", "plugin/*.lua", "tests/*.lua", "examples/*.lua" }) do
  for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
    assert(loadfile(path))
  end
end
vim.cmd.helptags("doc")

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local compat = require("fzf-pack.compat")
assert(compat.ensure() == "supported", "CI and syntax checks must run on supported Neovim 0.12.6")
local api = {
  pack = { get = function() end, update = function() end },
  system = function() end,
}
local function version(major, minor, patch, extra)
  return vim.tbl_extend("force", { major = major, minor = minor, patch = patch }, extra or {})
end
assert(compat.classify(version(0, 12, 6, { build = "custom" }), api) == "supported")
assert(compat.classify(version(0, 12, 0), api) == "best-effort")
assert(compat.classify(version(0, 13, 0), api) == "best-effort")
local state, reason = compat.classify(version(0, 11, 9), api)
assert(state == nil and reason:find("0.12", 1, true))
state, reason = compat.classify(version(0, 12, 6, { prerelease = "dev" }), api)
assert(state == nil and reason:find("prerelease", 1, true))
state, reason = compat.classify(version(0, 12, 6), { pack = { get = function() end }, system = function() end })
assert(state == nil and reason:find("vim.pack.update", 1, true))
state, reason = compat.classify(version(0, 12, 6), { pack = { update = function() end }, system = function() end })
assert(state == nil and reason:find("vim.pack.get", 1, true))
state, reason = compat.classify(version(0, 12, 6), { pack = { get = function() end, update = function() end } })
assert(state == nil and reason:find("vim.system", 1, true))

-- Best-effort runtimes warn once; build metadata alone remains stable.
local real_version, real_notify = vim.version, vim.notify
local warnings = 0
local warning_message
vim.version = function()
  return version(0, 13, 0, { build = "custom" })
end
vim.notify = function(message, level)
  assert(level == vim.log.levels.WARN)
  warnings = warnings + 1
  warning_message = message
end
compat.ensure()
compat.ensure()
assert(warnings == 1 and warning_message:find("0.13.0+custom", 1, true))
vim.version, vim.notify = real_version, real_notify

local real_pack = vim.pack
vim.pack = { get = function() end }
local ok, err = pcall(compat.ensure)
vim.pack = real_pack
assert(not ok and tostring(err):find("vim.pack.update", 1, true))
print("PASS: Lua syntax, help tags, and compatibility policy")
vim.cmd.qa({ bang = true })
