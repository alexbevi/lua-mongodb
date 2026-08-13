local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime")

local M = {}

local DNS_PORT = 53
local DNS_QUERY_TIMEOUT = 10
local DNS_CLASS_IN = 1
local DNS_TYPE_SRV = 33
local DNS_TYPE_TXT = 16
local MAX_DNS_MESSAGE_SIZE = 65535

local function require_positive_number(name, value, level)
  if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
    error(name .. " must be a finite positive number", level or 3)
  end
end

local function protocol_error(message)
  return errors.new({
    category = errors.CATEGORY.PROTOCOL,
    details = { operation = "dns" },
    message = "malformed DNS response: " .. message,
  })
end

local function network_error(operation, reason)
  return errors.new({
    category = errors.CATEGORY.NETWORK,
    details = { operation = operation },
    message = "DNS " .. operation .. " failed: " .. tostring(reason),
  })
end

local function response_error(code)
  return errors.new({
    category = errors.CATEGORY.NETWORK,
    details = { operation = "dns", response_code = code },
    message = "DNS query failed with response code " .. tostring(code),
  })
end

local function encode_name(name)
  if type(name) ~= "string" or name == "" then
    error("DNS name must be a non-empty string", 3)
  end

  if name:sub(-1) == "." then
    name = name:sub(1, -2)
  end

  if name == "" or #name > 253 then
    error("DNS name must contain 1 through 253 bytes", 3)
  end

  local encoded = {}
  local label_count = 0

  for label in name:gmatch("[^.]+") do
    if #label > 63 then
      error("DNS labels must contain at most 63 bytes", 3)
    end

    label_count = label_count + 1
    encoded[#encoded + 1] = string.char(#label) .. label
  end

  if label_count == 0 or select(2, name:gsub("%.", "")) ~= label_count - 1 then
    error("DNS name must not contain empty labels", 3)
  end

  encoded[#encoded + 1] = "\0"
  local result = table.concat(encoded)

  if #result > 255 then
    error("encoded DNS name must contain at most 255 bytes", 3)
  end

  return result
end

local function decode_name(packet, position)
  local labels = {}
  local next_position
  local current = position
  local visited = {}
  local encoded_length = 1

  while true do
    local length = packet:byte(current)

    if length == nil then
      return nil, nil, "name extends beyond the message"
    end

    if length & 0xc0 == 0xc0 then
      local low = packet:byte(current + 1)

      if low == nil then
        return nil, nil, "compressed name pointer is incomplete"
      end

      local target = ((length & 0x3f) << 8) | low

      if target >= #packet then
        return nil, nil, "compressed name pointer is outside the message"
      end

      next_position = next_position or current + 2
      current = target + 1

      if visited[current] then
        return nil, nil, "compressed name pointer contains a loop"
      end

      visited[current] = true
    elseif length & 0xc0 ~= 0 then
      return nil, nil, "name label uses reserved length bits"
    elseif length == 0 then
      next_position = next_position or current + 1
      return table.concat(labels, "."), next_position
    else
      local last = current + length

      if last > #packet then
        return nil, nil, "name label extends beyond the message"
      end

      encoded_length = encoded_length + length + 1

      if encoded_length > 255 then
        return nil, nil, "decoded name exceeds 255 bytes"
      end

      labels[#labels + 1] = packet:sub(current + 1, last)
      current = last + 1
    end
  end
end

local function question_end(packet, position, expected_name, expected_type)
  local name, next_position, reason = decode_name(packet, position)

  if name == nil then
    return nil, reason
  end

  if next_position + 3 > #packet then
    return nil, "question is incomplete"
  end

  local record_type, class
  record_type, class, next_position = string.unpack(">I2I2", packet, next_position)

  if name:lower() ~= expected_name:lower()
      or record_type ~= expected_type or class ~= DNS_CLASS_IN then
    return nil, "question does not match the query"
  end

  return next_position
end

local function decode_srv(packet, position, length, ttl)
  if length < 7 or position + length - 1 > #packet then
    return nil, "SRV record data is incomplete"
  end

  local priority, weight, port, target_position = string.unpack(
    ">I2I2I2", packet, position
  )
  local target, next_position, reason = decode_name(packet, target_position)

  if target == nil then
    return nil, reason
  end

  if next_position ~= position + length then
    return nil, "SRV record length does not match its data"
  end

  return {
    port = port,
    priority = priority,
    target = target,
    ttl = ttl,
    weight = weight,
  }
end

local function decode_txt(packet, position, length, ttl)
  if position + length - 1 > #packet then
    return nil, "TXT record data is incomplete"
  end

  local strings = {}
  local limit = position + length

  while position < limit do
    local string_length = packet:byte(position)

    if string_length == nil or position + string_length >= limit then
      return nil, "TXT character string extends beyond its record"
    end

    strings[#strings + 1] = packet:sub(position + 1, position + string_length)
    position = position + string_length + 1
  end

  return { strings = strings, ttl = ttl }
end

local function decode_answer(packet, position, expected_type)
  local _, next_position, reason = decode_name(packet, position)

  if next_position == nil then
    return nil, nil, reason
  end

  if next_position + 9 > #packet then
    return nil, nil, "resource record header is incomplete"
  end

  local record_type, class, ttl, length
  record_type, class, ttl, length, next_position = string.unpack(
    ">I2I2I4I2", packet, next_position
  )

  if next_position + length - 1 > #packet then
    return nil, nil, "resource record data extends beyond the message"
  end

  local record

  if record_type == expected_type and class == DNS_CLASS_IN then
    if expected_type == DNS_TYPE_SRV then
      record, reason = decode_srv(packet, next_position, length, ttl)
    else
      record, reason = decode_txt(packet, next_position, length, ttl)
    end

    if record == nil then
      return nil, nil, reason
    end
  end

  return record, next_position + length
end

local function decode_response(packet, query_id, query_name, query_type)
  if type(packet) ~= "string" or #packet < 12 then
    return nil, protocol_error("header is incomplete")
  end

  local header = table.pack(string.unpack(">I2I2I2I2I2I2", packet))
  local response_id = header[1]
  local flags = header[2]
  local question_count = header[3]
  local answer_count = header[4]
  local position = header[7]

  if response_id ~= query_id then
    return nil, nil, "mismatch"
  end

  if flags & 0x8000 == 0 or flags & 0x7800 ~= 0 then
    return nil, protocol_error("header is not a standard query response")
  end

  if flags & 0x0200 ~= 0 then
    return nil, nil, "truncated"
  end

  if question_count ~= 1 then
    return nil, protocol_error("question count is not one")
  end

  local reason
  position, reason = question_end(packet, position, query_name, query_type)

  if position == nil then
    return nil, protocol_error(reason)
  end

  local response_code = flags & 0x000f

  if response_code == 3 then
    return {}
  end

  if response_code ~= 0 then
    return nil, response_error(response_code)
  end

  local records = {}

  for _ = 1, answer_count do
    local record
    record, position, reason = decode_answer(packet, position, query_type)

    if position == nil then
      return nil, protocol_error(reason)
    end

    if record ~= nil then
      records[#records + 1] = record
    end
  end

  return records
end

local function default_nameservers()
  local nameservers = {}
  local file = io.open("/etc/resolv.conf", "r")

  if file == nil then
    return nameservers
  end

  for line in file:lines() do
    local host = line:match("^%s*nameserver%s+([^%s#;]+)")

    if host ~= nil then
      nameservers[#nameservers + 1] = { host = host, port = DNS_PORT }
    end
  end

  file:close()
  return nameservers
end

local function normalize_nameservers(provided)
  if provided == nil then
    return default_nameservers()
  end

  if type(provided) ~= "table" then
    error("dns_nameservers must be an array", 3)
  end

  local nameservers = {}

  for index, value in ipairs(provided) do
    local host = value
    local port = DNS_PORT

    if type(value) == "table" then
      host = value.host
      port = value.port or DNS_PORT
    end

    if type(host) ~= "string" or host == "" then
      error("DNS nameserver host must be a non-empty string", 3)
    end

    if math.type(port) ~= "integer" or port < 1 or port > 65535 then
      error("DNS nameserver port must be an integer from 1 through 65535", 3)
    end

    nameservers[index] = { host = host, port = port }
  end

  for key in pairs(provided) do
    if math.type(key) ~= "integer" or key < 1 or key > #nameservers then
      error("dns_nameservers must be an array", 3)
    end
  end

  return nameservers
end

local function wait_timeout(owner, deadline, cancellation)
  local ok, err = runtime_contract.check(owner.runtime, deadline, cancellation)

  if not ok then
    return nil, err
  end

  local remaining = runtime_contract.remaining(owner.runtime, deadline)

  if cancellation ~= nil then
    remaining = math.min(remaining or math.huge, owner.poll_interval)
  end

  return remaining
end

local function retry_timeout(owner, reason, deadline, cancellation)
  if reason ~= "timeout" then
    return nil, network_error("I/O", reason)
  end

  local ok, err = runtime_contract.check(owner.runtime, deadline, cancellation)

  if not ok then
    return nil, err
  end

  return true
end

local function socket_factory(owner, server, transport)
  local ipv6 = server.host:find(":", 1, true) ~= nil
  local factory = owner.socket[transport .. (ipv6 and "6" or "")]
    or owner.socket[transport]

  if type(factory) ~= "function" then
    return nil, network_error("socket creation", transport .. " is unavailable")
  end

  local socket, reason = factory()

  if socket == nil then
    return nil, network_error("socket creation", reason)
  end

  return socket
end

local function read_exact(owner, socket, count, deadline, cancellation)
  local result = ""

  while #result < count do
    local timeout, err = wait_timeout(owner, deadline, cancellation)

    if timeout == nil then
      return nil, err
    end

    socket:settimeout(timeout)
    local data, reason, partial = socket:receive(count, result)

    if data ~= nil then
      result = data
    elseif partial ~= nil then
      result = partial
    end

    if data == nil then
      local retry
      retry, err = retry_timeout(owner, reason, deadline, cancellation)

      if not retry then
        return nil, err
      end
    end
  end

  return result
end

local function write_all(owner, socket, data, deadline, cancellation)
  local last = 0

  while last < #data do
    local timeout, err = wait_timeout(owner, deadline, cancellation)

    if timeout == nil then
      return nil, err
    end

    socket:settimeout(timeout)
    local sent, reason, sent_through = socket:send(data, last + 1)

    if sent ~= nil then
      last = sent
    elseif sent_through ~= nil and sent_through > last then
      last = sent_through
    end

    if sent == nil then
      local retry
      retry, err = retry_timeout(owner, reason, deadline, cancellation)

      if not retry then
        return nil, err
      end
    end
  end

  return true
end

local function tcp_query(
  owner, server, query, query_id, query_name, query_type, deadline, cancellation
)
  local raw, err = socket_factory(owner, server, "tcp")

  if raw == nil then
    return nil, err
  end

  local socket = owner.copas.wrap(raw)
  local connected

  while not connected do
    local timeout
    timeout, err = wait_timeout(owner, deadline, cancellation)

    if timeout == nil then
      raw:close()
      return nil, err
    end

    socket:settimeout(timeout)
    local reason
    connected, reason = socket:connect(server.host, server.port)

    if not connected then
      local retry
      retry, err = retry_timeout(owner, reason, deadline, cancellation)

      if not retry then
        raw:close()
        return nil, err
      end
    end
  end

  local frame = string.pack(">I2", #query) .. query
  local ok
  ok, err = write_all(owner, socket, frame, deadline, cancellation)

  if not ok then
    raw:close()
    return nil, err
  end

  local size_bytes
  size_bytes, err = read_exact(owner, socket, 2, deadline, cancellation)

  if size_bytes == nil then
    raw:close()
    return nil, err
  end

  local size = string.unpack(">I2", size_bytes)
  local response
  response, err = read_exact(owner, socket, size, deadline, cancellation)
  raw:close()

  if response == nil then
    return nil, err
  end

  local records, decode_err, status = decode_response(
    response, query_id, query_name, query_type
  )

  if status ~= nil then
    return nil, protocol_error("invalid TCP response status " .. status)
  end

  return records, decode_err
end

local function udp_query(
  owner, server, query, query_id, query_name, query_type, deadline, cancellation
)
  local raw, err = socket_factory(owner, server, "udp")

  if raw == nil then
    return nil, err
  end

  local socket = owner.copas.wrap(raw)
  local sent, reason = socket:sendto(query, server.host, server.port)

  if sent == nil then
    raw:close()
    return nil, network_error("send", reason)
  end

  while true do
    local timeout
    timeout, err = wait_timeout(owner, deadline, cancellation)

    if timeout == nil then
      raw:close()
      return nil, err
    end

    socket:settimeout(timeout)
    local response, peer_host, peer_port = socket:receivefrom(MAX_DNS_MESSAGE_SIZE)

    if response == nil then
      local retry
      retry, err = retry_timeout(owner, peer_host, deadline, cancellation)

      if not retry then
        raw:close()
        return nil, err
      end
    elseif peer_host == server.host and peer_port == server.port then
      local records, decode_err, status = decode_response(
        response, query_id, query_name, query_type
      )

      if status == "truncated" then
        raw:close()
        return tcp_query(
          owner, server, query, query_id, query_name, query_type,
          deadline, cancellation
        )
      end

      if status ~= "mismatch" then
        raw:close()
        return records, decode_err
      end
    end
  end
end

local function query(owner, name, record_type, deadline, cancellation)
  local ok, err = runtime_contract.check(owner.runtime, deadline, cancellation)

  if not ok then
    return nil, err
  end

  if #owner.nameservers == 0 then
    return nil, network_error("configuration", "no DNS nameserver is configured")
  end

  local query_deadline = owner.runtime.clock:now() + owner.query_timeout

  if deadline ~= nil then
    query_deadline = math.min(query_deadline, deadline)
  end

  local entropy
  entropy, err = owner.runtime.entropy:bytes(2)

  if entropy == nil then
    return nil, err
  end

  local query_id = string.unpack(">I2", entropy)
  local query_name = encode_name(name)
  local packet = string.pack(">I2I2I2I2I2I2", query_id, 0x0100, 1, 0, 0, 0)
    .. query_name .. string.pack(">I2I2", record_type, DNS_CLASS_IN)
  local last_error

  for index, server in ipairs(owner.nameservers) do
    local remaining = runtime_contract.remaining(owner.runtime, query_deadline)
    local server_count = #owner.nameservers - index + 1
    local server_deadline = owner.runtime.clock:now() + remaining / server_count
    local records
    records, last_error = udp_query(
      owner, server, packet, query_id, name, record_type,
      server_deadline, cancellation
    )

    if records ~= nil then
      return records
    end

    if errors.is(last_error, errors.CATEGORY.CANCELLED) then
      return nil, last_error
    end
  end

  return nil, last_error or runtime_contract.timeout_error()
end

function M.new(runtime, options)
  options = options or {}

  local owner = {
    copas = assert(options.copas),
    nameservers = normalize_nameservers(options.nameservers),
    poll_interval = options.poll_interval or 0.05,
    query_timeout = options.query_timeout or DNS_QUERY_TIMEOUT,
    runtime = runtime,
    socket = options.socket or require("socket"),
  }

  require_positive_number("DNS poll interval", owner.poll_interval, 2)
  require_positive_number("DNS query timeout", owner.query_timeout, 2)

  return {
    resolve_srv = function(_, name, deadline, cancellation)
      return query(owner, name, DNS_TYPE_SRV, deadline, cancellation)
    end,
    resolve_txt = function(_, name, deadline, cancellation)
      return query(owner, name, DNS_TYPE_TXT, deadline, cancellation)
    end,
  }
end

return M
