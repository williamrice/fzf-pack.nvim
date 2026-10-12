local M = {}

local function options(path, timeout)
  local env = vim.fn.environ()
  env.GIT_DIR, env.GIT_WORK_TREE, env.GIT_INDEX_FILE = nil, nil, nil
  env.GIT_TERMINAL_PROMPT = "0"
  return { cwd = path, text = true, timeout = timeout, env = env, clear_env = true }
end

-- Run one coroutine per plugin, yielding for each public vim.system call.
-- Resuming on the main loop also makes API calls safe inside consumers.
function M.run(work, done)
  local co = coroutine.create(work)
  local function resume(...)
    local ok, request = coroutine.resume(co, ...)
    if not ok then
      done(nil, tostring(request))
      return
    end
    if coroutine.status(co) == "dead" then
      done(request)
      return
    end
    local args = vim.list_extend({ "git", "-c", "gc.auto=0" }, request.args)
    local started, err = pcall(vim.system, args, options(request.path, request.timeout), function(out)
      vim.schedule(function()
        resume(out)
      end)
    end)
    if not started then
      vim.schedule(function()
        resume({ code = -1, stderr = tostring(err) })
      end)
    end
  end
  resume()
end

function M.exec(path, args, timeout)
  local out = coroutine.yield({ path = path, args = args, timeout = timeout })
  if out.code ~= 0 then
    error(("Git failed (%s): %s"):format(out.code, (out.stderr or ""):gsub("%s+$", "")), 0)
  end
  return (out.stdout or ""):gsub("\n+$", "")
end

return M
