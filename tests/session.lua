vim.opt.runtimepath:prepend(vim.fn.getcwd())

local plugin = {
  spec = { name = "session-plugin", src = "https://example.test/session.git", version = "main" },
  path = "/plugins/session-plugin",
  rev = string.rep("a", 40),
  lock_bytes = "lock-snapshot",
}
local fixed_time = 1700000000
local original_time = os.time
os.time = function()
  return fixed_time
end

local events, runs, opens = {}, {}, {}
local check = { running = false, stops = 0 }
function check.start(plugins, opts, fetch, done, progress)
  assert(not check.running, "session must reject duplicate check starts")
  check.running = true
  events[#events + 1] = "check.start"
  local run = { plugins = plugins, opts = opts, fetch = fetch, done = done, progress = progress }
  function run:finish()
    check.running = false
    self.done()
  end
  function run:report(completed, total, row, index)
    self.progress(completed, total, row, index)
  end
  runs[#runs + 1] = run
end
function check.stop()
  check.stops = check.stops + 1
  events[#events + 1] = "check.stop"
  -- Active work drains after the queue is stopped.
end

local pack = { fail_list = false }
function pack.confirm_open()
  return false
end
function pack.list()
  if pack.fail_list then
    error("pack list unavailable")
  end
  return { plugin }
end

local function make_row(status, checked_at)
  return {
    plugin = plugin,
    head = string.rep("b", 40),
    target = string.rep("c", 40),
    ref = "refs/remotes/origin/main",
    status = status or "update",
    log = { "incoming cached history", records = { [2] = {}, [5] = {} }, truncated = { [2] = false, [5] = false } },
    checked_at = checked_at or 1699990000,
    stale = true,
  }
end
local stored_rows = { make_row() }
local cache = { saves = {} }
function cache.load(plugins)
  local rows = {}
  for index, current_plugin in ipairs(plugins) do
    local saved = stored_rows[index]
    if saved then
      rows[index] = vim.deepcopy(saved)
      rows[index].plugin = current_plugin
      rows[index].stale = true
    else
      rows[index] = { plugin = current_plugin, status = "not checked", stale = true }
    end
  end
  return rows
end
function cache.save(rows)
  assert(not check.running, "completion must clear the mock running guard before persistence")
  events[#events + 1] = "cache.save"
  local saved = {}
  for index, row in ipairs(rows) do
    saved[index] = vim.deepcopy(row)
    saved[index].plugin = plugin
    saved[index].status = row.last_status or row.status
    saved[index].last_status = nil
    saved[index].error = nil
    saved[index].stale = true
  end
  stored_rows = saved
  cache.saves[#cache.saves + 1] = vim.deepcopy(saved)
  return true
end

package.loaded["fzf-pack.check"] = check
package.loaded["fzf-pack.cache"] = cache
package.loaded["fzf-pack.pack"] = pack
package.loaded["fzf-pack.picker"] = {
  open = function(rows, opts, checked, session)
    events[#events + 1] = "picker.open"
    local view = { updates = 0 }
    function view.update()
      view.updates = view.updates + 1
      events[#events + 1] = "view.update"
    end
    session.view = view
    opens[#opens + 1] = { rows = rows, opts = opts, checked = checked, session = session, view = view }
    return view
  end,
}

local session_module = require("fzf-pack.session")
local opts = { concurrency = 2, timeout = 1000, max_commits = 20, max_log_bytes = 1024, refresh_interval = 0 }
local first_view = session_module.open(opts)
local first = opens[1].session
assert(first_view == opens[1].view and opens[1].checked)
assert(opens[1].rows[1].stale and opens[1].rows[1].head == stored_rows[1].head)
assert(#runs == 0 and events[1] == "picker.open", "picker must open before check startup")

first.reviewing = true
first:refresh()
assert(#runs == 0 and not first.waiting, "reviewing inhibits refresh")
first.reviewing = false
first:refresh()
assert(#runs == 1 and events[#events - 1] == "view.update" and events[#events] == "check.start")
first:refresh()
assert(#runs == 1 and first.refreshing, "duplicate refresh while active is ignored")

local fresh = {
  plugin = plugin,
  head = string.rep("d", 40),
  target = string.rep("e", 40),
  ref = "refs/remotes/origin/main",
  status = "update",
  log = { "fresh incoming history", records = { [2] = {}, [5] = {} }, truncated = { [2] = false, [5] = false } },
}
runs[1]:report(1, 1, fresh, 1)
assert(first.rows[1] == fresh and fresh.checked_at == fixed_time and fresh.stale == false)
events = {}
runs[1]:finish()
assert(not first.refreshing and first.finished_at == fixed_time)
assert(events[1] == "cache.save" and events[2] == "view.update", "completion persists before publishing")
assert(cache.saves[1][1].checked_at == fixed_time and cache.saves[1][1].status == "update")

first:refresh()
assert(#runs == 2, "a completed session accepts another refresh")
local previous = first.rows[1]
local previous_log = vim.deepcopy(previous.log)
runs[2]:report(0, 1, { plugin = plugin, error = "temporary fetch error" }, 1)
local failed = first.rows[1]
assert(failed.status == "error" and failed.last_status == "update" and failed.stale)
assert(failed.error == "temporary fetch error")
assert(
  failed.head == previous.head
    and failed.target == previous.target
    and failed.checked_at == previous.checked_at
    and vim.deep_equal(failed.log, previous_log),
  "failed refresh retains the last successful display data"
)
runs[2]:finish()
assert(cache.saves[2][1].status == "update" and cache.saves[2][1].checked_at == fixed_time)

-- A list failure must leave prior rows visible but stale.
first.rows[1].stale = false
pack.fail_list = true
first:refresh()
assert(first.rows[1].stale and first.message:find("pack list unavailable", 1, true))
pack.fail_list = false

-- Closing stops queued work and detaches the session from its view.
first:refresh()
assert(#runs == 3 and first.refreshing)
local old_view = opens[1].view
local old_updates = old_view.updates
first:close()
assert(first.view == nil and check.stops == 1 and check.running)

-- Reopen while that worker is active. The new view waits; old completion
-- starts a check for the new session without publishing into the detached UI.
local second_view = session_module.open(opts)
local second = opens[2].session
assert(second_view == opens[2].view and #runs == 3)
assert(opens[2].rows[1].stale)
second.reviewing = true
second:refresh()
assert(not second.waiting and #runs == 3, "reviewing inhibits a waiting refresh")
second.reviewing = false
second:refresh()
assert(second.waiting and #runs == 3)
assert(second:header() == "Waiting for previous checks to finish")
runs[3]:finish()
assert(#runs == 4 and second.refreshing and not second.waiting, "old completion starts the waiting session")
assert(old_view.updates == old_updates, "old completion must not resurrect its closed UI")

second:close()
assert(second.view == nil and check.stops == 2)
runs[4]:finish()
assert(not check.running)

local cached_opts = vim.tbl_extend("force", opts, { refresh_interval = 3600 })
stored_rows = { make_row("update", fixed_time - 120) }
session_module.open(cached_opts)
local recent = session_module.current
local before_recent = #runs
recent:refresh(true)
assert(#runs == before_recent, "recent saved results skip automatic checks")
assert(not recent.rows[1].stale and recent:header():find("2 minutes ago", 1, true))
recent:refresh()
assert(#runs == before_recent + 1, "manual refresh ignores the interval")
runs[#runs]:finish()
recent:close()
for _, timestamp in ipairs({ fixed_time - 3600, fixed_time + 60, 0 }) do
  stored_rows = { make_row("update", timestamp) }
  session_module.open(cached_opts)
  local expired = session_module.current
  local before = #runs
  expired:refresh(true)
  assert(#runs == before + 1, "expired, future, or missing successful checks refresh automatically")
  runs[#runs]:finish()
  expired:close()
end
assert(session_module.age(fixed_time - 7200) == "2 hours ago")
assert(session_module.age(fixed_time - 172800) == "2 days ago")
stored_rows = {}
session_module.open(cached_opts)
local missing = session_module.current
local before_missing = #runs
missing:refresh(true)
assert(#runs == before_missing + 1, "missing cache checks regardless of interval")
missing:close()
session_module.open(cached_opts)
local waiting_recent = session_module.current
waiting_recent:refresh(true)
runs[#runs]:report(1, 1, make_row("current", fixed_time), 1)
runs[#runs]:finish()
assert(
  #runs == before_missing + 1 and not waiting_recent.waiting,
  "reopening reuses results completed by the draining check rather than fetching again"
)
assert(not waiting_recent.rows[1].stale)
waiting_recent:close()
local config = require("fzf-pack")
assert(config.options.refresh_interval == 3600)
for _, invalid in ipairs({ -1, 0.5, math.huge, "3600" }) do
  assert(not pcall(config.setup, { refresh_interval = invalid }), "invalid refresh interval rejected")
end
config.setup({ refresh_interval = 0 })
assert(config.options.refresh_interval == 0)
assert(not pcall(config.setup, { timeout = 0 }), "Git timeout remains positive")
os.time = original_time
print("PASS: session lifecycle")
vim.cmd.qa({ bang = true })
