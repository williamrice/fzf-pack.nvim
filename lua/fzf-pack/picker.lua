local M = {}

local function clean(s)
  return tostring(s or "?"):gsub("[%c]", " ")
end
local function version(p)
  return p.spec.version == nil and "default branch" or tostring(p.spec.version)
end

-- Pad by display cells, so Unicode names do not shift the other columns.
local function cell(value, width)
  local text = clean(value)
  if vim.fn.strdisplaywidth(text) > width then
    while vim.fn.strdisplaywidth(text) > width - 1 do
      text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
    end
    text = text .. "…"
  end
  return text .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
end

function M.preview(row)
  local p = row.plugin
  local text = {
    p.spec.name .. " (" .. (p.active and "active" or "inactive") .. ")",
    "Status: " .. row.status,
    "Constraint: " .. version(p),
    "Installed: " .. (row.head or "?"),
    "Target: " .. (row.target or "?"),
    "Locked: " .. (p.rev or "?"),
    "Resolved ref: " .. (row.ref or "?"),
    "",
  }
  if row.error then
    text[#text + 1] = row.error
  end
  if row.log then
    vim.list_extend(text, row.log)
  end
  vim.list_extend(text, { "", "Source: " .. p.spec.src, "Path: " .. p.path })
  return vim.split(table.concat(text, "\n"):gsub("\r", ""), "\n")
end

function M.open(rows, opts, checked)
  local ok, fzf = pcall(require, "fzf-lua")
  assert(ok, "fzf-pack could not load fzf-lua: " .. tostring(fzf))
  assert(type(fzf.fzf_exec) == "function", "fzf-pack requires fzf-lua.fzf_exec")
  local entries, by_id = {}, {}
  local preview_cache = {}
  local name_width = 12
  for _, row in ipairs(rows) do
    name_width = math.max(name_width, math.min(24, vim.fn.strdisplaywidth(clean(row.plugin.spec.name))))
  end
  local function display(name, state, status)
    return cell(name, name_width) .. "  " .. cell(state, 8) .. "  " .. clean(status)
  end
  for i, row in ipairs(rows) do
    local p = row.plugin
    entries[i] = table.concat({
      tostring(i),
      clean(p.spec.name),
      display(p.spec.name, p.active and "active" or "inactive", row.status),
    }, "\t")
    by_id[i] = row
  end
  local function find(entry)
    return by_id[tonumber(entry:match("^(%d+)"))]
  end
  local Preview = require("fzf-lua.previewer.builtin").base:extend()
  -- fzf-lua merges previewer specs with its file-preview defaults. An
  -- inherited constructor is not a raw table field, so supply our own to
  -- prevent that merge from choosing the file previewer's constructor.
  function Preview:new(o, options, win)
    Preview.super.new(self, o, options, win)
    setmetatable(self, Preview)
    return self
  end
  function Preview:gen_winopts()
    return vim.tbl_extend("force", self.winopts, { wrap = true, number = false, relativenumber = false })
  end
  function Preview:populate_preview_buf(entry)
    local row = find(entry)
    local buf = self:get_tmp_buffer()
    local lines = row and preview_cache[row]
    if row and not lines then
      lines = M.preview(row)
      preview_cache[row] = lines
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
    self:set_preview_buf(buf)
    self.win:update_preview_scrollbar()
  end
  local function review(selected, all)
    local chosen, seen = {}, {}
    for _, entry in ipairs(all and entries or selected) do
      local row = find(entry)
      if row and row.target and row.head ~= row.target and not row.error and not seen[row] then
        chosen[#chosen + 1], seen[row] = row, true
      end
    end
    if #chosen == 0 then
      vim.notify("fzf-pack: No available updates selected", vim.log.levels.INFO)
      return
    end
    require("fzf-pack.check").review(chosen, opts, function(valid, err)
      if not valid then
        vim.notify("fzf-pack: " .. err, vim.log.levels.ERROR)
        return
      end
      local success, failure = pcall(require("fzf-pack.pack").review, chosen)
      if not success then
        vim.notify("fzf-pack: " .. failure, vim.log.levels.ERROR)
      end
    end)
  end
  local actions = checked
      and {
        ["enter"] = function(selected)
          review(selected, false)
        end,
        ["ctrl-a"] = function(selected)
          review(selected, true)
        end,
      }
    or { ["enter"] = function() end }
  return fzf.fzf_exec(entries, {
    prompt = checked and "PackUpdate> " or "Pack> ",
    header = (checked and "Tab: select · Enter: review · Ctrl-A: all" or "Local refs · :PackUpdate to fetch")
      .. "\n\n"
      .. display("PLUGIN", "STATE", "STATUS"),
    previewer = Preview,
    actions = actions,
    -- Matching fields refer to the transformed display, which has one field.
    -- Searching 2.. here would exclude the entire displayed plugin row.
    fzf_opts = { ["--multi"] = true, ["--delimiter"] = "\t", ["--with-nth"] = "3..", ["--nth"] = "1.." },
    winopts = {
      width = 0.95,
      height = 0.85,
      preview = { layout = "flex", flip_columns = 120, horizontal = "right:55%", vertical = "down:60%" },
    },
  })
end

return M
