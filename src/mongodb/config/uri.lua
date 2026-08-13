local errors = require("mongodb.error")

local M = {}

local function parse_error(message, component)
  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    message = message,
    details = { component = component },
  })
end

local function valid_utf8(value)
  return utf8.len(value) ~= nil
end

local function percent_decode(value, plus_as_space, component)
  local output = {}
  local index = 1

  while index <= #value do
    local byte = value:sub(index, index)

    if byte == "%" then
      local encoded = value:sub(index + 1, index + 2)

      if #encoded ~= 2 or not encoded:match("^[0-9a-fA-F][0-9a-fA-F]$") then
        return parse_error("invalid percent escape in MongoDB URI", component)
      end

      output[#output + 1] = string.char(tonumber(encoded, 16))
      index = index + 3
    elseif byte == "+" and plus_as_space then
      output[#output + 1] = " "
      index = index + 1
    else
      output[#output + 1] = byte
      index = index + 1
    end
  end

  local decoded = table.concat(output)

  if not valid_utf8(decoded) then
    return parse_error("percent-decoded MongoDB URI component is not UTF-8", component)
  end

  return decoded
end

local function parse_port(value)
  if value == "" or not value:match("^%d+$") then
    return parse_error("MongoDB URI port must contain only digits", "port")
  end

  local port = tonumber(value)

  if port < 1 or port > 65535 then
    return parse_error("MongoDB URI port must be between 1 and 65535", "port")
  end

  return port
end

local function parse_host(entity)
  if entity == "" then
    return parse_error("MongoDB URI contains an empty host", "host")
  end

  local decoded, decode_err = percent_decode(entity, false, "host")

  if not decoded then
    return nil, decode_err
  end

  if decoded:find("/", 1, true) and decoded:sub(-5) == ".sock" then
    return { host = decoded, type = "unix" }
  end

  if entity:sub(1, 1) == "[" then
    local close = entity:find("]", 2, true)

    if not close then
      return parse_error("MongoDB URI IPv6 literal is missing a closing bracket", "host")
    end

    local host = entity:sub(2, close - 1)
    local suffix = entity:sub(close + 1)

    if host == "" or host:find("[", 1, true) or host:find("]", 1, true) then
      return parse_error("MongoDB URI contains an invalid IPv6 literal", "host")
    end

    local result = { host = host:lower(), type = "ip_literal" }

    if suffix ~= "" then
      if suffix:sub(1, 1) ~= ":" then
        return parse_error("MongoDB URI has data after an IPv6 literal", "host")
      end

      local port, port_err = parse_port(suffix:sub(2))

      if not port then
        return nil, port_err
      end

      result.port = port
    end

    return result
  end

  local first_colon = entity:find(":", 1, true)
  local result = { type = "hostname" }

  if first_colon then
    if entity:find(":", first_colon + 1, true) then
      return parse_error("MongoDB URI IPv6 literals must be enclosed in brackets", "host")
    end

    local host = entity:sub(1, first_colon - 1)
    local port, port_err = parse_port(entity:sub(first_colon + 1))

    if host == "" then
      return parse_error("MongoDB URI contains an empty host", "host")
    end

    if not port then
      return nil, port_err
    end

    result.host = host:lower()
    result.port = port
  else
    result.host = entity:lower()
  end

  if result.host == "" or result.host:find("/", 1, true) then
    return parse_error("MongoDB URI contains an invalid host", "host")
  end

  if result.host:match("^%d+%.%d+%.%d+%.%d+$") then
    local ipv4 = true

    for part in result.host:gmatch("%d+") do
      if tonumber(part) > 255 then
        ipv4 = false
      end
    end

    if ipv4 then
      result.type = "ipv4"
    end
  end

  return result
end

local function parse_hosts(value)
  local hosts = {}
  local start = 1

  while true do
    local comma = value:find(",", start, true)
    local entity = comma and value:sub(start, comma - 1) or value:sub(start)
    local host, err = parse_host(entity)

    if not host then
      return nil, err
    end

    hosts[#hosts + 1] = host

    if not comma then
      break
    end

    start = comma + 1
  end

  return hosts
end

local function parse_userinfo(value)
  if value == "" or value:find("@", 1, true) then
    return parse_error(
      "MongoDB URI username is invalid; reserved characters must be escaped",
      "userinfo"
    )
  end

  local colon = value:find(":", 1, true)

  if colon and value:find(":", colon + 1, true) then
    return parse_error("MongoDB URI credentials contain an unescaped colon", "userinfo")
  end

  local raw_username = colon and value:sub(1, colon - 1) or value

  if raw_username == "" then
    return parse_error("MongoDB URI username cannot be empty", "userinfo")
  end

  local username, username_err = percent_decode(raw_username, false, "userinfo")

  if not username then
    return nil, username_err
  end

  local result = { username = username }

  if colon then
    local password, password_err = percent_decode(value:sub(colon + 1), false, "userinfo")

    if not password then
      return nil, password_err
    end

    result.password = password
  end

  return result
end

local function parse_options(value)
  local options = {}
  local seen = {}
  local warnings = {}

  if value == nil or value == "" then
    return options, warnings
  end

  local start = 1

  while true do
    local separator = value:find("[&;]", start)
    local pair = separator and value:sub(start, separator - 1) or value:sub(start)
    local equals = pair:find("=", 1, true)

    if not equals then
      return parse_error("MongoDB URI option must contain '='", "options")
    end

    local key, key_err = percent_decode(pair:sub(1, equals - 1), true, "options")

    if not key then
      return nil, key_err
    end

    local option_value, value_err = percent_decode(pair:sub(equals + 1), true, "options")

    if not option_value then
      return nil, value_err
    end

    key = key:lower()

    if key == "" then
      return parse_error("MongoDB URI option key cannot be empty", "options")
    end

    if seen[key] and key ~= "readpreferencetags" then
      warnings[#warnings + 1] = "duplicate option: " .. key
    end

    seen[key] = true
    options[#options + 1] = { key = key, value = option_value }

    if not separator then
      break
    end

    start = separator + 1
  end

  return options, warnings
end

function M.parse_options(value)
  if value ~= nil and type(value) ~= "string" then
    error("MongoDB URI options must be a string", 2)
  end

  return parse_options(value)
end

function M.parse(value)
  if type(value) ~= "string" then
    error("MongoDB URI must be a string", 2)
  end

  local is_srv
  local scheme_length

  if value:sub(1, 10) == "mongodb://" then
    is_srv = false
    scheme_length = 10
  elseif value:sub(1, 14) == "mongodb+srv://" then
    is_srv = true
    scheme_length = 14
  else
    return parse_error(
      "MongoDB URI must begin with mongodb:// or mongodb+srv://",
      "scheme"
    )
  end

  if not valid_utf8(value) then
    return parse_error("MongoDB URI must be valid UTF-8", "uri")
  end

  local remainder = value:sub(scheme_length + 1)
  local question = remainder:find("?", 1, true)
  local option_text

  if question then
    option_text = remainder:sub(question + 1)
    remainder = remainder:sub(1, question - 1)
  end

  local slash = remainder:find("/", 1, true)
  local authority = slash and remainder:sub(1, slash - 1) or remainder
  local database_text = slash and remainder:sub(slash + 1) or nil
  local at = authority:find("@", 1, true)
  local credentials

  if at then
    if authority:find("@", at + 1, true) then
      return parse_error("MongoDB URI credentials contain an unescaped '@'", "userinfo")
    end

    credentials = authority:sub(1, at - 1)
    authority = authority:sub(at + 1)
  end

  local hosts, hosts_err = parse_hosts(authority)

  if not hosts then
    return nil, hosts_err
  end

  if is_srv and (#hosts ~= 1 or hosts[1].type ~= "hostname") then
    return parse_error(
      "mongodb+srv URI must contain exactly one hostname",
      "host"
    )
  end

  if is_srv and hosts[1].port ~= nil then
    return parse_error("mongodb+srv URI hostname must not include a port", "port")
  end

  local result = { hosts = hosts, is_srv = is_srv }

  if credentials then
    local userinfo, userinfo_err = parse_userinfo(credentials)

    if not userinfo then
      return nil, userinfo_err
    end

    result.username = userinfo.username
    result.password = userinfo.password
  end

  if database_text ~= nil and database_text ~= "" then
    local database, database_err = percent_decode(database_text, true, "database")

    if not database then
      return nil, database_err
    end

    if database:find('[/\\ "$]') then
      return parse_error("MongoDB URI database contains a prohibited character", "database")
    end

    result.database = database
  end

  local options, options_err = parse_options(option_text)

  if not options then
    return nil, options_err
  end

  result.options = options
  result.warnings = options_err
  return result
end

return M
