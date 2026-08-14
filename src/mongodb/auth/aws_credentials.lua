local errors = require("mongodb.error")

local M = {}

local ACCESS_KEY_ID = "AWS_ACCESS_KEY_ID"
local SECRET_ACCESS_KEY = "AWS_SECRET_ACCESS_KEY"
local SESSION_TOKEN = "AWS_SESSION_TOKEN"
local REFRESH_WINDOW_SECONDS = 60
local cache_entry

local function auth_error(message)
  return errors.new({
    category = errors.CATEGORY.AUTHENTICATION,
    message = message,
  })
end

local function immutable_value()
  error("resolved AWS credentials are immutable", 2)
end

local function immutable(values)
  local proxy = {}

  setmetatable(proxy, {
    __index = values,
    __metatable = "mongodb.auth.aws_credentials",
    __newindex = immutable_value,
    __pairs = function()
      return next, values, nil
    end,
  })

  return proxy
end

local function environment_value(runtime, name)
  local value = runtime.environment:get(name)

  if value ~= nil and type(value) ~= "string" then
    error("runtime environment must return strings or nil", 3)
  end

  return value
end

local function provider_error(original)
  local options = {
    category = errors.CATEGORY.AUTHENTICATION,
    message = "MONGODB-AWS credential provider failed",
  }

  if errors.is(original) then
    options.code = original.code
    options.code_name = original.code_name
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

local function resolved_credential(values)
  return immutable({
    expiration = values.expiration,
    mechanism = "MONGODB-AWS",
    password = values.password,
    session_token = values.session_token,
    source = "$external",
    username = values.username,
  })
end

local function call_provider(runtime, provider, options)
  local values, err = provider(runtime, options)

  if values == nil then
    return nil, provider_error(err)
  end

  if type(values) ~= "table"
      or type(values.username) ~= "string"
      or values.username == ""
      or type(values.password) ~= "string"
      or values.password == ""
      or (values.session_token ~= nil
        and (type(values.session_token) ~= "string"
          or values.session_token == ""))
      or type(values.expiration) ~= "number"
      or values.expiration ~= values.expiration
      or values.expiration == math.huge
      or values.expiration <= wall_time(runtime)
  then
    return nil, provider_error()
  end

  local credential = resolved_credential(values)

  cache_entry = {
    credential = credential,
    expiration = values.expiration,
    provider = provider,
  }
  return credential
end

local function validate_inputs(runtime, credentials)
  if type(runtime) ~= "table"
      or type(runtime.clock) ~= "table"
      or type(runtime.clock.wall_time) ~= "function"
      or type(runtime.environment) ~= "table"
      or type(runtime.environment.get) ~= "function"
  then
    error("AWS credential resolution requires a runtime environment adapter", 3)
  end

  if type(credentials) ~= "table"
      or credentials.mechanism ~= "MONGODB-AWS"
      or credentials.source ~= "$external"
  then
    error("AWS credential resolution requires MONGODB-AWS on $external", 3)
  end
end

function M.clear_cache()
  cache_entry = nil
end

function M.invalidate(credentials)
  if cache_entry ~= nil and cache_entry.credential == credentials then
    cache_entry = nil
    return true
  end

  return false
end

function M.resolve(runtime, credentials, options)
  validate_inputs(runtime, credentials)
  options = options or {}

  if type(options) ~= "table" then
    error("AWS credential resolution options must be a table", 2)
  end

  if options.provider ~= nil and type(options.provider) ~= "function" then
    error("AWS credential provider must be a function", 2)
  end

  if cache_entry ~= nil then
    if cache_entry.expiration - wall_time(runtime) > REFRESH_WINDOW_SECONDS then
      return cache_entry.credential
    end

    local provider = cache_entry.provider

    cache_entry = nil
    return call_provider(runtime, provider, options)
  end

  local access_key_id = environment_value(runtime, ACCESS_KEY_ID)
  local secret_access_key = environment_value(runtime, SECRET_ACCESS_KEY)
  local session_token = environment_value(runtime, SESSION_TOKEN)
  local any_present = access_key_id ~= nil
    or secret_access_key ~= nil
    or session_token ~= nil

  if not any_present then
    if options.provider == nil then
      return nil, auth_error("MONGODB-AWS credentials are unavailable")
    end

    return call_provider(runtime, options.provider, options)
  end

  if access_key_id == nil
      or access_key_id == ""
      or secret_access_key == nil
      or secret_access_key == ""
      or session_token == ""
  then
    return nil, auth_error("MONGODB-AWS environment credentials are incomplete")
  end

  return resolved_credential({
    password = secret_access_key,
    session_token = session_token,
    username = access_key_id,
  })
end

return M
