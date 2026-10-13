vim.opt.runtimepath:prepend(vim.fn.getcwd())
assert(vim.env.FZF_PACK_TEST_TMP, "tests/cache.lua must run through tests/run.sh")

local cache = require("fzf-pack.cache")
local state_dir = vim.fn.stdpath("state")
local config_path = vim.fn.stdpath("config")
local opts = { max_commits = 20, max_log_bytes = 4096, config_path = config_path, appname = "nvim" }
local profile_key = vim.fn.sha256(vim.json.encode({ config_path, "nvim" }))
local cache_path = vim.fs.joinpath(state_dir, "fzf-pack-" .. profile_key .. ".json")
local plugin = {
  spec = { name = "private-plugin", src = "https://user:secret@example.test/repo.git", version = "stable" },
  path = "/plugins/private-plugin",
  rev = string.rep("a", 40),
  locked_src = "https://user:secret@example.test/repo.git",
  lock_bytes = '{"plugins":{"private-plugin":{"src":"credential"}}}',
}
local function record()
  return {
    hash = "abcdef123456",
    subject = "feat!: preserve metadata",
    body = "Details\n\nBREAKING CHANGE: update callers",
    partial = false,
    subject_complete = true,
    header_line = 0,
    header_end_col = #"commit abcdef12",
    subject_line = 1,
    subject_end_col = #"feat!: preserve metadata",
    breaking_subject = true,
    breaking_footer = true,
    breaking = true,
    footer_lines = { { start_line = 4, end_line = 4 } },
  }
end
local row = {
  plugin = plugin,
  head = string.rep("b", 40),
  target = string.rep("c", 40),
  ref = "refs/remotes/origin/stable",
  status = "update",
  checked_at = 1791914400,
  stale = false,
  log = {
    "Incoming commits (up to 20):",
    "commit abcdef12\nfeat!: preserve metadata\nDetails\n\nBREAKING CHANGE: update callers",
    "",
    "Removed commits (up to 20):",
    "(none)",
    records = { [2] = { record() }, [5] = {} },
    truncated = { [2] = true, [5] = false },
  },
}

