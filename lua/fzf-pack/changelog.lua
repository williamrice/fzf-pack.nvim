local M = {}
local git = require("fzf-pack.git")

local format = "commit %h%x00%s%x00%b%x00"

local function is_breaking_subject(subject)
  return subject:match("^[^%s%(%)!:]+!:%s+%S") ~= nil or subject:match("^[^%s%(%)!:]+%([^()]+%)!:%s+%S") ~= nil
end

local function footer_ranges(body)
  local lines = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  local last = #lines
  while last > 0 and lines[last] == "" do
    last = last - 1
  end
  local tokens, in_footer_block = {}, false
  for index = 1, last do
    local line = lines[index]
    local breaking = line:match("^BREAKING CHANGE:%s+%S") or line:match("^BREAKING%-CHANGE:%s+%S")
    local token = breaking and true or line:match("^[%w][%w%-]*:%s+%S") ~= nil
    token = token or line:match("^[%w][%w%-]*%s+#%S") ~= nil
    if token and (in_footer_block or index == 1 or lines[index - 1] == "") then
      tokens[#tokens + 1] = { line = index, breaking = breaking ~= nil }
      in_footer_block = true
    end
  end
  local ranges = {}
  for index, token in ipairs(tokens) do
    if token.breaking then
      ranges[#ranges + 1] = {
        start_line = token.line,
        end_line = (tokens[index + 1] and tokens[index + 1].line - 1) or last,
      }
    end
  end
  return lines, ranges
end

local function decode(output)
  local records, cursor = {}, 1
  while cursor <= #output do
    while output:sub(cursor, cursor) == "\n" do
      cursor = cursor + 1
    end
    if cursor > #output then
      break
    end
    local hash_end = output:find("\0", cursor, true)
    if not hash_end then
      break
    end
    local header = output:sub(cursor, hash_end - 1)
    local hash = header:match("^commit (%x+)$")
    if not hash then
      break
    end
    local subject_start = hash_end + 1
    local subject_end = output:find("\0", subject_start, true)
    if not subject_end then
      records[#records + 1] = {
        hash = hash,
        subject = output:sub(subject_start),
        body = "",
        partial = true,
        subject_complete = false,
      }
      break
    end
    local body_start = subject_end + 1
    local body_end = output:find("\0", body_start, true)
    records[#records + 1] = {
      hash = hash,
      subject = output:sub(subject_start, subject_end - 1),
      body = output:sub(body_start, body_end and body_end - 1 or #output),
      partial = body_end == nil,
      subject_complete = true,
    }
    if not body_end then
      break
    end
    cursor = body_end + 1
  end
  return records
end

local function count_newlines(text)
  local _, count = text:gsub("\n", "")
  return count
end

local function formatted(records)
  local output, lines = {}, 0
  for index, record in ipairs(records) do
    local separator = index == 1 and "" or "\n"
    local header = "commit " .. record.hash
    local rendered = header .. "\n" .. record.subject .. "\n" .. record.body
    local line_start = lines + count_newlines(separator)
    record.header_line = line_start
    record.header_end_col = #header
    record.subject_line = line_start + 1
    record.subject_end_col = #record.subject
    record.breaking_subject = record.subject_complete and is_breaking_subject(record.subject) or false
    local _, footers = footer_ranges(record.body)
    record.footer_lines = {}
    if #footers > 0 then
      record.breaking_footer = true
      local body_start = line_start + 2
      for _, footer in ipairs(footers) do
        record.footer_lines[#record.footer_lines + 1] = {
          start_line = body_start + footer.start_line - 1,
          end_line = body_start + footer.end_line - 1,
        }
      end
    end
    record.breaking = record.breaking_subject or record.breaking_footer or false
    output[#output + 1] = separator
    output[#output + 1] = rendered
    lines = line_start + count_newlines(rendered)
  end
  return table.concat(output), records
end

function M.read(path, head, target, opts)
  local max_log_bytes = opts.max_log_bytes or require("fzf-pack").options.max_log_bytes
  local range = head .. "..." .. target
  local function log(side)
    local raw, truncated = git.exec(path, {
      "log",
      "--no-color",
      "--topo-order",
      side,
      "--max-count=" .. opts.max_commits,
      "--format=" .. format,
      range,
      "--",
    }, opts.timeout, max_log_bytes)
    raw = raw:gsub("\r", "")
    local records = decode(raw)
    local output, metadata = formatted(records)
    output = output:gsub("\n+$", "")
    return output, truncated, metadata
  end
  local counts = git.exec(path, { "rev-list", "--left-right", "--count", range, "--" }, opts.timeout)
  local left, right = counts:match("^(%d+)%s+(%d+)$")
  assert(left and right, "Could not classify Git history")
  local incoming, incoming_truncated, incoming_records = log("--right-only")
  local removed, removed_truncated, removed_records = log("--left-only")
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
  local result = {
    "Incoming commits (up to " .. opts.max_commits .. "):",
    side_output(incoming, incoming_truncated),
    "",
    "Removed commits (up to " .. opts.max_commits .. "):",
    side_output(removed, removed_truncated),
  }
  result.records = { [2] = incoming_records, [5] = removed_records }
  result.truncated = { [2] = incoming_truncated, [5] = removed_truncated }
  return result, status
end

return M
