local M = {}

local ssh_hosts = { ["github.com"] = true, ["gitlab.com"] = true, ["codeberg.org"] = true }

-- Convert only sources with an unambiguous browser destination. In particular,
-- do not resolve Git aliases or assume SSH ports are web server ports.
function M.url(source)
  if type(source) ~= "string" or source == "" or source:find("[%c%s\\]") then
    return nil
  end
  local escapes = source:gsub("%%(%x%x)", function(hex)
    local byte = tonumber(hex, 16)
    return (byte < 32 or byte == 127) and "\n" or ""
  end)
  if escapes:find("%%") or escapes:find("[%c]") then
    return nil
  end
  local scheme, authority, path = source:match("^(%a+)://([^/]+)(/.*)$")
  scheme = scheme and scheme:lower()
  if scheme ~= "http" and scheme ~= "https" then
    local host
    host, path = source:match("^git@([^:]+):(.+)$")
    if not host then
      host, path = source:match("^ssh://git@([^/]+)/(.+)$")
    end
    if not host or not ssh_hosts[host:lower()] or path:find("[?#]") then
      return nil
    end
    scheme, authority, path = "https", host:lower(), "/" .. path
  end
  -- Reject credentials rather than forwarding them into browser history.
  local host, port = authority:match("^([%w%.%-]+):?(%d*)$")
  if not host then
    host, port = authority:match("^(%[[%x:%.]+%]):?(%d*)$")
  end
  if not host or authority:sub(-1) == ":" or (port ~= "" and (tonumber(port) < 1 or tonumber(port) > 65535)) then
    return nil
  end
  if host:sub(1, 1) ~= "[" then
    if host:find("..", 1, true) or host:sub(1, 1) == "." then
      return nil
    end
    for label in host:gmatch("[^.]+") do
      if label:sub(1, 1) == "-" or label:sub(-1) == "-" then
        return nil
      end
    end
  end
  local repo_path, suffix = path:match("^([^?#]*)(.*)$")
  repo_path = repo_path:gsub("/+$", ""):gsub("%.git$", "")
  if repo_path == "" or repo_path == "/" or repo_path:find("//", 1, true) then
    return nil
  end
  return scheme .. "://" .. authority .. repo_path .. suffix
end

function M.open(source)
  local url = M.url(source)
  if not url then
    vim.notify("fzf-pack: No browser repository URL for this source", vim.log.levels.INFO)
    return
  end
  local ok, process, err = pcall(vim.ui.open, url)
  if not ok or not process then
    vim.notify("fzf-pack: Could not open repository: " .. tostring(ok and err or process), vim.log.levels.ERROR)
  end
end

return M
