local root = assert(vim.env.FZF_PACK_TEST_ROOT)
local tmp = assert(vim.env.FZF_PACK_TEST_TMP)
vim.opt.runtimepath:prepend(root)
vim.opt.packpath:prepend(vim.fn.stdpath("data") .. "/site")
local total = 0
local function expect(value, message)
  assert(value, message)
  total = total + 1
end
local function git(path, ...)
  local args = { "git", "-C", path }
  vim.list_extend(args, { ... })
  local out = vim.system(args, { text = true }):wait()
  assert(out.code == 0, out.stderr)
  return out.stdout:gsub("\n+$", "")
end
local function commit(path, subject, body)
  vim.fn.writefile({ subject }, path .. "/content")
  git(path, "add", ".")
  local message_path = tmp .. "/commit-message"
  vim.fn.writefile(vim.split(subject .. "\n\n" .. (body or (subject .. " body")), "\n"), message_path)
  git(path, "commit", "-q", "-F", message_path)
  return git(path, "rev-parse", "HEAD")
end
local function valid_utf8(s)
  local i = 1
  while i <= #s do
    local first = s:byte(i)
    local width = first <= 0x7F and 1
      or (first >= 0xC2 and first <= 0xDF) and 2
      or (first >= 0xE0 and first <= 0xEF) and 3
      or (first >= 0xF0 and first <= 0xF4) and 4
    if not width or i + width - 1 > #s then
      return false
    end
    for j = i + 1, i + width - 1 do
      local byte = s:byte(j)
      if byte < 0x80 or byte > 0xBF then
        return false
      end
    end
    i = i + width
  end
  return true
end
local function repo(name)
  local path = tmp .. "/" .. name
  vim.fn.mkdir(path, "p")
  git(path, "init", "-q", "-b", "main")
  git(path, "config", "user.name", "Fixture")
  git(path, "config", "user.email", "fixture@example.invalid")
  return path
