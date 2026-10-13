local M = {}

local MAX_FILE_BYTES = 8 * 1024 * 1024
local MAX_CACHE_COMMITS = MAX_FILE_BYTES / 128
local MAX_CACHE_LOG_BYTES = MAX_FILE_BYTES / 8
local MAX_SAFE_INTEGER = 9007199254740991
local SCHEMA = 1
local uv = vim.uv
local VALID_STATUSES = { current = true, update = true, rollback = true, diverged = true }

local function finite_integer(value, minimum, maximum)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value % 1 == 0
    and value >= minimum
    and value <= maximum
end

local function sha256(value)
  return vim.fn.sha256(value)
end

local function version_key(version)
  if version == nil then
    return ""
  end
  if type(version) == "string" or type(version) == "number" or type(version) == "boolean" then
    return tostring(version)
  end
  -- vim.version ranges are table-like on the supported runtime. Inspect gives
  -- their value fields without serializing a userdata or an object address.
  return vim.inspect(version, { newline = "", indent = "", depth = 4 })
end

local function identity(plugin, opts)
  if
    type(plugin) ~= "table"
    or type(plugin.spec) ~= "table"
    or type(plugin.spec.name) ~= "string"
    or type(plugin.spec.src) ~= "string"
    or type(plugin.path) ~= "string"
    or type(plugin.rev) ~= "string"
  then
    return nil
  end
  local components = {
    plugin.spec.name,
    sha256(plugin.spec.src),
    version_key(plugin.spec.version),
    plugin.path,
    plugin.rev,
    sha256(type(plugin.lock_bytes) == "string" and plugin.lock_bytes or "<no-lock-bytes>"),
    tostring(opts.max_commits),
    tostring(opts.max_log_bytes),
  }
  return sha256(vim.json.encode(components))
end

local function cache_path(opts)
  local config_path = opts.config_path or vim.fn.stdpath("config")
  local appname = opts.appname or "nvim"
  local profile_key = sha256(vim.json.encode({ config_path, appname }))
  return vim.fs.joinpath(vim.fn.stdpath("state"), "fzf-pack-" .. profile_key .. ".json")
end

local function array_length(value, maximum, allowed_named)
  if type(value) ~= "table" then
    return nil
  end
  local length = #value
  if length > maximum then
    return nil
  end
  for key in pairs(value) do
    if not finite_integer(key, 1, length) then
      if not allowed_named or not allowed_named[key] then
        return nil
      end
    end
  end
  return length
end

local function cacheable_options(opts)
  return type(opts) == "table"
    and finite_integer(opts.max_commits, 1, MAX_SAFE_INTEGER)
    and finite_integer(opts.max_log_bytes, 1, MAX_SAFE_INTEGER)
    and opts.max_commits <= MAX_CACHE_COMMITS
    and opts.max_log_bytes <= MAX_CACHE_LOG_BYTES
end

local function validate_record(record, section_lines, max_commits)
  local line_count = #section_lines
  if type(record) ~= "table" then
    return false
  end
  if
    type(record.hash) ~= "string"
    or #record.hash > 64
    or not record.hash:match("^%x+$")
    or type(record.subject) ~= "string"
    or type(record.body) ~= "string"
    or type(record.partial) ~= "boolean"
    or type(record.subject_complete) ~= "boolean"
    or type(record.breaking) ~= "boolean"
    or type(record.breaking_subject) ~= "boolean"
    or (record.breaking_footer ~= nil and type(record.breaking_footer) ~= "boolean")
    or not finite_integer(record.header_line, 0, line_count - 1)
    or not finite_integer(record.header_end_col, 0, 128)
    or not finite_integer(record.subject_line, 0, line_count - 1)
    or not finite_integer(record.subject_end_col, 0, 65536)
    or type(record.footer_lines) ~= "table"
  then
    return false
  end
  local footer_count = array_length(record.footer_lines, max_commits * 4)
  if not footer_count then
    return false
  end
  for _, span in ipairs(record.footer_lines) do
    if
      type(span) ~= "table"
      or not finite_integer(span.start_line, 0, line_count - 1)
      or not finite_integer(span.end_line, span.start_line, line_count - 1)
    then
      return false
    end
  end
  if
    record.header_end_col > #section_lines[record.header_line + 1]
    or record.subject_end_col > #section_lines[record.subject_line + 1]
  then
    return false
  end
  return true
