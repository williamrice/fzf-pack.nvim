local M = {}
local check = require("fzf-pack.check")
local cache = require("fzf-pack.cache")

function M.age(timestamp)
  if not timestamp then
    return "never"
  end
  local seconds = math.max(0, os.time() - timestamp)
  if seconds < 60 then
    return "just now"
  end
  local count, unit
  if seconds < 3600 then
    count, unit = math.floor(seconds / 60), "minute"
  elseif seconds < 86400 then
    count, unit = math.floor(seconds / 3600), "hour"
  else
    count, unit = math.floor(seconds / 86400), "day"
  end
  return ("%d %s%s ago"):format(count, unit, count == 1 and "" or "s")
end

local function recent(row, opts)
  local age = row.checked_at and (os.time() - row.checked_at)
  return age ~= nil and age >= 0 and age < (opts.refresh_interval or 3600) and not row.error
end

function M.open(opts)
  if M.current and M.current.view then
    vim.notify("fzf-pack: FzfPack is already open", vim.log.levels.INFO)
    return
  end
  local pack = require("fzf-pack.pack")
  assert(not pack.confirm_open(), "Close the update confirmation before opening FzfPack")
  local plugins = pack.list()
  if #plugins == 0 then
    vim.notify("fzf-pack: No installed plugins")
    return
  end
  local session = { rows = cache.load(plugins, opts), opts = opts, completed = 0, total = #plugins }
  for _, row in ipairs(session.rows) do
    row.stale = not recent(row, opts)
  end
  M.current = session
  function session:publish()
    if self.view then
      self.view.update()
    end
  end
  function session:resume_waiting()
    if M.current ~= self and M.current and M.current.waiting and M.current.view then
      M.current:refresh(M.current.waiting_automatic)
    end
  end
  function session:header()
    if self.waiting then
      return "Waiting for previous checks to finish"
    end
    if self.refreshing then
      return ("%s %d/%d"):format(
        self.stopping and "Stopping; finishing active checks" or "Refreshing",
        self.completed,
        self.total
      )
    end
    if self.stopping then
      return "Refresh cancelled; Ctrl-R to retry"
    end
    if self.completed > 0 then
      return ("Checked %d/%d · %s"):format(self.completed, self.total, M.age(self.finished_at))
    end
    local oldest
    for _, row in ipairs(self.rows) do
      if not row.checked_at then
        return "Last checked: never"
      end
      oldest = math.min(oldest or row.checked_at, row.checked_at)
    end
    return "Last checked: " .. M.age(oldest)
  end
  function session:refresh(automatic)
    if self.refreshing or self.reviewing then
      return
    end
    if check.running then
      self.waiting = true
      self.waiting_automatic = automatic
      self:publish()
      return
    end
    local ok, current_plugins = pcall(pack.list)
    if not ok then
      for _, row in ipairs(self.rows) do
        row.stale = true
      end
      self.message = tostring(current_plugins)
      self:publish()
      return
    end
    self.rows = cache.load(current_plugins, self.opts)
    self.waiting = false
    if automatic then
      local fresh = #self.rows > 0
      for _, row in ipairs(self.rows) do
        row.stale = not recent(row, self.opts)
        fresh = fresh and not row.stale
      end
      if fresh then
        self.message = nil
        self:publish()
        return
      end
    end
    self.completed, self.total = 0, #current_plugins
    self.refreshing, self.stopping, self.waiting, self.message = true, false, false, nil
    self:publish()
    check.start(current_plugins, self.opts, true, function()
      self.refreshing = false
      self.finished_at = os.time()
      self.message = nil
      cache.save(self.rows, self.opts)
      self:publish()
      self:resume_waiting()
    end, function(completed, total, row, index)
      self.completed, self.total = completed, total
      if row then
        if row.error then
          local previous = self.rows[index]
          previous.last_status = previous.status
          previous.error, previous.status, previous.stale = row.error, "error", true
        else
          row.checked_at, row.stale = os.time(), false
          self.rows[index] = row
        end
      end
      self:publish()
    end)
  end
  function session:stop()
    if self.refreshing then
      self.stopping = true
      check.stop()
      self:publish()
    end
  end
  function session:close()
    self.view = nil
    self.waiting = false
    self:stop()
  end
  return require("fzf-pack.picker").open(session.rows, opts, true, session)
end

return M
