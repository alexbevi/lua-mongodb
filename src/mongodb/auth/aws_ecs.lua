local bson = require("mongodb.bson")
local json = require("mongodb.bson.json")
local errors = require("mongodb.error")

local M = {}

local ENDPOINT = "http://169.254.170.2"
local FULL_URI = "AWS_CONTAINER_CREDENTIALS_FULL_URI"
local MAX_RESPONSE_BYTES = 1024 * 1024
local RELATIVE_URI = "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"
local TIMEOUT_SECONDS = 10

local function provider_error(original)
  local options = {
    category = errors.CATEGORY.AUTHENTICATION,
    details = { provider = "ecs" },
    message = "MONGODB-AWS ECS credential resolution failed",
  }

  if errors.is(original) then
    options.code = original.code
    options.code_name = original.code_name
    options.details.source_category = original.category
    options.labels = {}
    options.retryable = original.retryable
    options.server = original.server
    options.timeout = original.timeout

    for index, label in ipairs(original.labels) do
      options.labels[index] = label
    end
  end

  return errors.new(options)
end

local function environment_value(runtime, name)
  local value = runtime.environment:get(name)

  if value ~= nil and type(value) ~= "string" then
    error("runtime environment must return strings or nil", 3)
  end

  return value
end

local function leap_year(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function parse_expiration(value)
  if type(value) ~= "string" then
    return nil
  end

  local year, month, day, hour, minute, second = value:match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
  )

  if year == nil then
    year, month, day, hour, minute, second = value:match(
      "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.%d+Z$"
    )
  end

  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)
  hour = tonumber(hour)
  minute = tonumber(minute)
  second = tonumber(second)

  if year == nil
      or year < 1970
      or month < 1
      or month > 12
      or hour > 23
      or minute > 59
      or second > 59
  then
    return nil
  end

  local month_days = {
    31,
    leap_year(year) and 29 or 28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  }

  if day < 1 or day > month_days[month] then
    return nil
  end

  local adjusted_year = year - (month <= 2 and 1 or 0)
  local era = adjusted_year // 400
  local year_of_era = adjusted_year - era * 400
  local month_position = month + (month > 2 and -3 or 9)
  local day_of_year = (153 * month_position + 2) // 5 + day - 1
  local day_of_era = year_of_era * 365
    + year_of_era // 4
    - year_of_era // 100
    + day_of_year
  local days = era * 146097 + day_of_era - 719468

  return days * 86400 + hour * 3600 + minute * 60 + second
end

local function validate_runtime(runtime)
  if type(runtime) ~= "table"
      or type(runtime.clock) ~= "table"
      or type(runtime.clock.now) ~= "function"
      or type(runtime.clock.wall_time) ~= "function"
      or type(runtime.environment) ~= "table"
      or type(runtime.environment.get) ~= "function"
      or type(runtime.http) ~= "table"
      or type(runtime.http.request) ~= "function"
  then
    error(
      "ECS credential resolution requires runtime environment, HTTP, and "
        .. "clock adapters",
      3
    )
  end
end

local function request_deadline(runtime, deadline)
  local now = runtime.clock:now()

  if type(now) ~= "number"
      or now ~= now
      or now < 0
      or now == math.huge
  then
    error("runtime monotonic clock must return a finite non-negative number", 3)
  end

  local provider_deadline = now + TIMEOUT_SECONDS

  if deadline == nil then
    return provider_deadline
  end

  if type(deadline) ~= "number"
      or deadline ~= deadline
      or deadline < 0
      or deadline == math.huge
  then
    error("ECS deadline must be a finite non-negative number", 3)
  end

  return math.min(deadline, provider_deadline)
end

local function valid_relative_uri(value)
  return type(value) == "string"
    and value ~= ""
    and value:sub(1, 1) == "/"
    and value:find("#", 1, true) == nil
    and value:find("[%c%s]") == nil
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