end

local function validate_log(log, opts)
  if log == nil then
    return nil
  end
  if type(log) ~= "table" then
    return nil
  end
  local line_count = array_length(log, math.floor(2 * opts.max_log_bytes + 512), { records = true, truncated = true })
  if not line_count then
    return nil
  end
  local byte_count = 0
  for _, line in ipairs(log) do
    if type(line) ~= "string" or line:find("\r", 1, true) then
      return nil
    end
    byte_count = byte_count + #line + 1
  end
  if byte_count > 2 * opts.max_log_bytes + 512 then
    return nil
  end
  if type(log.records) ~= "table" or type(log.truncated) ~= "table" then
    return nil
  end
  for _, index in ipairs({ 2, 5 }) do
    local records = log.records[index]
    local count = array_length(records, opts.max_commits)
    if not count or type(log[index]) ~= "string" or type(log.truncated[index]) ~= "boolean" then
      return nil
    end
    local section_lines = vim.split(log[index], "\n", { plain = true })
    for _, record in ipairs(records) do
      if not validate_record(record, section_lines, opts.max_commits) then
        return nil
      end
    end
  end
  return log
end

local function valid_row(row, opts, validate_display_log)
  if type(row) ~= "table" then
    return false
  end
  if
    (row.status ~= "error" and not VALID_STATUSES[row.status])
    or (row.last_status ~= nil and not VALID_STATUSES[row.last_status])
    or not VALID_STATUSES[row.last_status or row.status]
  then
    return false
  end
  if
    type(row.head) ~= "string"
    or #row.head > 128
    or type(row.target) ~= "string"
    or #row.target > 128
    or type(row.ref) ~= "string"
    or #row.ref > 65536
    or not finite_integer(row.checked_at, 0, os.time() + 86400)
  then
    return false
  end
  if validate_display_log ~= false and row.log ~= nil and not validate_log(row.log, opts) then
    return false
  end
  return true
end

local function clean_record(record)
  return {
    hash = record.hash,
    subject = record.subject,
    body = record.body,
    partial = record.partial,
    subject_complete = record.subject_complete,
    header_line = record.header_line,
    header_end_col = record.header_end_col,
    subject_line = record.subject_line,
    subject_end_col = record.subject_end_col,
    breaking_subject = record.breaking_subject,
    breaking_footer = record.breaking_footer,
    breaking = record.breaking,
    footer_lines = vim.deepcopy(record.footer_lines),
  }
end

