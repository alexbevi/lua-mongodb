local errors = require("mongodb.error")
local transport = require("mongodb.network.transport")

local M = {}

local DEFAULT_MAX_RESPONSE_BYTES = 1024 * 1024
local MAX_HEADER_BYTES = 64 * 1024

local function protocol_error(message)
  return errors.new({
    category = errors.CATEGORY.PROTOCOL,
    message = message,
  })
end

local function parse_port(value)
  if value == nil or value == "" or not value:match("^%d+$") then
    return nil
  end

  local port = tonumber(value)

  if port < 1 or port > 65535 then
    return nil
  end

  return port
end

local function parse_url(url)
  if type(url) ~= "string" or url == "" then
    error("HTTP URL must be a non-empty string", 3)
  end

  local scheme, remainder = url:match("^(https?)://(.+)$")

  if scheme == nil then
    return nil, protocol_error("HTTP URL must use http or https")
  end

  local separator = remainder:find("[/?]")
  local authority = separator and remainder:sub(1, separator - 1) or remainder
  local target = separator and remainder:sub(separator) or "/"

  if target:sub(1, 1) == "?" then
    target = "/" .. target
  end

  if authority == ""
      or authority:find("@", 1, true)
      or authority:find("#", 1, true)
      or authority:find("[%c%s]")
      or target:find("#", 1, true)
      or target:find("[%c%s]")
  then
    return nil, protocol_error("HTTP URL is malformed")
  end

  local host
  local port
  local host_header

  if authority:sub(1, 1) == "[" then
    local close = authority:find("]", 2, true)

    if close == nil then
      return nil, protocol_error("HTTP URL has an invalid IPv6 host")
    end

    host = authority:sub(2, close - 1)
    local suffix = authority:sub(close + 1)

    if host == "" or suffix ~= "" and suffix:sub(1, 1) ~= ":" then
      return nil, protocol_error("HTTP URL has an invalid authority")
    end

    if suffix ~= "" then
      port = parse_port(suffix:sub(2))

      if port == nil then
        return nil, protocol_error("HTTP URL has an invalid port")
      end
    end

    host_header = "[" .. host .. "]"
  else
    local colon = authority:find(":", 1, true)

    if colon ~= nil and authority:find(":", colon + 1, true) then
      return nil, protocol_error("HTTP IPv6 hosts must use brackets")
    end

    if colon ~= nil then
      host = authority:sub(1, colon - 1)
      port = parse_port(authority:sub(colon + 1))

      if port == nil then
        return nil, protocol_error("HTTP URL has an invalid port")
      end
    else
      host = authority
    end

    if host == "" then
      return nil, protocol_error("HTTP URL has an empty host")
    end

    host_header = host
  end

  port = port or (scheme == "https" and 443 or 80)

  if port ~= (scheme == "https" and 443 or 80) then
    host_header = host_header .. ":" .. port
  end

  return {
    host = host,
    host_header = host_header,
    port = port,
    scheme = scheme,
    target = target,
  }
end

