local M = {}

local supported = { major = 0, minor = 12, patch = 6 }
local warned_best_effort = false

local function version_string(version)
  local text = ("%d.%d.%d"):format(version.major, version.minor, version.patch)
  if version.prerelease then
    text = text .. "-" .. version.prerelease
  end
  if version.build then
    text = text .. "+" .. version.build
  end
  return text
end

function M.classify(version, api)
  if
    type(version) ~= "table"
    or type(version.major) ~= "number"
    or type(version.minor) ~= "number"
    or type(version.patch) ~= "number"
  then
    return nil, "could not identify the Neovim version"
  end
  if version.prerelease and version.prerelease ~= "" then
    return nil, "fzf-pack does not support Neovim prerelease or development builds"
  end
  if version.major < 0 or (version.major == 0 and version.minor < 12) then
    return nil, "fzf-pack requires stable Neovim 0.12 or newer"
  end
  if
    type(api) ~= "table"
    or type(api.pack) ~= "table"
    or type(api.pack.get) ~= "function"
    or type(api.pack.update) ~= "function"
    or type(api.system) ~= "function"
  then
    return nil, "fzf-pack requires vim.pack.get, vim.pack.update, and vim.system"
  end
  if version.major == supported.major and version.minor == supported.minor and version.patch == supported.patch then
    return "supported"
  end
  return "best-effort"
end

function M.ensure()
  local ok, version = pcall(function()
    return vim.version()
  end)
  local status, err = M.classify(ok and version or nil, vim)
  if not status then
    error(err, 2)
  end
  if status == "best-effort" and not warned_best_effort then
    vim.notify(
      ("fzf-pack: Neovim %s is best effort; only 0.12.6 is supported and tested"):format(version_string(version)),
      vim.log.levels.WARN
    )
    warned_best_effort = true
  end
  return status
end

-- Keep the 0.12.6 vim.pack lock location behind the compatibility boundary.
function M.lock_path()
  return vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")
end

function M.plugin_dir()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "site", "pack", "core", "opt")
end

-- In Neovim 0.12.6, vim.pack.get().rev is the cached lock revision, not HEAD.
function M.cached_revision(plugin)
  return plugin.rev
end

-- fzf-lua renamed its callback-to-shell helper after the 0.7 snapshot.
function M.callback_command(fn, fields)
  local shell = require("fzf-lua.shell")
  if shell.stringify_data then
    return shell.stringify_data(fn, {}, fields)
  end
  return shell.raw_action(function(...)
    return fn(...) or {}
  end, fields)
end

return M
