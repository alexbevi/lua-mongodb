local errors = require("mongodb.error")

local M = {}

local ACCESS_KEY_ID = "AWS_ACCESS_KEY_ID"
local SECRET_ACCESS_KEY = "AWS_SECRET_ACCESS_KEY"
local SESSION_TOKEN = "AWS_SESSION_TOKEN"

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

local function validate_inputs(runtime, credentials)
  if type(runtime) ~= "table"
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

function M.resolve(runtime, credentials)
  validate_inputs(runtime, credentials)

  local access_key_id = environment_value(runtime, ACCESS_KEY_ID)
  local secret_access_key = environment_value(runtime, SECRET_ACCESS_KEY)
  local session_token = environment_value(runtime, SESSION_TOKEN)
  local any_present = access_key_id ~= nil
    or secret_access_key ~= nil
    or session_token ~= nil

  if not any_present then
    return nil, auth_error("MONGODB-AWS environment credentials are unavailable")
  end

  if access_key_id == nil
      or access_key_id == ""
      or secret_access_key == nil
      or secret_access_key == ""
      or session_token == ""
  then
    return nil, auth_error("MONGODB-AWS environment credentials are incomplete")
  end

  return immutable({
    mechanism = "MONGODB-AWS",
    password = secret_access_key,
    session_token = session_token,
    source = "$external",
    username = access_key_id,
  })
end

return M
