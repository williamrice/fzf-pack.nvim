local M = {}
local git = require("fzf-pack.git")

function M.read(path, head, target, opts)
  local range = head .. "..." .. target
  local function log(side)
    return git.exec(path, {
      "log",
      "--no-color",
      "--topo-order",
      side,
      "--max-count=" .. opts.max_commits,
      "--format=commit %h%n%s%n%b",
      range,
      "--",
    }, opts.timeout)
  end
  local incoming, removed = log("--right-only"), log("--left-only")
  local status = incoming == "" and "rollback" or (removed == "" and "update" or "diverged")
  return {
    "Incoming commits (up to " .. opts.max_commits .. "):",
    incoming == "" and "(none)" or incoming,
    "",
    "Removed commits (up to " .. opts.max_commits .. "):",
    removed == "" and "(none)" or removed,
  },
    status
end

return M