local function clean_log(log)
  if not log then
    return nil
  end
  local lines = {}
  for _, line in ipairs(log) do
    lines[#lines + 1] = line
  end
  local records = {}
  for _, index in ipairs({ 2, 5 }) do
    records[tostring(index)] = {}
    for _, record in ipairs(log.records[index]) do
      records[tostring(index)][#records[tostring(index)] + 1] = clean_record(record)
    end
  end
  return {
    lines = lines,
    records = records,
    truncated = { ["2"] = log.truncated[2], ["5"] = log.truncated[5] },
  }
end

local function restore_log(encoded, opts)
  if encoded == nil then
    return nil
  end
  if type(encoded) ~= "table" or type(encoded.lines) ~= "table" then
    return nil
  end
  local log = vim.deepcopy(encoded.lines)
  log.records = {}
  log.truncated = {}
  for _, index in ipairs({ 2, 5 }) do
    local key = tostring(index)
    if type(encoded.records) ~= "table" or type(encoded.records[key]) ~= "table" then
      return nil
    end
    log.records[index] = encoded.records[key]
    if type(encoded.truncated) ~= "table" or type(encoded.truncated[key]) ~= "boolean" then
      return nil
    end
    log.truncated[index] = encoded.truncated[key]
  end
  if not validate_log(log, opts) then
    return nil
  end
  return log
end

local function decode_rows(path, opts)
  local fd = uv.fs_open(path, "r", 384)
  if not fd then
    return {}
  end
  local stat = uv.fs_fstat(fd)
  if not stat or stat.size > MAX_FILE_BYTES then
    uv.fs_close(fd)
    return {}
  end
  local bytes = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if type(bytes) ~= "string" or #bytes > MAX_FILE_BYTES then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, bytes)
  if not ok or type(decoded) ~= "table" or decoded.schema ~= SCHEMA or type(decoded.rows) ~= "table" then
    return {}
  end
  return decoded.rows
end

function M.load(plugins, opts)
  opts = opts or {}
  assert(type(plugins) == "table", "plugins must be a table")
  if not cacheable_options(opts) then
    local misses = {}
    for index, plugin in ipairs(plugins) do
      misses[index] = { plugin = plugin, status = "not checked", stale = true }
    end
    return misses
  end
  local stored = decode_rows(cache_path(opts), opts)
  local results = {}
  for index, plugin in ipairs(plugins) do
    local key = identity(plugin, opts)
    local saved = key and stored[key]
    local row
    if type(saved) == "table" and saved.identity == key and valid_row(saved, opts, false) then
      local log = restore_log(saved.log, opts)
      if saved.log == nil or log then
        row = {
          plugin = plugin,
          head = saved.head,
          target = saved.target,
          ref = saved.ref,
          status = saved.status,
          checked_at = saved.checked_at,
          stale = true,
          log = log,
        }
      end
    end
    results[index] = row or { plugin = plugin, status = "not checked", stale = true }
  end
  return results
end

local function write_atomic(path, bytes)
  local nonce = tostring(uv.os_getpid()) .. "-" .. tostring(uv.hrtime())
  local temp = path .. "." .. nonce .. ".tmp"
  local fd, open_err = uv.fs_open(temp, "wx", 384)
  if not fd then
    return nil, open_err
  end
  local ok, err = pcall(function()
    local written, write_err = uv.fs_write(fd, bytes, 0)
    if written ~= #bytes then
      error(write_err or "short cache write")
    end
    local sync_ok, sync_err = uv.fs_fsync(fd)
    if not sync_ok then
      error(sync_err or "cache sync failed")
    end
  end)
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(temp)
    return nil, err
  end
  local renamed, rename_err = uv.fs_rename(temp, path)
  if not renamed then
    uv.fs_unlink(temp)
    return nil, rename_err
  end
  return true
end

function M.save(rows, opts)
  opts = opts or {}
  if type(rows) ~= "table" then
    return nil, "invalid cache arguments"
  end
  if not cacheable_options(opts) then
    return nil, "cache options exceed cache capacity"
  end
  local encoded_rows = {}
  for _, row in ipairs(rows) do
    local plugin = type(row) == "table" and row.plugin
    local key = identity(plugin, opts)
    -- A failed refresh may carry the last successful fields alongside an error.
    -- Persist only those fields; the transient error message is never cached.
    if key and valid_row(row, opts) then
      local saved = {
        identity = key,
        head = row.head,
        target = row.target,
        ref = row.ref,
        status = row.last_status or row.status,
        checked_at = row.checked_at,
        log = clean_log(row.log),
      }
      encoded_rows[key] = saved
    end
  end
  local ok, bytes = pcall(vim.json.encode, { schema = SCHEMA, rows = encoded_rows })
  if not ok or type(bytes) ~= "string" or #bytes > MAX_FILE_BYTES then
    return nil, "cache data exceeds the supported size"
  end
  return write_atomic(cache_path(opts), bytes)
end

return M
