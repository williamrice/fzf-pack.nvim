local M = {}

local function options(path, timeout)
  local env = vim.fn.environ()
  env.GIT_DIR, env.GIT_WORK_TREE, env.GIT_INDEX_FILE = nil, nil, nil
  env.GIT_TERMINAL_PROMPT = "0"
  return { cwd = path, text = true, timeout = timeout, env = env, clear_env = true }
end

local function capture_stdout(limit)
  local chunks, size, truncated, output_error = {}, 0, false, nil
  local function on_stdout(err, data)
    if err then
      output_error = tostring(err)
    end
    if not data then
      return
    end
    local remaining = limit - size
    local count = math.min(remaining, #data)
    if count > 0 then
      chunks[#chunks + 1] = data:sub(1, count)
      size = size + count
    end
    if count < #data then
      truncated = true
    end
  end
  return on_stdout, function()
    return table.concat(chunks), truncated, output_error
  end
end

local function trim_incomplete_utf8(text)
  local start = #text
  while start > 0 do
    local byte = text:byte(start)
    if byte < 0x80 or byte > 0xBF then
      break
    end
    start = start - 1
  end
  if start == 0 then
    return text
  end
  local first = text:byte(start)
  local width = first >= 0xC2 and first <= 0xDF and 2
    or (first >= 0xE0 and first <= 0xEF) and 3
    or (first >= 0xF0 and first <= 0xF4) and 4
  if width and start + width - 1 > #text then
    return text:sub(1, start - 1)
  end
  return text
end

-- Run one coroutine per plugin, yielding for each public vim.system call.
-- Resuming on the main loop also makes API calls safe inside consumers.
function M.run(work, done)
  local co = coroutine.create(work)
  local cancelled, process = false, nil
  local function cancel()
    if cancelled then
      return false
    end
    cancelled = true
    if process then
      pcall(process.kill, process, "sigterm")
    end
    return true
  end
  local function resume(...)
    if cancelled then
      return
    end
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
    local opts = options(request.path, request.timeout)
    local finish_capture
    if request.max_stdout_bytes then
      opts.stdout, finish_capture = capture_stdout(request.max_stdout_bytes)
      opts.text = false
    end
    local started, result = pcall(vim.system, args, opts, function(out)
      vim.schedule(function()
        if cancelled then
          return
        end
        process = nil
        if finish_capture then
          out.stdout, out.stdout_truncated, out.stdout_error = finish_capture()
        end
        resume(out)
      end)
    end)
    if started then
      process = result
    else
      vim.schedule(function()
        resume({ code = -1, stderr = tostring(result) })
      end)
    end
  end
  resume()
  return cancel
end

function M.exec(path, args, timeout, max_stdout_bytes)
  local out = coroutine.yield({
    path = path,
    args = args,
    timeout = timeout,
    max_stdout_bytes = max_stdout_bytes,
  })
  if out.code ~= 0 then
    error(("Git failed (%s): %s"):format(out.code, (out.stderr or ""):gsub("%s+$", "")), 0)
  end
  if out.stdout_error then
    error("Failed to read Git output: " .. out.stdout_error, 0)
  end
  local stdout = (out.stdout or ""):gsub("\r\n", "\n"):gsub("\n+$", "")
  if out.stdout_truncated then
    stdout = trim_incomplete_utf8(stdout)
  end
  return stdout, out.stdout_truncated or false
end

return M
