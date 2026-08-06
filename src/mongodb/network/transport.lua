local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime")

local M = {}

local CONNECTION_METHODS = {}
local CONNECTION_METATABLE = {
  __index = CONNECTION_METHODS,
  __metatable = "mongodb.network.connection",
  __newindex = function()
    error("network connections are immutable", 2)
  end,
}

local function network_error(message, details)
  return errors.new({
    category = errors.CATEGORY.NETWORK,
    details = details,
    message = message,
  })
end

local function require_length(name, value)
  if math.type(value) ~= "integer" or value < 0 then
    error(name .. " must be a non-negative integer", 3)
  end
end

local function check_open(connection)
  if connection._closed then
    return nil, network_error("connection is closed")
  end

  return true
end

function CONNECTION_METHODS:read_exact(length, deadline, cancellation)
  require_length("read length", length)

  local open, open_err = check_open(self)

  if not open then
    return nil, open_err
  end

  local chunks = {}
  local received = 0

  while received < length do
    local ok, err = runtime_contract.check(self._runtime, deadline, cancellation)

    if not ok then
      return nil, err
    end

    local chunk
    chunk, err = self._socket:read_some(length - received, deadline, cancellation)

    if not chunk then
      return nil, err
    end

    if chunk == "" then
      return nil, network_error("connection closed before the requested bytes arrived", {
        expected = length,
        received = received,
      })
    end

    if #chunk > length - received then
      return nil, network_error("runtime socket returned more bytes than requested")
    end

    chunks[#chunks + 1] = chunk
    received = received + #chunk
  end

  return table.concat(chunks)
end

function CONNECTION_METHODS:read_frame(max_message_size, deadline, cancellation)
  require_length("max_message_size", max_message_size)

  if max_message_size < 16 then
    error("max_message_size must be at least 16", 2)
  end

  local header, err = self:read_exact(4, deadline, cancellation)

  if not header then
    return nil, err
  end

  local message_size = string.unpack("<i4", header)

  if message_size < 16 or message_size > max_message_size then
    return nil, errors.new({
      category = errors.CATEGORY.PROTOCOL,
      details = { max_message_size = max_message_size, message_size = message_size },
      message = "wire message length is outside the permitted range",
    })
  end

  local remainder
  remainder, err = self:read_exact(message_size - 4, deadline, cancellation)

  if not remainder then
    return nil, err
  end

  return header .. remainder
end

function CONNECTION_METHODS:write_all(data, deadline, cancellation)
  if type(data) ~= "string" then
    error("socket data must be a string", 2)
  end

  local open, open_err = check_open(self)

  if not open then
    return nil, open_err
  end

  local position = 1

  while position <= #data do
    local ok, err = runtime_contract.check(self._runtime, deadline, cancellation)

    if not ok then
      return nil, err
    end

    local written
    written, err = self._socket:write_some(data:sub(position), deadline, cancellation)

    if written == nil then
      return nil, err
    end

    if math.type(written) ~= "integer" or written <= 0 or written > #data - position + 1 then
      return nil, network_error("runtime socket returned an invalid write count")
    end

    position = position + written
  end

  return true
end

function CONNECTION_METHODS:is_closed()
  return self._closed
end

function CONNECTION_METHODS:close()
  if self._closed then
    return false
  end

  self._closed = true
  self._socket:close()
  return true
end

function M.connect(runtime, host, port, options)
  runtime_contract.validate(runtime)
  options = options or {}

  if type(options) ~= "table" then
    error("transport options must be a table", 2)
  end

  local deadline = options.deadline
  local cancellation = options.cancellation
  local socket, err = runtime.socket:connect(
    host,
    port,
    options.socket_options or {},
    deadline,
    cancellation
  )

  if not socket then
    return nil, err
  end

  if options.tls then
    local wrapped
    wrapped, err = runtime.tls:wrap(
      socket,
      options.tls,
      deadline,
      cancellation
    )

    if not wrapped then
      socket:close()
      return nil, err
    end

    socket = wrapped
  end

  return setmetatable({
    _closed = false,
    _runtime = runtime,
    _socket = socket,
  }, CONNECTION_METATABLE)
end

return M
