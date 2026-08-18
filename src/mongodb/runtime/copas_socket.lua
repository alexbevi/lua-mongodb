local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime.contract")

local M = {}

local SUBJECT_ALT_NAME_OID = "2.5.29.17"

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

local function interrupt_on_cancel(socket, token)
  if token == nil then
    return function() end
  end

  return token:on_cancel(function()
    socket:close()
  end)
end

local function parse_ipv4(value)
  local parts = {}

  for part in value:gmatch("[^.]+") do
    if not part:match("^%d+$") or #part > 1 and part:sub(1, 1) == "0" then
      return nil
    end

    local number = tonumber(part)

    if not number or number > 255 then
      return nil
    end

    parts[#parts + 1] = number
  end

  if #parts ~= 4 or select(2, value:gsub("%.", "")) ~= 3 then
    return nil
  end

  return string.char(table.unpack(parts))
end

local function ipv6_groups(section, allow_ipv4)
  local groups = {}
  local saw_ipv4 = false

  if section == "" then
    return groups
  end

  for part in section:gmatch("[^:]+") do
    if saw_ipv4 then
      return nil
    end

    if part:find(".", 1, true) then
      if not allow_ipv4 then
        return nil
      end

      local ipv4 = parse_ipv4(part)

      if not ipv4 then
        return nil
      end

      groups[#groups + 1] = ipv4:byte(1) * 256 + ipv4:byte(2)
      groups[#groups + 1] = ipv4:byte(3) * 256 + ipv4:byte(4)
      saw_ipv4 = true
    else
      if not part:match("^[0-9a-fA-F]+$") or #part > 4 then
        return nil
      end

      groups[#groups + 1] = tonumber(part, 16)
    end
  end

  return groups
end

local function parse_ipv6(value)
  value = value:match("^%[(.*)%]$") or value

  if not value:find(":", 1, true) or value:find("%%", 1, true) then
    return nil
  end

  local compression = value:find("::", 1, true)

  if compression and value:find("::", compression + 2, true) then
    return nil
  end

  local left_text = compression and value:sub(1, compression - 1) or value
  local right_text = compression and value:sub(compression + 2) or ""
  local left = ipv6_groups(left_text, right_text == "")
  local right = ipv6_groups(right_text, true)

  if not left or not right then
    return nil
  end

  local missing = 8 - #left - #right

  if compression and missing < 1 or not compression and missing ~= 0 then
    return nil
  end

  local groups = {}

  for _, group in ipairs(left) do
    groups[#groups + 1] = group
  end

  for _ = 1, missing do
    groups[#groups + 1] = 0
  end

  for _, group in ipairs(right) do
    groups[#groups + 1] = group
  end

  local bytes = {}

  for index, group in ipairs(groups) do
    bytes[index] = string.pack(">I2", group)
  end

  return table.concat(bytes)
end

local function ip_bytes(value)
  return parse_ipv4(value) or parse_ipv6(value)
end

local function dns_matches(pattern, hostname)
  pattern = pattern:lower()
  hostname = hostname:lower()

  if not pattern:find("*", 1, true) then
    return pattern == hostname
  end

  local suffix = pattern:match("^%*%.([^*]+)$")

  if not suffix or suffix:find(".", 1, true) == nil then
    return false
  end

  local prefix = hostname:sub(1, #hostname - #suffix - 1)
  return hostname:sub(-#suffix - 1) == "." .. suffix
    and prefix ~= "" and not prefix:find(".", 1, true)
end

local function certificate_matches(certificate, hostname)
  local target_ip = ip_bytes(hostname)
  local extensions = certificate:extensions()
  local alternatives = extensions[SUBJECT_ALT_NAME_OID] or {}

  if target_ip then
    for _, candidate in ipairs(alternatives.iPAddress or {}) do
      if ip_bytes(candidate) == target_ip then
        return true
      end
    end

    return false
  end

  local dns_names = alternatives.dNSName or {}

  if #dns_names > 0 then
    for _, candidate in ipairs(dns_names) do
      if dns_matches(candidate, hostname) then
        return true
      end
    end

    return false
  end

  for _, name in ipairs(certificate:subject()) do
    if name.name == "commonName" and dns_matches(name.value, hostname) then
      return true
    end
  end

  return false
end

local function tls_error(message)
  return errors.new({
    category = errors.CATEGORY.NETWORK,
    message = message,
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
    local unsubscribe = interrupt_on_cancel(self, token)
    local data, reason, partial = self._socket:receivepartial(max_bytes)

    unsubscribe()
    local ok
    ok, err = runtime_contract.check(self._owner.runtime, deadline, token)

    if not ok then
      return nil, err
    end

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

function M.wrap_tls(socket, context, hostname, check_hostname, deadline, token)
  if getmetatable(socket) ~= "mongodb.copas_socket" then
    error("LuaSec can only wrap a Copas runtime socket", 2)
  end

  if socket._closed then
    return nil, network_error("TLS handshake", "socket is closed")
  end

  local owner = socket._owner
  local target = socket._socket
  local prepared = false
  local target_is_ip = ip_bytes(hostname) ~= nil

  while true do
    local timeout, err = wait_timeout(owner, deadline, token)

    if timeout == nil and err then
      return nil, err
    end

    target:settimeout(timeout)
    local outcome = table.pack(pcall(function()
      if not prepared then
        target.ssl_params.wrap = context

        if not target_is_ip then
          target.ssl_params.sni = { names = hostname, strict = true }
          target:sni()
        end

        prepared = true
      end

      return target:dohandshake(context)
    end))

    if outcome[1] and outcome[2] then
      break
    end

    local checked, check_err = runtime_contract.check(owner.runtime, deadline, token)

    if not checked then
      return nil, check_err
    end

    local reason = outcome[1] and outcome[3] or outcome[2]

    local timed_out = tostring(reason):find("timeout", 1, true) ~= nil

    if not (token and timed_out) then
      if timed_out then
        return nil, runtime_contract.timeout_error()
      end

      return nil, tls_error("TLS handshake failed")
    end
  end

  if check_hostname then
    local matched, matches = pcall(function()
      local certificate = target.socket:getpeercertificate()
      return certificate and certificate_matches(certificate, hostname)
    end)

    if not matched or not matches then
      return nil, tls_error("TLS certificate does not match the server name")
    end
  end

  return socket
end

return M