local function validate_headers(headers)
  headers = headers or {}

  if type(headers) ~= "table" then
    error("HTTP headers must be a table", 3)
  end

  local result = {}

  for name, value in pairs(headers) do
    if type(name) ~= "string"
        or name == ""
        or not name:match("^[!#$%%&'*+.^_`|~%w-]+$")
        or type(value) ~= "string"
        or value:find("[\r\n]")
    then
      error("HTTP header names and values must be valid strings", 3)
    end

    local lowered = name:lower()

    if lowered == "host"
        or lowered == "connection"
        or lowered == "content-length"
    then
      error("HTTP transport owns host, connection, and content-length headers", 3)
    end

    result[#result + 1] = { name = lowered, value = value }
  end

  table.sort(result, function(left, right)
    return left.name < right.name
  end)
  return result
end

local function request_bytes(request, parsed)
  if type(request) ~= "table" then
    error("HTTP request must be a table", 3)
  end

  local method = request.method or "GET"
  local body = request.body or ""

  if type(method) ~= "string"
      or not method:match("^[A-Z]+$")
      or type(body) ~= "string"
  then
    error("HTTP method and body must be strings", 3)
  end

  local lines = {
    method .. " " .. parsed.target .. " HTTP/1.1",
    "host: " .. parsed.host_header,
    "connection: close",
    "content-length: " .. #body,
  }

  for _, header in ipairs(validate_headers(request.headers)) do
    lines[#lines + 1] = header.name .. ": " .. header.value
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  return table.concat(lines, "\r\n")
end

local function new_reader(connection, deadline, cancellation)
  return {
    buffer = "",
    cancellation = cancellation,
    connection = connection,
    deadline = deadline,
    eof = false,
  }
end

local function fill(reader)
  if reader.eof then
    return false
  end

  local chunk, err = reader.connection:read_some(
    4096,
    reader.deadline,
    reader.cancellation
  )

  if chunk == nil then
    return nil, err
  end

  if chunk == "" then
    reader.eof = true
    return false
  end

  reader.buffer = reader.buffer .. chunk
  return true
end

local function read_until(reader, delimiter, limit)
  while true do
    local position = reader.buffer:find(delimiter, 1, true)

    if position ~= nil then
      if position - 1 > limit then
        return nil, protocol_error("HTTP response section exceeds its size limit")
      end

      local result = reader.buffer:sub(1, position - 1)

      reader.buffer = reader.buffer:sub(position + #delimiter)
      return result
    end

    if #reader.buffer > limit then
      return nil, protocol_error("HTTP response section exceeds its size limit")
    end

    local filled, err = fill(reader)

    if filled == nil then
      return nil, err
    end

    if not filled then
      return nil, protocol_error("HTTP response ended before its delimiter")
    end
  end
end

local function read_exact(reader, length)
  while #reader.buffer < length do
    local filled, err = fill(reader)

    if filled == nil then
      return nil, err
    end

    if not filled then
      return nil, protocol_error("HTTP response body ended early")
    end
  end

  local result = reader.buffer:sub(1, length)

  reader.buffer = reader.buffer:sub(length + 1)
  return result
end

local function parse_response_head(value)
  local lines = {}

  for line in (value .. "\r\n"):gmatch("(.-)\r\n") do
    lines[#lines + 1] = line
  end

  local status = lines[1] and lines[1]:match("^HTTP/%d+%.%d+ (%d%d%d)[ 	]?.*$")

  if status == nil then
    return nil, protocol_error("HTTP response has an invalid status line")
  end

  local headers = {}

  for index = 2, #lines do
    local line = lines[index]

    if line:match("^[ 	]") then
      return nil, protocol_error("HTTP response uses folded headers")
    end

    local name, header_value = line:match("^([^:]+):[ 	]*(.-)[ 	]*$")

    if name == nil or not name:match("^[!#$%%&'*+.^_`|~%w-]+$") then
      return nil, protocol_error("HTTP response has a malformed header")
    end

    name = name:lower()

    if headers[name] ~= nil then
      if name == "content-length" and headers[name] ~= header_value then
        return nil, protocol_error("HTTP response has conflicting content lengths")
      end

      headers[name] = headers[name] .. "," .. header_value
    else
      headers[name] = header_value
    end
  end

  return {
    headers = headers,
    status = tonumber(status),
  }
end

local function read_chunked(reader, max_bytes)
  local chunks = {}
  local total = 0

  while true do
    local line, err = read_until(reader, "\r\n", 8192)

    if line == nil then
      return nil, err
    end

    local size_text, extension = line:match("^([0-9a-fA-F]+)(.*)$")

    if size_text == nil
        or extension ~= "" and extension:sub(1, 1) ~= ";"
    then
      return nil, protocol_error("HTTP chunk has an invalid size")
    end

    local size = tonumber(size_text, 16)

    if size == 0 then
      local trailer_bytes = 0

      while true do
        local trailer

        trailer, err = read_until(reader, "\r\n", MAX_HEADER_BYTES)

        if trailer == nil then
          return nil, err
        end

        if trailer == "" then
          return table.concat(chunks)
        end

        trailer_bytes = trailer_bytes + #trailer + 2

        if trailer_bytes > MAX_HEADER_BYTES then
          return nil, protocol_error("HTTP trailers exceed their size limit")
        end

        if trailer:match("^[ \t]")
            or not trailer:match("^[!#$%%&'*+.^_`|~%w-]+:[ \t]*.*$")
        then
          return nil, protocol_error("HTTP response has a malformed trailer")
        end
      end
    end

    total = total + size

    if total > max_bytes then
      return nil, protocol_error("HTTP response body exceeds its size limit")
    end

    local chunk

    chunk, err = read_exact(reader, size)

    if chunk == nil then
      return nil, err
    end

    local terminator

    terminator, err = read_exact(reader, 2)

    if terminator == nil then
      return nil, err
    end

    if terminator ~= "\r\n" then
      return nil, protocol_error("HTTP chunk is missing its terminator")
    end

    chunks[#chunks + 1] = chunk
  end
end

local function read_to_eof(reader, max_bytes)
  local chunks = {}
  local total = 0

  if reader.buffer ~= "" then
    chunks[1] = reader.buffer
    total = #reader.buffer
    reader.buffer = ""
  end

  while not reader.eof do
    local filled, err = fill(reader)

    if filled == nil then
      return nil, err
    end

    if filled then
      total = total + #reader.buffer

      if total > max_bytes then
        return nil, protocol_error("HTTP response body exceeds its size limit")
      end

      chunks[#chunks + 1] = reader.buffer
      reader.buffer = ""
    end
  end

  if total > max_bytes then
    return nil, protocol_error("HTTP response body exceeds its size limit")
  end

  return table.concat(chunks)
end

local function read_body(reader, headers, max_bytes)
  local transfer_encoding = headers["transfer-encoding"]
  local content_length = headers["content-length"]

  if transfer_encoding ~= nil and content_length ~= nil then
    return nil, protocol_error("HTTP response has ambiguous body framing")
  end

  if transfer_encoding ~= nil then
    if transfer_encoding:lower() ~= "chunked" then
      return nil, protocol_error("HTTP response uses an unsupported transfer encoding")
    end

    return read_chunked(reader, max_bytes)
  end

  if content_length ~= nil then
    if not content_length:match("^%d+$") then
      return nil, protocol_error("HTTP response has an invalid content length")
    end

    local length = tonumber(content_length)

    if length > max_bytes then
      return nil, protocol_error("HTTP response body exceeds its size limit")
    end

    return read_exact(reader, length)
  end

  return read_to_eof(reader, max_bytes)
end

local METHODS = {}

function METHODS:request(request, deadline, cancellation)
  if type(request) ~= "table" then
    error("HTTP request must be a table", 2)
  end

  local parsed, err = parse_url(request.url)

  if parsed == nil then
    return nil, err
  end

  local max_bytes = request.max_response_bytes or DEFAULT_MAX_RESPONSE_BYTES

  if math.type(max_bytes) ~= "integer" or max_bytes <= 0 then
    error("HTTP maximum response size must be a positive integer", 2)
  end

  local connection

  connection, err = transport.connect(self._runtime, parsed.host, parsed.port, {
    cancellation = cancellation,
    deadline = deadline,
    tls = parsed.scheme == "https" and { server_name = parsed.host } or nil,
  })

  if connection == nil then
    return nil, err
  end

  local written

  written, err = connection:write_all(
    request_bytes(request, parsed),
    deadline,
    cancellation
  )

  if not written then
    connection:close()
    return nil, err
  end

  local reader = new_reader(connection, deadline, cancellation)
  local head

  head, err = read_until(reader, "\r\n\r\n", MAX_HEADER_BYTES)

  if head == nil then
    connection:close()
    return nil, err
  end

  local response

  response, err = parse_response_head(head)

  if response == nil then
    connection:close()
    return nil, err
  end

  response.body, err = read_body(reader, response.headers, max_bytes)
  connection:close()

  if response.body == nil then
    return nil, err
  end

  return response
end

function M.new(runtime)
  if type(runtime) ~= "table" then
    error("HTTP runtime requires a runtime table", 2)
  end

  return setmetatable({ _runtime = runtime }, { __index = METHODS })
end

return M
