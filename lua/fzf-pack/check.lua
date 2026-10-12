local M = { running = false }
local git = require("fzf-pack.git")

local function lines(s)
  return s == "" and {} or vim.split(s, "\n")
end

-- Only version selection is mirrored: public vim.pack does not expose a
-- read-only target resolver. Uses public vim.version parsing/comparison.
function M.resolve(p, opts)
  local function exec(args)
    return git.exec(p.path, args, opts.timeout)
  end
  local version = p.spec.version
  local ref
  if version == nil then
    ref = exec({ "symbolic-ref", "refs/remotes/origin/HEAD" })
  else
    local branches = lines(exec({ "for-each-ref", "--format=%(refname:strip=3)", "refs/remotes/origin/" }))
    if type(version) == "string" then
      ref = vim.tbl_contains(branches, version) and ("refs/remotes/origin/" .. version) or version
    else
      local best, tag
      for _, name in ipairs(lines(exec({ "tag", "--list", "--sort=-v:refname" }))) do
        local parsed = vim.version.parse(name, { strict = true })
        if parsed and version:has(parsed) and (not best or vim.version.gt(parsed, best)) then
          best, tag = parsed, name
        end
      end
      assert(tag, "No tags fit configured version constraint")
      ref = tag
    end
  end
  return exec({ "rev-parse", "--verify", "--end-of-options", ref .. "^{commit}" }), ref
end

function M.inspect(p, opts, fetch, row)
  row = row or { plugin = p }
  row.head = git.exec(p.path, { "rev-parse", "HEAD" }, opts.timeout)
  assert(p.spec.src == p.locked_src, "Configured source changed; reconcile with vim.pack first")
  if fetch then
    local urls = git.exec(p.path, { "config", "--null", "--get-all", "remote.origin.url" }, opts.timeout)
    -- Git fetches from the first configured URL; remote get-url expands insteadOf aliases.
    local origin = urls:match("^(.-)%z") or urls
    assert(origin == p.spec.src, "origin differs from configured source; reconcile with vim.pack first")
    git.exec(p.path, { "fetch", "--quiet", "--tags", "--force", "--recurse-submodules=no", "origin" }, opts.timeout)
  end
  row.target, row.ref = M.resolve(p, opts)
  row.status = row.head == row.target and (fetch and "current" or "cached") or "update"
  if row.head ~= row.target then
    row.log, row.status = require("fzf-pack.changelog").read(p.path, row.head, row.target, opts)
  end
  return row
end

function M.start(plugins, opts, fetch, done)
  if M.running or require("fzf-pack.pack").confirm_open() then
    vim.notify("fzf-pack: A check or native confirmation is already open", vim.log.levels.WARN)
    return false
  end
  M.running = true
  local rows, next_index, active, finished = {}, 1, 0, 0
  local pump
  pump = function()
    if finished == #plugins then
      M.running = false
      done(rows)
      return
    end
    while active < opts.concurrency and next_index <= #plugins do
      local index = next_index
      next_index, active = next_index + 1, active + 1
      local p = plugins[index]
      local row = { plugin = p, status = "checking" }
      rows[index] = row
      git.run(function()
        return M.inspect(p, opts, fetch, row)
      end, function(result, err)
        if err then
          row.error, row.status = err, "error"
        else
          rows[index] = result
        end
        active, finished = active - 1, finished + 1
        pump()
      end)
    end
  end
  pump()
  return true
end

-- Verify that the reviewed target and installed HEAD still match the snapshot
-- before native update resolves local refs again. No fetching during handoff.
function M.review(rows, opts, done)
  if M.running then
    done(nil, "A check is already running")
    return
  end
  M.running = true
  local index = 1
  local function next_row()
    local row = rows[index]
    if not row then
      M.running = false
      done(true)
      return
    end
    index = index + 1
    git.run(function()
      local head = git.exec(row.plugin.path, { "rev-parse", "HEAD" }, opts.timeout)
      local target = M.resolve(row.plugin, opts)
      assert(head == row.head and target == row.target, "Plugin changed since checking; run :PackUpdate again")
      return true
    end, function(_, err)
      if err then
        M.running = false
        done(nil, err)
      else
        next_row()
      end
    end)
  end
  next_row()
end

return M
