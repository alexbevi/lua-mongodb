local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime")

local M = {}

local SOCKET_METHODS = {}
local SOCKET_METATABLE = {
  __index = SOCKET_METHODS,
  __metatable = "mongodb.copas_socket",
}

local function network_error(operation, reason)
  return errors.new({
    category = errors.CATEGORY.NETWORK,
    details = { operation = operation },
    message = "socket " .. operation .. " failed: " .. tostring(reason),
  })
end

local function wait_timeout(owner, deadline, token)
  local ok, err = runtime_contract.check(owner.runtime, deadline, token)

  if not ok then
    return nil, err
  end

  local remaining = runtime_contract.remaining(owner.runtime, deadline)

  if token then
    remaining = math.min(remaining or math.huge, owner.poll_interval)
  end

  return remaining
end

local function retry_timeout(owner, operation, reason, deadline, token)
  if reason ~= "timeout" then
    return nil, network_error(operation, reason)
  end

  local ok, err = runtime_contract.check(owner.runtime, deadline, token)

  if not ok then
    return nil, err
  end

  if token then
    return true
  end

  return nil, errors.new({
    category = errors.CATEGORY.TIMEOUT,
    message = "socket " .. operation .. " timed out",
  })
end

function SOCKET_METHODS:read_some(max_bytes, deadline, token)
  if math.type(max_bytes) ~= "integer" or max_bytes <= 0 then
    error("max_bytes must be a positive integer", 2)
  end

  while true do
    local timeout, err = wait_timeout(self._owner, deadline, token)

    if timeout == nil and err then
      return nil, err
    end

    self._socket:settimeout(timeout)
    local data, reason, partial = self._socket:receivepartial(max_bytes)

    if data then
      return data
    end

    if partial and partial ~= "" then
      return partial
    end

    if reason == "closed" then
      return ""
    end

    local retry
    retry, err = retry_timeout(self._owner, "read", reason, deadline, token)

    if not retry then
      return nil, err
    end
  end
end

function SOCKET_METHODS:write_some(data, deadline, token)
  if type(data) ~= "string" then
    error("socket data must be a string", 2)
  end

  while true do
    local timeout, err = wait_timeout(self._owner, deadline, token)

    if timeout == nil and err then
      return nil, err
    end

    self._socket:settimeout(timeout)
    local sent, reason, last = self._socket:send(data)

    if sent then
      return math.tointeger(sent) or sent
    end

    if last and last > 0 then
      return math.tointeger(last) or last
    end

    local retry
    retry, err = retry_timeout(self._owner, "write", reason, deadline, token)

    if not retry then
      return nil, err
    end
  end
end

function SOCKET_METHODS:close()
  if self._closed then
    return false
  end

  self._closed = true
  self._socket:close()
  return true
end

function SOCKET_METHODS:is_closed()
  return self._closed
end

local function wrap(owner, socket)
  return setmetatable({
    _closed = false,
    _owner = owner,
    _socket = socket,
  }, SOCKET_METATABLE)
end

function M.new(runtime, options)
  options = options or {}

  local owner = {
    copas = assert(options.copas),
    poll_interval = options.poll_interval or 0.05,
    runtime = runtime,
    socket = options.socket or require("socket"),
  }

  return {
    connect = function(_, host, port, socket_options, deadline, token)
      if type(host) ~= "string" or host == "" then
        error("socket host must be a non-empty string", 2)
      end

      if math.type(port) ~= "integer" or port < 1 or port > 65535 then
        error("socket port must be an integer from 1 through 65535", 2)
      end

      socket_options = socket_options or {}

      local raw, reason = owner.socket.tcp()

      if not raw then
        return nil, network_error("creation", reason)
      end

      if socket_options.tcp_nodelay ~= false then
        raw:setoption("tcp-nodelay", true)
      end

      local socket = owner.copas.wrap(raw)

      while true do
        local timeout, err = wait_timeout(owner, deadline, token)

        if timeout == nil and err then
          raw:close()
          return nil, err
        end

        socket:settimeout(timeout)
        local connected
        connected, reason = socket:connect(host, port)

        if connected then
          return wrap(owner, socket)
        end

        local retry
        retry, err = retry_timeout(owner, "connect", reason, deadline, token)

        if not retry then
          raw:close()
          return nil, err
        end
      end
    end,
  }
end

return M
