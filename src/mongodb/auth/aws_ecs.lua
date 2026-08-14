local bson = require("mongodb.bson")
local json = require("mongodb.bson.json")
local errors = require("mongodb.error")

local M = {}

local ENDPOINT = "http://169.254.170.2"
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

function M.is_configured(runtime)
  validate_runtime(runtime)
  return environment_value(runtime, RELATIVE_URI) ~= nil
end

function M.resolve(runtime, options)
  validate_runtime(runtime)
  options = options or {}

  if type(options) ~= "table" then
    error("ECS credential options must be a table", 2)
  end

  local relative_uri = environment_value(runtime, RELATIVE_URI)

  if not valid_relative_uri(relative_uri) then
    return nil, provider_error()
  end

  local response, err = runtime.http:request({
    method = "GET",
    url = ENDPOINT .. relative_uri,
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
