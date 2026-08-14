local json = require("mongodb.bson.json")
local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local ENDPOINT = "https://sts.amazonaws.com/"
local MAX_TOKEN_BYTES = 1024 * 1024
local ROLE_ARN = "AWS_ROLE_ARN"
local ROLE_SESSION_NAME = "AWS_ROLE_SESSION_NAME"
local TOKEN_FILE = "AWS_WEB_IDENTITY_TOKEN_FILE"

local function provider_error(original)
  local options = {
    category = errors.CATEGORY.AUTHENTICATION,
    details = { provider = "web_identity" },
    message = "MONGODB-AWS web identity credential resolution failed",
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

local function percent_encode(value)
  return (value:gsub("([^A-Za-z0-9_.~-])", function(character)
    return string.format("%%%02X", character:byte())
  end))
end

local function hex(value)
  return (value:gsub(".", function(character)
    return string.format("%02x", character:byte())
  end))
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
      or type(runtime.clock.wall_time) ~= "function"
      or type(runtime.entropy) ~= "table"
      or type(runtime.entropy.bytes) ~= "function"
      or type(runtime.environment) ~= "table"
      or type(runtime.environment.get) ~= "function"
      or type(runtime.file) ~= "table"
      or type(runtime.file.read) ~= "function"
      or type(runtime.http) ~= "table"
      or type(runtime.http.request) ~= "function"
  then
    error(
      "web identity resolution requires runtime environment, file, HTTP, "
        .. "clock, and entropy adapters",
      3
    )
  end
end

function M.is_configured(runtime)
  validate_runtime(runtime)
  return environment_value(runtime, TOKEN_FILE) ~= nil
    and environment_value(runtime, ROLE_ARN) ~= nil
end

function M.resolve(runtime, options)
  validate_runtime(runtime)
  options = options or {}

  if type(options) ~= "table" then
    error("web identity options must be a table", 2)
  end

  local token_path = environment_value(runtime, TOKEN_FILE)
  local role_arn = environment_value(runtime, ROLE_ARN)
  local session_name = environment_value(runtime, ROLE_SESSION_NAME)

  if token_path == nil
      or token_path == ""
      or role_arn == nil
      or role_arn == ""
      or session_name == ""
  then
    return nil, provider_error()
  end

  if session_name == nil then
    local bytes, err = runtime.entropy:bytes(16)

    if bytes == nil then
      return nil, provider_error(err)
    end

    if type(bytes) ~= "string" or #bytes ~= 16 then
      return nil, provider_error()
    end

    session_name = "lua-mongodb-" .. hex(bytes)
  end

  local token, err = runtime.file:read(token_path, {
    cancellation = options.cancellation,
    deadline = options.deadline,
    max_bytes = MAX_TOKEN_BYTES,
  })

  if token == nil or token == "" then
    return nil, provider_error(err)
  end

  local query = table.concat({
    "Action=AssumeRoleWithWebIdentity",
    "RoleSessionName=" .. percent_encode(session_name),
    "RoleArn=" .. percent_encode(role_arn),
    "WebIdentityToken=" .. percent_encode(token),
    "Version=2011-06-15",
  }, "&")
  local response

  response, err = runtime.http:request({
    body = "",
    headers = { accept = "application/json" },
    method = "POST",
    url = ENDPOINT .. "?" .. query,
  }, options.deadline, options.cancellation)

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
    max_input_size = MAX_TOKEN_BYTES,
    max_string_size = MAX_TOKEN_BYTES,
  })

  if not document or not bson.is_document(document) then
    return nil, provider_error(err)
  end

  local values = document:get("Credentials")

  if not bson.is_document(values) then
    return nil, provider_error()
  end

  local username = values:get("AccessKeyId")
  local password = values:get("SecretAccessKey")
  local session_token = values:get("SessionToken")
  local expiration = parse_expiration(values:get("Expiration"))

  if type(username) ~= "string"
      or username == ""
      or type(password) ~= "string"
      or password == ""
      or type(session_token) ~= "string"
      or session_token == ""
      or expiration == nil
      or expiration <= runtime.clock:wall_time()
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