-- The cache must not create the state directory.
local state_existed = vim.fn.isdirectory(state_dir) == 1
local miss = cache.load({ plugin }, opts)
assert(#miss == 1 and miss[1].status == "not checked" and miss[1].stale)
local failed, failure = cache.save({ row }, opts)
if not state_existed then
  assert(failed == nil and failure, "save without an existing state directory must fail")
  assert(vim.fn.isdirectory(state_dir) == 0, "cache.save must not create the state directory")
  assert(vim.fn.mkdir(state_dir, "p") == 1)
else
  assert(failed == true, "existing state directory supports cache save")
end

assert(cache.save({ row }, opts) == true)
local loaded = cache.load({ plugin }, opts)
assert(#loaded == 1 and loaded[1].plugin == plugin)
assert(loaded[1].head == row.head and loaded[1].target == row.target and loaded[1].ref == row.ref)
assert(loaded[1].status == "update" and loaded[1].checked_at == row.checked_at and loaded[1].stale)
assert(loaded[1].log[2] == row.log[2] and loaded[1].log[5] == row.log[5])
assert(loaded[1].log.records[2][1].body == row.log.records[2][1].body)
assert(loaded[1].log.records[2][1].footer_lines[1].start_line == 4)
assert(loaded[1].log.truncated[2] and not loaded[1].log.truncated[5])

local bytes = assert(vim.fn.readfile(cache_path, "b"))
local encoded = table.concat(bytes, "\n")
assert(not encoded:find("user:secret", 1, true) and not encoded:find("credential", 1, true))
assert(
  cache.load({ vim.deepcopy(plugin) }, vim.tbl_extend("force", opts, { max_commits = 21 }))[1].status == "not checked"
)
local oversized_options = vim.tbl_extend("force", opts, { max_log_bytes = 8 * 1024 * 1024 + 1 })
local large_load_ok, large_rows = pcall(cache.load, { plugin }, oversized_options)
assert(large_load_ok and large_rows[1].status == "not checked", "large supported options should become a cache miss")
local large_save, large_error = cache.save({ row }, oversized_options)
assert(large_save == nil and large_error, "cache save should skip options beyond cache capacity")
oversized_options = vim.tbl_extend("force", opts, { max_commits = 100000 })
large_load_ok, large_rows = pcall(cache.load, { plugin }, oversized_options)
assert(large_load_ok and large_rows[1].status == "not checked", "large commit budgets should become a cache miss")
local changed_source = vim.deepcopy(plugin)
changed_source.spec.src = "https://user:secret@example.test/other.git"
assert(cache.load({ changed_source }, opts)[1].status == "not checked")
local other_config = vim.tbl_extend("force", opts, { config_path = config_path .. "-other" })
assert(cache.load({ plugin }, other_config)[1].status == "not checked")

-- Malformed and oversized files are misses and never escape through the API.
assert(vim.fn.writefile({ "{not-json" }, cache_path, "b") == 0)
assert(cache.load({ plugin }, opts)[1].status == "not checked")
assert(vim.fn.writefile({ string.rep("x", 8 * 1024 * 1024 + 1) }, cache_path, "b") == 0)
assert(cache.load({ plugin }, opts)[1].status == "not checked")
assert(cache.save({ row }, opts) == true)
local malformed = vim.json.decode(table.concat(assert(vim.fn.readfile(cache_path, "b")), "\n"))
for _, saved in pairs(malformed.rows) do
  saved.log.records["2"][1].header_line = 999999
end
assert(vim.fn.writefile({ vim.json.encode(malformed) }, cache_path, "b") == 0)
assert(cache.load({ plugin }, opts)[1].status == "not checked")
assert(cache.save({ row }, opts) == true)
malformed = vim.json.decode(table.concat(assert(vim.fn.readfile(cache_path, "b")), "\n"))
for _, saved in pairs(malformed.rows) do
  saved.checked_at = os.time() + 86401
end
assert(vim.fn.writefile({ vim.json.encode(malformed) }, cache_path, "b") == 0)
assert(cache.load({ plugin }, opts)[1].status == "not checked", "unsafe future timestamps should be misses")
assert(cache.save({ row }, opts) == true)
malformed = vim.json.decode(table.concat(assert(vim.fn.readfile(cache_path, "b")), "\n"))
for _, saved in pairs(malformed.rows) do
  saved.log.lines[2] = saved.log.lines[2]:gsub("commit", "\r\r\r\r\r\r", 1)
end
assert(vim.fn.writefile({ vim.json.encode(malformed) }, cache_path, "b") == 0)
assert(cache.load({ plugin }, opts)[1].status == "not checked", "cache text cannot invalidate preview span offsets")

-- A fresh check error is transient: successful display fields are retained,
-- while the error text is not serialized.
row.last_status = row.status
row.status = "error"
row.error = "temporary network credential-like text"
assert(cache.save({ row }, opts) == true)
local final_bytes = table.concat(assert(vim.fn.readfile(cache_path, "b")), "\n")
assert(not final_bytes:find("temporary network", 1, true))
local recovered = cache.load({ plugin }, opts)[1]
assert(recovered.checked_at == row.checked_at and recovered.status == "update")

local error_only = vim.deepcopy(row)
error_only.last_status = nil
local error_profile = vim.tbl_extend("force", opts, { config_path = config_path .. "-error-only" })
assert(cache.save({ error_only }, error_profile) == true)
assert(cache.load({ plugin }, error_profile)[1].status == "not checked", "error-only status must not be cached")

local lock_before = plugin.lock_bytes
assert(cache.save({ row }, opts) == true)
assert(plugin.lock_bytes == lock_before, "cache operations must not modify lock data")
vim.fn.delete(cache_path)
print("PASS: persistent display cache")
