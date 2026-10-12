local M = {}
local git = require("fzf-pack.git")

function M.read(path, head, target, opts)
  local max_log_bytes = opts.max_log_bytes or require("fzf-pack").options.max_log_bytes
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
    }, opts.timeout, max_log_bytes)
  end
  local counts = git.exec(path, { "rev-list", "--left-right", "--count", range, "--" }, opts.timeout)
  local left, right = counts:match("^(%d+)%s+(%d+)$")
  assert(left and right, "Could not classify Git history")
  local incoming, incoming_truncated = log("--right-only")
  local removed, removed_truncated = log("--left-only")
  local status = tonumber(right) == 0 and "rollback" or (tonumber(left) == 0 and "update" or "diverged")
  local function with_notice(output, truncated)
    if truncated then
      return output .. (output == "" and "" or "\n\n") .. ("[history truncated at %d bytes]"):format(max_log_bytes)
    end
    return output
  end
  local function side_output(output, truncated)
    if output == "" and not truncated then
      return "(none)"
    end
    return with_notice(output, truncated)
  end
  return {
    "Incoming commits (up to " .. opts.max_commits .. "):",
    side_output(incoming, incoming_truncated),
    "",
    "Removed commits (up to " .. opts.max_commits .. "):",
    side_output(removed, removed_truncated),
  },
    status
end

return M
