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
  git(path, "commit", "-qm", subject, "-m", body or (subject .. " body"))
  return git(path, "rev-parse", "HEAD")
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
  local excluded = commit(upstream, "outside semver range")
  git(upstream, "tag", "v2.0.0")
  git(upstream, "checkout", "-q", "topic")
  local topic = commit(upstream, "topic update")
  git(upstream, "checkout", "-q", "main")
  local pack = require("fzf-pack.pack")
  local plugins = pack.list()
  local paths = {}
  for _, p in ipairs(plugins) do
    paths[p.spec.name] = p.path
  end
  git(paths.rollback, "fetch", "-q", "origin")
  git(paths.rollback, "checkout", "-q", newer)
  git(paths.diverged, "config", "user.name", "Fixture")
  git(paths.diverged, "config", "user.email", "fixture@example.invalid")
  local divergent = commit(paths.diverged, "removed subject", "removed body")
  vim.fn.rename(broken, broken .. "-unavailable")
  local bytes = pack.lock_bytes()
  local check = require("fzf-pack.check")
  local opts = { concurrency = 2, timeout = 10000, max_commits = 200 }
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
  expect(pack.lock_bytes() == bytes, "fetch check preserves lock bytes")
  expect(
    git(paths.branch, "rev-parse", "HEAD") == old and git(paths.diverged, "rev-parse", "HEAD") == divergent,
    "checks preserve installed revisions"
  )

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
  instance:populate_preview_buf(captured[1][2])
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
  pack.review({ rows.branch, rows.semver })
  vim.cmd.write()
  vim.wait(100, function()
    return not pack.confirm_open()
  end)
  expect(git(paths.branch, "rev-parse", "HEAD") == excluded, "write applies branch")
  expect(git(paths.semver, "rev-parse", "HEAD") == newer, "write applies constrained version")
  expect(#events == 4 and events[1].kind == "update", "native build events preserved")
  expect(git(paths.topic, "rev-parse", "HEAD") == old, "unselected plugin untouched")
  local after = pack.lock_bytes()
  expect(after ~= bytes, "accept updates lock")
  expect(git(paths.branch, "config", "--get-all", "remote.origin.url") == alias, "native update retains source alias")
  expect(vim.json.decode(after).plugins.branch.src == alias, "native update retains alias in lock")
  local success = pcall(pack.review, { rows.topic })
  expect(not success, "stale lock snapshot refused")

  -- Timeout a real Git fetch via a local upload-pack command.
  git(paths.topic, "config", "remote.origin.uploadpack", "sleep 2; git-upload-pack")
  local _, timed = collect(true, pack.list({}), { concurrency = 1, timeout = 100, max_commits = 20 })
  expect(timed.topic.error ~= nil, "timed out fetch isolated")
  git(paths.topic, "config", "--unset", "remote.origin.uploadpack")

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