local function parse_ipv4(value)
  local parts = {}

  for part in value:gmatch("[^.]+") do
    if not part:match("^%d+$")
        or #part > 1 and part:sub(1, 1) == "0"
    then
      return nil
    end

    local number = tonumber(part)

    if number > 255 then
      return nil
    end

    parts[#parts + 1] = number
  end

  if #parts ~= 4 then
    return nil
  end

  return parts
end

local function parse_ipv6_piece(value)
  local words = {}

  if value == "" then
    return words
  end

  for word in value:gmatch("[^:]+") do
    if #word > 4 or not word:match("^[0-9A-Fa-f]+$") then
      return nil
    end

    words[#words + 1] = tonumber(word, 16)
  end

  return words
end

local function parse_ipv6(value)
  if value == ""
      or value:find("[^0-9A-Fa-f:]")
      or value:find(":::", 1, true)
      or value:sub(1, 1) == ":" and value:sub(1, 2) ~= "::"
      or value:sub(-1) == ":" and value:sub(-2) ~= "::"
  then
    return nil
  end

  local compressed = value:find("::", 1, true)

  if compressed ~= nil and value:find("::", compressed + 2, true) then
    return nil
  end

  local left
  local right

  if compressed == nil then
    left = parse_ipv6_piece(value)

    if left == nil or #left ~= 8 then
      return nil
    end

    return left
  end

  left = parse_ipv6_piece(value:sub(1, compressed - 1))
  right = parse_ipv6_piece(value:sub(compressed + 2))

  if left == nil or right == nil or #left + #right >= 8 then
    return nil
  end

  local words = {}

  for _, word in ipairs(left) do
    words[#words + 1] = word
  end

  for _ = 1, 8 - #left - #right do
    words[#words + 1] = 0
  end

  for _, word in ipairs(right) do
    words[#words + 1] = word
  end

  return words
end

local function valid_dns_name(value)
  if #value > 253 or value:sub(-1) == "." then
    return false
  end

  local count = 0

  for label in value:gmatch("[^.]+") do
    if #label > 63
        or not label:match("^[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]$")
          and not label:match("^[A-Za-z0-9]$")
    then
      return false
    end

    count = count + #label + 1
  end

  return count == #value + 1
end

local function words_equal(left, right)
  for index = 1, 8 do
    if left[index] ~= right[index] then
      return false
    end
  end

  return true
end

local IPV6_LOOPBACK = { 0, 0, 0, 0, 0, 0, 0, 1 }
local IPV6_EKS = { 0xfd00, 0x0ec2, 0, 0, 0, 0, 0, 0x23 }

local function permitted_http_host(host, ipv6)
  local lowered = host:lower()

  if lowered == "localhost" then
    return true
  end

  if ipv6 then
    local words = parse_ipv6(host)

    return words ~= nil
      and (words_equal(words, IPV6_LOOPBACK)
        or words_equal(words, IPV6_EKS))
  end

  local address = parse_ipv4(host)

  return address ~= nil
    and (address[1] == 127
      or address[1] == 169
        and address[2] == 254
        and address[3] == 170
        and (address[4] == 2 or address[4] == 23))
end

local function valid_full_uri(value)
  if type(value) ~= "string"
      or value == ""
      or value:find("#", 1, true)
      or value:find("[%c%s]")
  then
    return false
  end

  local scheme, remainder = value:match("^(https?)://(.+)$")

  if scheme == nil then
    return false
  end

  local separator = remainder:find("[/?]")
  local authority = separator and remainder:sub(1, separator - 1) or remainder

  if authority == "" or authority:find("@", 1, true) then
    return false
  end

  local host
  local ipv6 = false

  if authority:sub(1, 1) == "[" then
    local close = authority:find("]", 2, true)

    if close == nil then
      return false
    end

    host = authority:sub(2, close - 1)
    ipv6 = true

    local suffix = authority:sub(close + 1)

    if host == ""
        or parse_ipv6(host) == nil
        or suffix ~= "" and (suffix:sub(1, 1) ~= ":"
          or parse_port(suffix:sub(2)) == nil)
    then
      return false
    end
  else
    local colon = authority:find(":", 1, true)

    if colon ~= nil and authority:find(":", colon + 1, true) then
      return false
    end

    if colon == nil then
      host = authority
    else
      host = authority:sub(1, colon - 1)

      if parse_port(authority:sub(colon + 1)) == nil then
        return false
      end
    end

    if host == ""
        or parse_ipv4(host) == nil and not valid_dns_name(host)
    then
      return false
    end
  end

  return scheme == "https" or permitted_http_host(host, ipv6)
end

function M.is_configured(runtime)
  validate_runtime(runtime)
  return environment_value(runtime, RELATIVE_URI) ~= nil
    or environment_value(runtime, FULL_URI) ~= nil
end

function M.resolve(runtime, options)
  validate_runtime(runtime)
  options = options or {}

  if type(options) ~= "table" then
    error("ECS credential options must be a table", 2)
  end

  local relative_uri = environment_value(runtime, RELATIVE_URI)
  local url

  if relative_uri ~= nil then
    if not valid_relative_uri(relative_uri) then
      return nil, provider_error()
    end

    url = ENDPOINT .. relative_uri
  else
    local full_uri = environment_value(runtime, FULL_URI)

    if not valid_full_uri(full_uri) then
      return nil, provider_error()
    end

    url = full_uri
  end

  local response, err = runtime.http:request({
    method = "GET",
    url = url,
  }, request_deadline(runtime, options.deadline), options.cancellation)

  if response == nil then
    return nil, provider_error(err)
  end

  if type(response) ~= "table"
      or math.type(response.status) ~= "integer"
      or response.status < 200
      or response.status > 299
      or type(response.body) ~= "string"
  then
    return nil, provider_error()
  end

  local document

  document, err = json.decode(response.body, {
    max_depth = 8,
    max_input_size = MAX_RESPONSE_BYTES,
    max_string_size = MAX_RESPONSE_BYTES,
  })

  if not document or not bson.is_document(document) then
    return nil, provider_error(err)
  end

  local username = document:get("AccessKeyId")
  local password = document:get("SecretAccessKey")
  local session_token = document:get("Token")
  local expiration = parse_expiration(document:get("Expiration"))
  local wall_time = runtime.clock:wall_time()

  if type(wall_time) ~= "number"
      or wall_time ~= wall_time
      or wall_time < 0
      or wall_time == math.huge
  then
    error("runtime wall clock must return a finite non-negative number", 2)
  end

  if type(username) ~= "string"
      or username == ""
      or type(password) ~= "string"
      or password == ""
      or type(session_token) ~= "string"
      or session_token == ""
      or expiration == nil
      or expiration <= wall_time
  then
    return nil, provider_error()
  end

  return {
    expiration = expiration,
    password = password,
    session_token = session_token,
    username = username,
  }
end

return M
