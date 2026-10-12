local M = {}
local highlight_autocmd = false
local commit_highlight_namespace
local generated_commit_highlight

local status_highlights = {
  current = "FzfPackCurrent",
  update = "FzfPackUpdate",
  rollback = "FzfPackRollback",
  diverged = "FzfPackDiverged",
  error = "FzfPackError",
}

local highlight_links = {
  FzfPackCurrent = "DiagnosticOk",
  FzfPackUpdate = "DiagnosticError",
  FzfPackRollback = "DiagnosticWarn",
  FzfPackDiverged = "DiagnosticWarn",
  FzfPackError = "DiagnosticError",
}

local function commit_highlight()
  local identifier = vim.api.nvim_get_hl(0, { name = "Identifier", link = false })
  local highlight = { bold = true }
  if identifier.fg then
    highlight.fg = identifier.fg
  end
  if identifier.ctermfg then
    highlight.ctermfg = identifier.ctermfg
  end
  return highlight
end

local function refresh_commit_highlight()
  if not generated_commit_highlight then
    return
  end
  local current = vim.api.nvim_get_hl(0, { name = "FzfPackCommit", link = true })
  if next(current) == nil or vim.deep_equal(current, generated_commit_highlight) then
    vim.api.nvim_set_hl(0, "FzfPackCommit", commit_highlight())
    generated_commit_highlight = vim.api.nvim_get_hl(0, { name = "FzfPackCommit", link = true })
  end
end

local function initialize_highlights()
  for name, target in pairs(highlight_links) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
  if next(vim.api.nvim_get_hl(0, { name = "FzfPackCommit", link = true })) == nil then
    local highlight = vim.tbl_extend("force", commit_highlight(), { default = true })
    vim.api.nvim_set_hl(0, "FzfPackCommit", highlight)
    generated_commit_highlight = vim.api.nvim_get_hl(0, { name = "FzfPackCommit", link = true })
  end
  if not highlight_autocmd then
    local group = vim.api.nvim_create_augroup("FzfPackStatusHighlights", { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = group,
      callback = function()
        for name, target in pairs(highlight_links) do
          local current = vim.api.nvim_get_hl(0, { name = name, link = true })
          if next(current) == nil or current.link == target then
            vim.api.nvim_set_hl(0, name, { link = target })
          end
        end
        refresh_commit_highlight()
      end,
    })
    highlight_autocmd = true
  end
end

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
  local prefix = table.concat(text, "\n"):gsub("\r", "")
  local log_text = row.log and #row.log > 0 and table.concat(row.log, "\n"):gsub("\r", "") or nil
  if log_text then
    text[#text + 1] = log_text
  end
  local highlights = {}
  if log_text then
    local log_row = select(2, prefix:gsub("\n", "")) + 1
    for line in (log_text .. "\n"):gmatch("(.-)\n") do
      if line:match("^commit %x+$") then
        highlights[#highlights + 1] = {
          row = log_row,
          start_col = 0,
          end_col = #line,
        }
      end
      log_row = log_row + 1
    end
  end
  vim.list_extend(text, { "", "Source: " .. p.spec.src, "Path: " .. p.path })
  return vim.split(table.concat(text, "\n"):gsub("\r", ""), "\n"), highlights
end

function M.open(rows, opts, checked)
  local ok, fzf = pcall(require, "fzf-lua")
  assert(ok, "fzf-pack could not load fzf-lua: " .. tostring(fzf))
  assert(type(fzf.fzf_exec) == "function", "fzf-pack requires fzf-lua.fzf_exec")
  initialize_highlights()
  commit_highlight_namespace = commit_highlight_namespace or vim.api.nvim_create_namespace("fzf-pack-commit-headers")
  local utils = require("fzf-lua.utils")
  local entries, by_id = {}, {}
  local preview_cache = {}
  local name_width = 12
  for _, row in ipairs(rows) do
    name_width = math.max(name_width, math.min(24, vim.fn.strdisplaywidth(clean(row.plugin.spec.name))))
  end
  local function display(name, state, status)
    local visible_status = clean(status)
    local highlight = status_highlights[status]
    if highlight then
      visible_status = utils.ansi_from_hl(highlight, visible_status)
    end
    return cell(name, name_width) .. "  " .. cell(state, 8) .. "  " .. visible_status
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
    local formatted = row and preview_cache[row]
    if row and not formatted then
      local lines, highlights = M.preview(row)
      formatted = { lines = lines, highlights = highlights }
      preview_cache[row] = formatted
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, formatted and formatted.lines or {})
    vim.api.nvim_buf_clear_namespace(buf, commit_highlight_namespace, 0, -1)
    for _, span in ipairs(formatted and formatted.highlights or {}) do
      vim.api.nvim_buf_set_extmark(buf, commit_highlight_namespace, span.row, span.start_col, {
        end_col = span.end_col,
        hl_group = "FzfPackCommit",
      })
    end
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
      .. cell("PLUGIN", name_width)
      .. "  "
      .. cell("STATE", 8)
      .. "  STATUS",
    previewer = Preview,
    actions = actions,
    -- Matching fields refer to the transformed display, which has one field.
    -- Searching 2.. here would exclude the entire displayed plugin row.
    fzf_opts = {
      ["--ansi"] = true,
      ["--multi"] = true,
      ["--delimiter"] = "\t",
      ["--with-nth"] = "3..",
      ["--nth"] = "1..",
    },
    winopts = {
      width = 0.95,
      height = 0.85,
      preview = { layout = "flex", flip_columns = 120, horizontal = "right:55%", vertical = "down:60%" },
    },
  })
end

return M
