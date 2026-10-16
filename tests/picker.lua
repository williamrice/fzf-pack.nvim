vim.opt.runtimepath:prepend(vim.fn.getcwd())

local captured, payload, reviewed
local callbacks = {}
package.loaded["fzf-lua"] = {
  fzf_exec = function(contents, options)
    captured = { contents = contents, options = options }
  end,
}
package.loaded["fzf-lua.utils"] = {
  ansi_from_hl = function(group, text)
    if group == "FzfPackFilterAll" then
      return "\27[34m" .. text .. "\27[0m"
    elseif group == "FzfPackFilterOutdated" then
      return "\27[33m" .. text .. "\27[0m"
    end
    return text
  end,
}
package.loaded["fzf-lua.previewer.builtin"] = {
  base = {
    extend = function()
      return {}
    end,
  },
}
package.loaded["fzf-pack.compat"] = {
  callback_command = function(callback)
    local name = "callback" .. (#callbacks + 1)
    callbacks[#callbacks + 1] = callback
    callbacks[name] = callback
    return name
  end,
}
package.loaded["fzf-pack.live"] = {
  new = function()
    return {
      send = function(_, action)
        payload = type(action) == "function" and action() or action
      end,
    }
  end,
}
package.loaded["fzf-pack.check"] = {
  review = function(rows)
    reviewed = rows
  end,
}
local rows = {}
for index, status in ipairs({ "current", "update", "rollback", "diverged", "error", "not checked", "update" }) do
  rows[index] = {
    plugin = { path = "/fixture/" .. index, active = true, spec = { name = "plugin" .. index, src = "source" } },
    status = status,
    head = "old",
    target = status ~= "not checked" and (status == "current" and "old" or "new") or nil,
    error = status == "error" and "check failed" or nil,
    stale = index == 7,
    checked_at = index == 7 and os.time() - 7200 or nil,
  }
end
local session = {
  rows = rows,
  header = function()
    return "Checked 7/7"
  end,
}
function session:publish()
  self.view.update()
end
local picker = require("fzf-pack.picker")
picker.open(rows, {}, true, session)
local options = captured.options
local contents = callbacks[captured.contents]
assert(#contents() == 7)
assert(options.header:find("Filter: All", 1, true), "picker starts with visible All filter state")
assert(options.header:find("\27[34m", 1, true), "All mode has its own color")
local first_line = options.header:match("[^\n]+")
assert(
  first_line:find("[ Filter: All ]", 1, true) and not first_line:find("Tab:", 1, true),
  "filter has a dedicated badge line"
)
local toggle = assert(options.actions["alt-u"], "Alt-U toggles outdated filter")
assert(toggle.exec_silent and toggle.field_index == "{q}", "toggle works without focused rows")
local mark = options.keymap.fzf.tab:match("execute%-silent%((.-)%)")
callbacks[mark]({ contents()[3] })
toggle.fn({ "search" })
assert(#contents() == 3, "only update, diverged and stale update are visible")
assert(contents()[1]:find("plugin2", 1, true) and contents()[2]:find("plugin4", 1, true))
assert(contents()[3]:find("stale", 1, true), "stale warning is retained")
assert(payload:find("Filter: Outdated", 1, true) and payload:find("Selected: 1", 1, true))
assert(payload:find("\27[33m", 1, true), "live header preserves Outdated color escapes")
assert(not payload:find("change-query", 1, true), "filter preserves query")
options.actions.enter.fn({ "search" })
assert(#reviewed == 1 and reviewed[1] == rows[3], "hidden marked rollback remains reviewable")
session.reviewing = false
options.actions["ctrl-a"].fn({ "search" })
assert(#reviewed == 3, "review all includes hidden rollback but excludes stale/error/current rows")
session.reviewing = false
rows[2].status, rows[2].target = "current", "old"
session.message = "Refreshing"
session:publish()
assert(#contents() == 2 and payload:find("Filter: Outdated", 1, true))
assert(payload:find("Refreshing", 1, true), "refresh message and filter coexist")
toggle.fn({})
assert(#contents() == 7 and payload:find("Selected: 1", 1, true))
assert(payload:find("\27[34m", 1, true), "toggling back restores All color")
session.rows = {}
session:publish()
toggle.fn({})
assert(#contents() == 0 and payload:find("Filter: Outdated", 1, true))
toggle.fn({})
assert(payload:find("Filter: All", 1, true), "empty filter can be turned off")
toggle.fn({})
session.rows = rows
picker.open(rows, {}, true, session)
assert(captured.options.header:find("Filter: Outdated", 1, true), "reopening remembers Outdated mode")
assert(#callbacks[captured.contents]() == 2, "remembered filter applies to initial rows")
captured.options.actions["alt-u"].fn({})
picker.open(rows, {}, true, session)
assert(captured.options.header:find("Filter: All", 1, true), "reopening remembers switching back to All")
assert(#callbacks[captured.contents]() == 7)
print("PASS: picker filtering, live results, hidden marks and review scope")
vim.cmd.qa({ bang = true })
