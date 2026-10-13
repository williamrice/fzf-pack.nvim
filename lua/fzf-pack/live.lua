local M = {}

-- Coalesce updates sent through fzf's loopback HTTP control API.
function M.new()
  local self = { closed = false, pending = nil, port = nil, sockets = {} }
  function self:send(actions)
    if self.closed then
      return
    end
    self.pending = actions
    if not self.port or self.scheduled or self.busy then
      return
    end
    self.scheduled = true
    vim.defer_fn(function()
      self.scheduled = false
      if self.closed or not self.pending then
        return
      end
      local payload = self.pending
      self.pending = nil
      if type(payload) == "function" then
        payload = payload()
      end
      self.busy = true
      local socket = assert(vim.uv.new_tcp())
      self.sockets[socket] = true
      local function close()
        if not self.sockets[socket] then
          return
        end
        self.sockets[socket] = nil
        self.busy = false
        if not socket:is_closing() then
          socket:close()
        end
        vim.schedule(function()
          if self.pending and not self.closed then
            self:send(self.pending)
          end
        end)
      end
      socket:connect("127.0.0.1", self.port, function(err)
        if err or self.closed then
          close()
          return
        end
        local auth = self.key and ("X-API-Key: " .. self.key .. "\r\n") or ""
        local request = "POST / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
          .. auth
          .. "Content-Length: "
          .. #payload
          .. "\r\n\r\n"
          .. payload
        socket:write(request, function(write_err)
          if write_err then
            close()
          end
        end)
        socket:read_start(function(read_err, data)
          if read_err or not data then
            close()
          end
        end)
      end)
      vim.defer_fn(close, 2000)
    end, 100)
  end
  function self:ready(port)
    self.port = tonumber(port)
    local key = vim.env.FZF_API_KEY
    self.key = key and not key:find("[%c]") and key or nil
    if self.pending and self.port then
      self:send(self.pending)
    end
  end
  function self:close()
    self.closed, self.pending = true, nil
    for socket in pairs(self.sockets) do
      if not socket:is_closing() then
        socket:close()
      end
    end
    self.sockets = {}
  end
  return self
end

return M