end
local function run()
  local upstream = repo("upstream")
  local old = commit(upstream, "initial")
  git(upstream, "tag", "-a", "v1.0.0", "-m", "annotated release")
  git(upstream, "branch", "topic")
  local alias = "fixture:"
  vim.env.GIT_CONFIG_COUNT = "1"
  vim.env.GIT_CONFIG_KEY_0 = "url." .. upstream .. ".insteadOf"
  vim.env.GIT_CONFIG_VALUE_0 = alias
  local broken = repo("broken-upstream")
  commit(broken, "broken initial")
  local specs = {
    { name = "branch", src = alias, version = "main" },
    { name = "default", src = upstream },
    { name = "pinned", src = upstream, version = old },
    { name = "tagged", src = upstream, version = "v1.0.0" },
    { name = "semver", src = upstream, version = vim.version.range("^1.0.0") },
    { name = "rollback", src = upstream, version = old },
    { name = "diverged", src = upstream, version = "main" },
    { name = "topic", src = upstream, version = "topic" },
    { name = "broken", src = broken },
  }
  vim.pack.add(specs, { confirm = false, load = false })
  local newer = commit(upstream, "incoming subject", "incoming body\n\nMore details.")
  git(upstream, "tag", "v1.1.0")
  local incoming_body = "incoming body\n" .. string.rep("payload界", 16384)
  local excluded = commit(upstream, "outside semver range", incoming_body)
  git(upstream, "tag", "v2.0.0")
  git(upstream, "checkout", "-q", "topic")
  local topic = commit(upstream, "topic update")
  git(upstream, "checkout", "-q", "main")
  -- A same-named tag must not shadow the remote branch in either resolver.
  git(upstream, "tag", "main", old)
  local pack = require("fzf-pack.pack")
  local config = require("fzf-pack")
  expect(config.options.max_log_bytes == 65536, "default per-side history byte limit")
  expect(not pcall(config.setup, { max_log_bytes = 0 }), "history byte limit must be positive")
  local plugins = pack.list()
  local paths = {}
  for _, p in ipairs(plugins) do
    paths[p.spec.name] = p.path
  end
  local lock_after_add = vim.json.decode(assert(pack.lock_bytes()))
  expect(type(lock_after_add.plugins) == "table", "vim.pack serializes plugins as a lock map")
  for _, p in ipairs(plugins) do
    local name = p.spec.name
    local data = assert(lock_after_add.plugins[name], "lock entry exists for " .. name)
    expect(type(data.rev) == "string" and data.rev == p.rev, "serialized cached revision matches vim.pack for " .. name)
    expect(data.src == p.spec.src, "serialized source matches vim.pack for " .. name)
    local version = p.spec.version
    local serialized = type(version) == "string" and ("'%s'"):format(version) or (version and tostring(version))
    expect(data.version == serialized, "serialized version matches vim.pack for " .. name)
  end
  git(paths.rollback, "fetch", "-q", "origin")
  git(paths.rollback, "checkout", "-q", newer)
  git(paths.diverged, "config", "user.name", "Fixture")
  git(paths.diverged, "config", "user.email", "fixture@example.invalid")
  local removed_body = "removed body\n" .. string.rep("removed界", 16384)
  local divergent = commit(paths.diverged, "removed subject", removed_body)
  vim.fn.rename(broken, broken .. "-unavailable")
  local bytes = pack.lock_bytes()
  local check = require("fzf-pack.check")
  local opts = { concurrency = 2, timeout = 10000, max_commits = 200, max_log_bytes = 1024 }
  local unmatched = vim.deepcopy(plugins[1])
  unmatched.spec.version = vim.version.range(">=9.0.0")
  local function collect(fetch, list, options)
    local result
    expect(
      check.start(list or pack.list(), options or opts, fetch, function(rows)
        result = rows
      end),
      "check starts"
    )
    expect(
      vim.wait(30000, function()
        return result ~= nil
      end, 10),
      "check finishes"
    )
    local map = {}
    for _, row in ipairs(result) do
      map[row.plugin.spec.name] = row
    end
    return result, map
  end
  local _, unmatched_rows = collect(false, { unmatched })
  local unmatched_row = unmatched_rows[unmatched.spec.name]
  expect(
    unmatched_row.error and unmatched_row.error:find("No tags fit configured version constraint", 1, true),
    "read-only resolver rejects an unmatched range"
  )
  local _, local_rows = collect(false)
  expect(local_rows.branch.target == old, "local listing does not fetch")
  expect(git(paths.branch, "rev-parse", "refs/remotes/origin/main") == old, "local refs unchanged")
  expect(local_rows.rollback.head == newer, "installed revision comes from HEAD, not lock")
  expect(git(paths.branch, "config", "--get-all", "remote.origin.url") == alias, "vim.pack retains source alias")
  local _, alias_rows = collect(true, { local_rows.branch.plugin })
  expect(alias_rows.branch.target == excluded, "insteadOf source checks and fetches")
  expect(git(paths.branch, "rev-parse", "HEAD") == old, "alias fetch preserves installed revision")
  expect(pack.lock_bytes() == bytes, "alias fetch preserves lock bytes")
  local fetched_ref = git(paths.branch, "rev-parse", "refs/remotes/origin/main")
  git(paths.branch, "config", "--add", "remote.origin.url", upstream)
  local _, multiple_rows = collect(true, { local_rows.branch.plugin })
  expect(multiple_rows.branch.target == excluded, "first matching URL works with a secondary URL")
  git(paths.branch, "config", "--replace-all", "remote.origin.url", upstream)
  git(paths.branch, "config", "--add", "remote.origin.url", alias)
  local _, mismatch_rows = collect(true, { local_rows.branch.plugin })
  expect(
    mismatch_rows.branch.error and mismatch_rows.branch.error:find("origin differs from configured source", 1, true),
    "mismatched first URL is rejected"
  )
  expect(git(paths.branch, "rev-parse", "refs/remotes/origin/main") == fetched_ref, "mismatched origin does not fetch")
  git(paths.branch, "config", "--replace-all", "remote.origin.url", alias)
  local result
  local system = vim.system
  local in_flight, peak, fetches = 0, 0, 0
  vim.system = function(args, options, callback)
    if not callback then
      return system(args, options)
    end
    in_flight = in_flight + 1
    peak = math.max(peak, in_flight)
    if vim.tbl_contains(args, "fetch") then
      fetches = fetches + 1
    end
    return system(args, options, function(out)
      in_flight = in_flight - 1
      callback(out)
    end)
  end
  expect(
    check.start(pack.list(), opts, true, function(rows)
      result = rows
    end),
    "async check starts"
  )
  expect(result == nil, "async check returns before completion")
  expect(not check.start(pack.list(), opts, true, function()
    error("duplicate callback")
  end), "duplicate check rejected")
  local heartbeat = false
  vim.schedule(function()
    heartbeat = true
  end)
  expect(
    vim.wait(30000, function()
      return result ~= nil
    end, 10),
    "fetch completes"
  )
  vim.system = system
  expect(peak <= opts.concurrency and peak > 1, "checks are bounded and parallel")
  expect(fetches == #plugins, "one fetch per plugin; duplicate checks launch no work")
  expect(heartbeat, "main loop runs during fetch")
  local rows = {}
  for _, row in ipairs(result) do
    rows[row.plugin.spec.name] = row
  end
  expect(rows.branch.target == excluded, "branch follows remote")
  expect(rows.default.target == excluded, "default branch follows origin HEAD")
  expect(rows.topic.target == topic, "nondefault branch")
  expect(rows.branch.ref == "refs/remotes/origin/main", "branch wins over same-named tag")
  expect(rows.pinned.target == old and rows.pinned.status == "current", "pinned commit stays pinned")
  expect(rows.tagged.target == old, "annotated tag resolves commit")
  expect(rows.semver.target == newer, "semver excludes v2")
  expect(rows.rollback.target == old and rows.rollback.status == "rollback", "rollback classified")
  expect(rows.diverged.status == "diverged", "diverged history classified")
  expect(rows.broken.error and rows.branch.status == "update", "fetch failure isolated")
  local preview = table.concat(require("fzf-pack.picker").preview(rows.diverged), "\n")
  expect(
    preview:find("incoming body", 1, true) and preview:find("removed body", 1, true),
    "subjects and bodies on both sides"
  )
  expect(select(2, preview:gsub("truncated", "")) == 2, "both oversized history sides show truncation")
  expect(#table.concat(rows.diverged.log, "\n") <= 2 * opts.max_log_bytes + 512, "history output stays byte bounded")
  local _, tiny_rows =
    collect(false, { rows.rollback.plugin, rows.diverged.plugin }, vim.tbl_extend("force", opts, { max_log_bytes = 1 }))
  expect(tiny_rows.rollback.status == "rollback", "tiny history budget preserves rollback classification")
  expect(tiny_rows.diverged.status == "diverged", "tiny history budget preserves divergence classification")
  expect(
    select(2, table.concat(tiny_rows.diverged.log, "\n"):gsub("truncated", "")) == 2,
    "tiny budget reports truncation on both sides"
  )

  local raw_incoming = vim
    .system({
      "git",
      "-C",
      paths.branch,
      "log",
      "--no-color",
      "--topo-order",
      "--right-only",
      "--max-count=" .. opts.max_commits,
      "--format=commit %h%n%s%n%b",
      rows.branch.head .. "..." .. rows.branch.target,
      "--",
    }, { text = true })
    :wait()
  expect(raw_incoming.code == 0, "full history fixture is readable")
  local changelog = require("fzf-pack.changelog")
  local function read_changelog(options)
    local result, failure
    require("fzf-pack.git").run(function()
      return changelog.read(paths.branch, rows.branch.head, rows.branch.target, options)
    end, function(value, err)
      result, failure = value, err
    end)
    expect(
      vim.wait(30000, function()
        return result ~= nil or failure ~= nil
      end, 10),
      "bounded changelog read finishes"
    )
    assert(not failure, failure)
    return result
  end
  local exact_log = read_changelog(vim.tbl_extend("force", opts, { max_log_bytes = #raw_incoming.stdout }))
  expect(not table.concat(exact_log, "\n"):find("truncated", 1, true), "exact byte budget is not marked truncated")
  local short_log = read_changelog(vim.tbl_extend("force", opts, { max_log_bytes = #raw_incoming.stdout - 1 }))
  expect(table.concat(short_log, "\n"):find("truncated", 1, true), "one byte below output size is truncated")
  local multibyte_at = assert(raw_incoming.stdout:find("界", 1, true))
  local boundary_log = read_changelog(vim.tbl_extend("force", opts, { max_log_bytes = multibyte_at }))
  expect(valid_utf8(boundary_log[2]), "byte cap preserves a complete UTF-8 boundary")
  expect(table.concat(boundary_log, "\n"):find("truncated", 1, true), "UTF-8 boundary truncation is visible")

  local many_plugins = {}
  for i = 1, 12 do
    local plugin = vim.deepcopy(rows.diverged.plugin)
    plugin.spec.name = "bounded-row-" .. i
    many_plugins[i] = plugin
  end
  local _, many_rows = collect(false, many_plugins, opts)
  for _, row in pairs(many_rows) do
    expect(row.status == "diverged", "many changed rows retain independent status")
    expect(#table.concat(row.log, "\n") <= 2 * opts.max_log_bytes + 512, "many changed rows remain byte bounded")
  end
  expect(pack.lock_bytes() == bytes, "fetch check preserves lock bytes")
  expect(
    git(paths.branch, "rev-parse", "HEAD") == old and git(paths.diverged, "rev-parse", "HEAD") == divergent,
    "checks preserve installed revisions"
  )

  -- Compare every read-only target with native vim.pack's public confirmation.
  local native_names, native_heads, native_targets = {}, {}, {}
  for _, row in ipairs(result) do
    if row.target and not row.error then
      local name = row.plugin.spec.name
      native_names[#native_names + 1] = name
      native_heads[name] = row.head
      native_targets[name] = row.target
    end
  end
  for _, name in ipairs({ "default", "branch", "tagged", "pinned", "semver", "topic", "rollback", "diverged" }) do
    expect(native_targets[name] ~= nil, "native parity includes " .. name)
  end
  vim.pack.update(native_names, { offline = true, force = false, target = "version" })
  expect(pack.confirm_open(), "native target comparison opens confirmation")
  local native_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local native_revisions, current_plugin = {}, nil
  for _, line in ipairs(native_lines) do
    current_plugin = line:match("^## ([^%s]+)") or current_plugin
    local revision = line:match("^Revision after:%s*(%x+)") or line:match("^Revision:%s*(%x+)")
    if current_plugin and revision then
      native_revisions[current_plugin] = revision
    end
  end
  for name, target in pairs(native_targets) do
    expect(native_revisions[name] == target, "read-only target matches native vim.pack for " .. name)
  end
  vim.cmd.quit()
  expect(
    vim.wait(100, function()
      return not pack.confirm_open()
    end),
    "native target comparison cancels"
  )
  expect(pack.lock_bytes() == bytes, "native target comparison preserves lock")
  for name, head in pairs(native_heads) do
    expect(git(paths[name], "rev-parse", "HEAD") == head, "native target comparison preserves HEAD for " .. name)
  end

  -- A reviewed row becomes stale if either its installed HEAD or resolved
  -- target ref changes before handoff to native confirmation.
  local function review_snapshot(row)
    local result, err
    expect(check.review({ row }, opts, function(valid, failure)
      result, err = valid, failure
    end) ~= false, "snapshot validation starts")
    expect(
      vim.wait(10000, function()
        return result ~= nil or err ~= nil
      end, 10),
      "snapshot validation finishes"
    )
    return result, err
  end
  git(paths.rollback, "checkout", "-q", old)
  local head_valid, head_error = review_snapshot(rows.rollback)
  expect(
    not head_valid and tostring(head_error):find("Plugin changed since checking", 1, true),
    "changed installed HEAD invalidates snapshot"
  )
  expect(
    pack.lock_bytes() == bytes and not pack.confirm_open(),
    "stale HEAD refusal preserves lock and closes confirmation"
  )
  git(paths.rollback, "checkout", "-q", newer)
  git(paths.branch, "update-ref", "refs/remotes/origin/main", old)
  local ref_valid, ref_error = review_snapshot(rows.branch)
  expect(
    not ref_valid and tostring(ref_error):find("Plugin changed since checking", 1, true),
    "changed target ref invalidates snapshot"
  )
  expect(
    pack.lock_bytes() == bytes and not pack.confirm_open(),
    "stale ref refusal preserves lock and closes confirmation"
  )
  git(paths.branch, "update-ref", "refs/remotes/origin/main", excluded)

  -- Exercise the picker action wiring independently of terminal interaction.
  local captured
  package.loaded["fzf-lua"] = {
    fzf_exec = function(entries, settings)
      captured = { entries, settings }
    end,
  }
  local base = {}
  function base:new()
    self.winopts = {}
    return self
  end
  function base:extend()
    local class = { super = self }
    class.__index = class
    return setmetatable(class, { __index = self })
  end
  package.loaded["fzf-lua.previewer.builtin"] = { base = base }
  local picker = require("fzf-pack.picker")
  picker.open(result, opts, true)
  expect(captured[2].fzf_opts["--multi"], "multi selection enabled")
  local original = pack.review
  local selected
  pack.review = function(chosen)
    selected = chosen
  end
  local entry_map = {}
  for _, entry in ipairs(captured[1]) do
    for _, row in ipairs(result) do
      if entry:match("^%d+\t([^\t]+)") == row.plugin.spec.name then
        entry_map[row.plugin.spec.name] = entry
      end
    end
  end
  captured[2].actions.enter({ entry_map.branch, entry_map.semver, entry_map.pinned })
  expect(
    vim.wait(10000, function()
      return selected ~= nil
    end),
    "selected handoff finishes"
  )
  expect(#selected == 2, "multi selection excludes unchanged plugins")
  selected = nil
  captured[2].actions["ctrl-a"]({ entry_map.pinned })
  expect(
    vim.wait(10000, function()
      return selected ~= nil
    end),
    "review all handoff finishes"
  )
  expect(#selected == 6, "review all includes available changes and excludes errors")
  pack.review = original

  -- Long and wide-character names must keep the visible state column aligned.
  local long = vim.deepcopy(rows.branch)
  long.plugin.spec.name = string.rep("界", 20)
  local short = vim.deepcopy(rows.pinned)
  short.plugin.spec.name = "short"
  picker.open({ long, short }, opts, true)
  local function state_column(entry)
    local visible = assert(entry:match("^%d+\t[^\t]+\t(.+)$"))
    return vim.fn.strdisplaywidth(assert(visible:match("^(.-)active"))), visible
  end
  local col_long, visible_long = state_column(captured[1][1])
  local col_short, visible_short = state_column(captured[1][2])
  expect(col_long == col_short and visible_long:find("…", 1, true), "Unicode and long names align and truncate")
  expect(not visible_short:find(old, 1, true), "dense revision fields live in preview only")
  expect(captured[2].fzf_opts["--with-nth"] == "3..", "picker hides identity fields from visible rows")
  expect(table.concat(picker.preview(short), "\n"):find(old, 1, true), "expanded details retain full revisions")

  -- Reproduce fzf-lua's default merge and constructor dispatch. Inherited
  -- constructors get replaced by the default file previewer during merging.
  local preview_spec = vim.tbl_deep_extend("keep", captured[2].previewer, {
    new = function()
      error("file previewer constructor selected")
    end,
  })
  local instance = preview_spec:new(preview_spec, {})
  local buffer = vim.api.nvim_create_buf(false, true)
  instance.get_tmp_buffer = function()
    return buffer
  end
  instance.set_preview_buf = function(_, buf)
    expect(buf == buffer, "preview uses detail buffer")
  end
  instance.win = { update_preview_scrollbar = function() end }
  local original_preview = picker.preview
  local preview_calls = 0
  picker.preview = function(row)
    preview_calls = preview_calls + 1
    return original_preview(row)
  end
  instance:populate_preview_buf(captured[1][2])
  instance:populate_preview_buf(captured[1][2])
  expect(preview_calls == 1, "formatted preview is cached for the picker lifetime")
  picker.preview = original_preview
  local rendered = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  expect(
    rendered:find("short (active)", 1, true) and rendered:find(old, 1, true),
    "custom preview survives fzf-lua default merge and renders plugin details"
  )
  vim.api.nvim_buf_delete(buffer, { force = true })

  -- The native confirmation must support cancellation and emit actual hooks.
  pack.review({ rows.branch, rows.semver })
  expect(vim.bo.filetype == "nvim-pack" and vim.bo.buftype == "acwrite", "native confirmation buffer")
  expect(pack.lock_bytes() == bytes, "opening native review preserves lock")
  vim.cmd.quit()
  vim.wait(100, function()
    return not pack.confirm_open()
  end)
  expect(pack.lock_bytes() == bytes and git(paths.branch, "rev-parse", "HEAD") == old, "quit cancels")
  local events = {}
  vim.api.nvim_create_autocmd({ "PackChangedPre", "PackChanged" }, {
    callback = function(ev)
      events[#events + 1] = { event = ev.event, name = ev.data.spec.name, kind = ev.data.kind }
    end,
  })
  pack.review({ rows.branch, rows.semver, rows.rollback, rows.diverged })
  vim.cmd.write()
  vim.wait(100, function()
    return not pack.confirm_open()
  end)
  expect(git(paths.branch, "rev-parse", "HEAD") == excluded, "write applies branch")
  expect(git(paths.semver, "rev-parse", "HEAD") == newer, "write applies constrained version")
  expect(git(paths.rollback, "rev-parse", "HEAD") == old, "native acceptance applies rollback")
  expect(git(paths.diverged, "rev-parse", "HEAD") == excluded, "native acceptance resolves divergence")
  expect(git(paths.topic, "rev-parse", "HEAD") == old, "unselected topic remains untouched")
  local event_counts = {}
  for _, event in ipairs(events) do
    event_counts[event.name] = event_counts[event.name] or { pre = 0, changed = 0 }
    local key = event.event == "PackChangedPre" and "pre" or "changed"
    event_counts[event.name][key] = event_counts[event.name][key] + 1
    expect(event.kind == "update", "native update event kind")
  end
  for _, name in ipairs({ "branch", "semver", "rollback", "diverged" }) do
    local count = event_counts[name]
    expect(count and count.pre == 1 and count.changed == 1, "native build events preserved for " .. name)
  end
  expect(#events == 8, "native acceptance emits pre and post events for every selected update")
  local after = pack.lock_bytes()
  expect(after ~= bytes, "accept updates lock")
  local lock_after_accept = vim.json.decode(after)
  for _, name in ipairs({ "branch", "semver", "rollback", "diverged" }) do
    expect(
      lock_after_accept.plugins[name].rev == rows[name].target,
      "native acceptance serializes target revision for " .. name
    )
  end
  expect(git(paths.branch, "config", "--get-all", "remote.origin.url") == alias, "native update retains source alias")
  expect(vim.json.decode(after).plugins.branch.src == alias, "native update retains alias in lock")
  local success = pcall(pack.review, { rows.topic })
  expect(not success, "stale lock snapshot refused")

  -- Timeout identity, elapsed time, sibling isolation, and retry all use a
  -- local upload-pack command and the existing fixture repositories.
  git(paths.topic, "config", "remote.origin.uploadpack", "sleep 2; git-upload-pack")
  local check_timeout = 300
  local timeout_options = { concurrency = 2, timeout = check_timeout, max_commits = 20 }
  local topic_plugin, healthy_plugin
  for _, plugin in ipairs(pack.list()) do
    if plugin.spec.name == "topic" then
      topic_plugin = plugin
    elseif plugin.spec.name == "branch" then
      healthy_plugin = plugin
    end
  end
  local system = vim.system
  local started = vim.uv.hrtime()
  local killed_at
  vim.system = function(args, options, callback)
    local process = system(args, options, callback)
    if callback and options.cwd == paths.topic and vim.tbl_contains(args, "fetch") then
      local kill = process.kill
      process.kill = function(self, signal)
        killed_at = killed_at or vim.uv.hrtime()
        return kill(self, signal)
      end
    end
    return process
  end
  local _, timed = collect(true, { topic_plugin, healthy_plugin }, timeout_options)
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
  local kill_elapsed_ms = killed_at and (killed_at - started) / 1e6
  vim.system = system
  expect(
    timed.topic.error and timed.topic.error:find("Git failed (124):", 1, true),
    "timeout is reported on the timed-out plugin with Neovim's timeout code: " .. tostring(timed.topic.error)
  )
  expect(
    kill_elapsed_ms and kill_elapsed_ms >= check_timeout / 2 and kill_elapsed_ms < 1500,
    ("timeout signal is sent near its deadline (%.1f ms)"):format(kill_elapsed_ms or -1)
  )
  -- Git's child upload-pack can retain the output pipes after Git is killed,
  -- so callback completion may follow the two-second fixture delay.
  expect(elapsed_ms < 5000, ("timed fetch callback drains pipes (%.1f ms)"):format(elapsed_ms))
  expect(not timed.branch.error and timed.branch.target == excluded, "healthy sibling result survives timeout")
  git(paths.topic, "config", "--unset", "remote.origin.uploadpack")
  local _, recovered = collect(true, { topic_plugin }, { concurrency = 1, timeout = 10000, max_commits = 20 })
  expect(
    not recovered.topic.error and recovered.topic.target == topic,
    "fetch recovers after timeout source is removed"
  )

  -- Cancellation must release the run guard while a killed Git child still
  -- holds inherited pipes, and its late callback must not disturb a new run.
  require("fzf-pack.commands").register()
  expect(vim.fn.exists(":PackCancel") == 2, "PackCancel command is registered")
  expect(not check.cancel(), "idle cancel is safe")
  local before_cancel_lock = pack.lock_bytes()
  local before_cancel_topic_head = git(paths.topic, "rev-parse", "HEAD")
  local before_cancel_branch_head = git(paths.branch, "rev-parse", "HEAD")
  local old_transport_marker = tmp .. "/cancel-old-transport-started"
  local new_transport_marker = tmp .. "/cancel-new-transport-started"
  vim.fn.delete(old_transport_marker)
  vim.fn.delete(new_transport_marker)
  git(
    paths.topic,
    "config",
    "remote.origin.uploadpack",
    "printf started > " .. vim.fn.shellescape(old_transport_marker) .. "; sleep 4; git-upload-pack"
  )
  local original_system = vim.system
  local old_process, old_callback_count, old_kill_count = nil, 0, 0
  local queued_fetch_count = 0
  vim.system = function(args, options, callback)
    if not callback then
      return original_system(args, options)
    end
    local old_fetch = callback and options.cwd == paths.topic and vim.tbl_contains(args, "fetch")
    local queued_fetch = callback and options.cwd == paths.branch and vim.tbl_contains(args, "fetch")
    local process = original_system(args, options, function(out)
      if old_fetch then
        old_callback_count = old_callback_count + 1
      end
      callback(out)
    end)
    if old_fetch then
      old_process = process
      local kill = process.kill
      process.kill = function(self, signal)
        old_kill_count = old_kill_count + 1
        return kill(self, signal)
      end
    elseif queued_fetch then
      queued_fetch_count = queued_fetch_count + 1
    end
    return process
  end
  local old_done_count, old_progress = 0, {}
  expect(
    check.start(
      { topic_plugin, healthy_plugin },
      { concurrency = 1, timeout = 15000, max_commits = 20 },
      true,
      function()
        old_done_count = old_done_count + 1
      end,
      function(completed, count)
        old_progress[#old_progress + 1] = { completed, count }
      end
    ),
    "cancellable run starts"
  )
  expect(
    vim.wait(5000, function()
      return old_process ~= nil
    end, 10),
    "slow fetch process starts"
  )
  expect(
    vim.wait(5000, function()
      return vim.fn.filereadable(old_transport_marker) == 1
    end, 10),
    "old upload-pack child starts before cancellation"
  )
  vim.cmd.PackCancel()
  expect(not check.running, "cancel immediately releases duplicate protection")
  expect(old_kill_count == 1, "cancel signals the active Git process")
  expect(old_callback_count == 0, "cancel returns before inherited pipes drain")
  expect(queued_fetch_count == 0, "cancel prevents queued plugin work from starting")
  expect(not check.cancel(), "repeated cancel is safe")
  local old_progress_count = #old_progress
  git(paths.topic, "config", "--unset", "remote.origin.uploadpack")
  git(
    paths.branch,
    "config",
    "remote.origin.uploadpack",
    "printf started > " .. vim.fn.shellescape(new_transport_marker) .. "; sleep 8; git-upload-pack"
  )
  local new_done, new_done_count, new_progress = nil, 0, {}
  expect(
    check.start({ healthy_plugin }, { concurrency = 1, timeout = 15000, max_commits = 20 }, true, function(rows)
      new_done, new_done_count = rows, new_done_count + 1
    end, function(completed, count)
      new_progress[#new_progress + 1] = { completed, count }
    end),
    "new run starts before canceled process pipes drain"
  )
  expect(
    vim.wait(5000, function()
      return vim.fn.filereadable(new_transport_marker) == 1
    end, 10),
    "replacement upload-pack child starts"
  )
  expect(check.running and queued_fetch_count == 1, "new run remains guarded while its fetch is active")
  expect(
    vim.wait(7000, function()
      return old_callback_count > 0
    end, 10),
    "canceled process callback arrives after transport drains"
  )
  expect(check.running and new_done == nil, "old callback cannot release or complete the new run")
  expect(
    old_done_count == 0 and #old_progress == old_progress_count,
    "canceled run emits no late completion or progress"
  )
  expect(
    vim.wait(10000, function()
      return new_done ~= nil
    end, 10),
    "new run completes after old callback"
  )
  expect(new_done_count == 1 and not check.running, "new run completes exactly once and releases guard")
  expect(
    #new_progress == 2
      and new_progress[1][1] == 0
      and new_progress[1][2] == 1
      and new_progress[2][1] == 1
      and new_progress[2][2] == 1,
    "progress counts advance monotonically from zero through completion"
  )
  vim.system = original_system
  git(paths.branch, "config", "--unset", "remote.origin.uploadpack")
  expect(not check.cancel(), "cancel is safe after completion")
  expect(
    pack.lock_bytes() == before_cancel_lock
      and git(paths.topic, "rev-parse", "HEAD") == before_cancel_topic_head
      and git(paths.branch, "rev-parse", "HEAD") == before_cancel_branch_head,
    "canceled and replacement checks preserve lock bytes and installed revisions"
  )
  local progress_error_done = false
  expect(
    check.start({ healthy_plugin }, { concurrency = 1, timeout = 10000, max_commits = 20 }, false, function()
      progress_error_done = true
    end, function()
      error("expected progress callback failure")
    end),
    "progress callback failure check starts"
  )
  expect(
    vim.wait(10000, function()
      return progress_error_done
    end, 10),
    "progress callback failure does not strand completion"
  )
  expect(not check.running, "progress callback failure releases duplicate protection")
  local done_error_called = false
  expect(
    check.start({ healthy_plugin }, { concurrency = 1, timeout = 10000, max_commits = 20 }, false, function()
      done_error_called = true
      error("expected completion callback failure")
    end),
    "completion callback failure check starts"
  )
  expect(
    vim.wait(10000, function()
      return done_error_called and not check.running
    end, 10),
    "completion callback failure leaves the check guard clear"
  )

  -- New Neovim process: inactive specs restored from lock; no fetch or writes.
  vim.fn.rename(broken .. "-unavailable", broken)
  local child = vim
    .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", root .. "/tests/repeat.lua" }, { text = true })
    :wait(30000)
  expect(child.code == 0, "repeat startup: " .. (child.stderr or ""))
  expect(pack.lock_bytes() == after, "repeat startup preserves lock")

  -- An external revision change to an unselected plugin must invalidate a
  -- fresh check and a newly checked selected update in this session.
  local _, current_rows = collect(false)
  expect(current_rows.topic.status == "update", "unselected topic remains available to update")
  local external_lock = vim.json.decode(after)
  external_lock.plugins.pinned.rev = newer
  local external_bytes = vim.json.encode(external_lock)
  local lock_path = vim.fs.joinpath(vim.fn.stdpath("config"), "nvim-pack-lock.json")
  local lock_file = assert(io.open(lock_path, "wb"))
  lock_file:write(external_bytes)
  lock_file:close()
  local branch_head = git(paths.branch, "rev-parse", "HEAD")
  local topic_head = git(paths.topic, "rev-parse", "HEAD")
  local fresh_ok = pcall(function()
    collect(false)
  end)
  expect(not fresh_ok, "fresh check refuses externally changed cached revision")
  local review_ok, review_error = pcall(pack.review, { current_rows.topic })
  expect(
    not review_ok and tostring(review_error):find("cached lock revisions differ", 1, true),
    "selected update refuses because an unselected cached revision differs"
  )
  expect(not pack.confirm_open(), "refusal does not open native confirmation")
  expect(pack.lock_bytes() == external_bytes, "external lock bytes preserved after refusal")
  expect(
    git(paths.branch, "rev-parse", "HEAD") == branch_head and git(paths.topic, "rev-parse", "HEAD") == topic_head,
    "refusal preserves selected and unselected installed revisions"
  )
  print(("PASS: %d assertions on Neovim %s"):format(total, tostring(vim.version())))
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd.cquit()
end
vim.cmd.qa({ bang = true })
