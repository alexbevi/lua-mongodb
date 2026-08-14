local bson = require("mongodb.bson")
local json = require("mongodb.bson.json")
local errors = require("mongodb.error")

local M = {}

local CREDENTIALS_ENDPOINT = "http://169.254.169.254/latest/meta-data/iam/"
  .. "security-credentials/"
local MAX_RESPONSE_BYTES = 1024 * 1024
local MAX_ROLE_BYTES = 1024
local MAX_TOKEN_BYTES = 64 * 1024
local TIMEOUT_SECONDS = 10
local TOKEN_ENDPOINT = "http://169.254.169.254/latest/api/token"
local TOKEN_TTL_SECONDS = "30"

local function provider_error(original)
  local options = {
    category = errors.CATEGORY.AUTHENTICATION,
    details = { provider = "ec2" },
    message = "MONGODB-AWS EC2 credential resolution failed",
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
      or type(runtime.http) ~= "table"
      or type(runtime.http.request) ~= "function"
  then
    error("EC2 credential resolution requires runtime HTTP and clock adapters", 3)
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
    error("EC2 deadline must be a finite non-negative number", 3)
  end

  return math.min(deadline, provider_deadline)
end

local function response_body(
  runtime,
  request,
  deadline,
  cancellation,
  max_bytes
)
  request.max_response_bytes = max_bytes

  local response, err = runtime.http:request(
    request,
    deadline,
    cancellation
  )

  if response == nil then
    return nil, err
  end

  if type(response) ~= "table"
      or math.type(response.status) ~= "integer"
      or response.status < 200
      or response.status > 299
      or type(response.body) ~= "string"
      or #response.body > max_bytes
  then
    return nil
  end

  return response.body
end

local function valid_token(value)
  return type(value) == "string"
    and value ~= ""
    and not value:find("[%c%s]")
end

local function role_name(value)
  if type(value) ~= "string" then
    return nil
  end

  local role = value:match("^%s*(.-)%s*$")

  if role == ""
      or #role > 64
      or not role:match("^[A-Za-z0-9_+=,.@-]+$")
  then
    return nil
  end

  return role
end

local function wall_time(runtime)
  local value = runtime.clock:wall_time()

  if type(value) ~= "number"
      or value ~= value
      or value < 0
      or value == math.huge
  then
    error("runtime wall clock must return a finite non-negative number", 3)
  end

  return value
end

function M.resolve(runtime, options)
  validate_runtime(runtime)
  options = options or {}

  if type(options) ~= "table" then
    error("EC2 credential options must be a table", 2)
  end

  local deadline = request_deadline(runtime, options.deadline)
  local token, err = response_body(runtime, {
    headers = {
      ["x-aws-ec2-metadata-token-ttl-seconds"] = TOKEN_TTL_SECONDS,
    },
    method = "PUT",
    url = TOKEN_ENDPOINT,
  }, deadline, options.cancellation, MAX_TOKEN_BYTES)

  if not valid_token(token) then
    return nil, provider_error(err)
  end

  local metadata_headers = {
    ["x-aws-ec2-metadata-token"] = token,
  }
  local role_body

  role_body, err = response_body(runtime, {
    headers = metadata_headers,
    method = "GET",
    url = CREDENTIALS_ENDPOINT,
  }, deadline, options.cancellation, MAX_ROLE_BYTES)

  local role = role_name(role_body)

  if role == nil then
    return nil, provider_error(err)
  end

  local credentials_body

  credentials_body, err = response_body(runtime, {
    headers = metadata_headers,
    method = "GET",
    url = CREDENTIALS_ENDPOINT .. role,
  }, deadline, options.cancellation, MAX_RESPONSE_BYTES)

  if credentials_body == nil then
    return nil, provider_error(err)
  end

  local document

  document, err = json.decode(credentials_body, {
    max_depth = 8,
    max_input_size = MAX_RESPONSE_BYTES,
    max_string_size = MAX_RESPONSE_BYTES,
  })

  if not document
      or not bson.is_document(document)
      or document:get("Code") ~= "Success"
  then
    return nil, provider_error(err)
  end

  local username = document:get("AccessKeyId")
  local password = document:get("SecretAccessKey")
  local session_token = document:get("Token")
  local expiration = parse_expiration(document:get("Expiration"))

  if type(username) ~= "string"
      or username == ""
      or type(password) ~= "string"
      or password == ""
      or type(session_token) ~= "string"
      or session_token == ""
      or expiration == nil
      or expiration <= wall_time(runtime)
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
