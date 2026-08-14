local errors = require("mongodb.error")

local M = {}

local DEFAULT_ALLOWED_HOSTS = {
  "*.mongodb.net",
  "*.mongodb-qa.net",
  "*.mongodb-dev.net",
  "*.mongodbgov.net",
  "localhost",
  "127.0.0.1",
  "::1",
  "*.mongo.com",
}
local ENVIRONMENTS = {
  azure = true,
  gcp = true,
  k8s = true,
  test = true,
}
local PROPERTIES = {
  ALLOWED_HOSTS = true,
  ENVIRONMENT = true,
  OIDC_CALLBACK = true,
  OIDC_HUMAN_CALLBACK = true,
  TOKEN_RESOURCE = true,
}

local function config_error(option, message)
  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    details = { option = option },
    message = message,
  })
end

local function immutable_value()
  error("authentication credentials are immutable", 2)
end

local function immutable(values)
  local proxy = {}

  setmetatable(proxy, {
    __index = values,
    __len = function()
      return #values
    end,
    __metatable = "mongodb.auth.oidc",
    __newindex = immutable_value,
    __pairs = function()
      return next, values, nil
    end,
  })

  return proxy
end

local function normalize_allowed_hosts(value)
  if type(value) ~= "table" then
    return config_error(
      "auth_mechanism_properties",
      "MONGODB-OIDC ALLOWED_HOSTS must be a list"
    )
  end

  local count = 0

  for index, host in pairs(value) do
    if math.type(index) ~= "integer" or index < 1
        or type(host) ~= "string" or host == ""
    then
      return config_error(
        "auth_mechanism_properties",
        "MONGODB-OIDC ALLOWED_HOSTS must contain only non-empty strings"
      )
    end

    count = count + 1
  end

  local result = {}

  for index = 1, count do
    if value[index] == nil then
      return config_error(
        "auth_mechanism_properties",
        "MONGODB-OIDC ALLOWED_HOSTS must be a dense list"
      )
    end

    result[index] = value[index]
  end

  return immutable(result)
end

function M.configure(username, properties)
  if type(properties) ~= "table" then
    error("OIDC mechanism properties must be a table", 2)
  end

  for name in pairs(properties) do
    if not PROPERTIES[name] then
      return config_error(
        "auth_mechanism_properties",
        "MONGODB-OIDC mechanism property is not supported"
      )
    end
  end

  local callback = properties.OIDC_CALLBACK
  local environment = properties.ENVIRONMENT
  local human_callback = properties.OIDC_HUMAN_CALLBACK
  local token_resource = properties.TOKEN_RESOURCE

  if callback ~= nil and type(callback) ~= "function" then
    return config_error(
      "auth_mechanism_properties",
      "MONGODB-OIDC machine callback must be configured programmatically"
    )
  end

  if human_callback ~= nil and type(human_callback) ~= "function" then
    return config_error(
      "auth_mechanism_properties",
      "MONGODB-OIDC human callback must be configured programmatically"
    )
  end

  local identities = (environment ~= nil and 1 or 0)
    + (callback ~= nil and 1 or 0)
    + (human_callback ~= nil and 1 or 0)

  if identities ~= 1 then
    return config_error(
      "auth_mechanism_properties",
      "MONGODB-OIDC requires exactly one environment or callback"
    )
  end

  if environment ~= nil and not ENVIRONMENTS[environment] then
    return config_error(
      "auth_mechanism_properties",
      "MONGODB-OIDC requires a supported ENVIRONMENT"
    )
  end

  if environment == "test" and username ~= nil then
    return config_error(
      "username",
      "MONGODB-OIDC test environment does not support a username"
    )
  end

  if environment == "azure" or environment == "gcp" then
    if type(token_resource) ~= "string" or token_resource == "" then
      return config_error(
        "auth_mechanism_properties",
        "MONGODB-OIDC environment requires TOKEN_RESOURCE"
      )
    end
  elseif token_resource ~= nil then
    return config_error(
      "auth_mechanism_properties",
      "MONGODB-OIDC configuration does not support TOKEN_RESOURCE"
    )
  end

  local allowed_hosts = properties.ALLOWED_HOSTS

  if allowed_hosts ~= nil and human_callback == nil then
    return config_error(
      "auth_mechanism_properties",
      "MONGODB-OIDC ALLOWED_HOSTS requires a human callback"
    )
  end

  local normalized = {}

  if environment ~= nil then
    normalized.ENVIRONMENT = environment
  elseif callback ~= nil then
    normalized.OIDC_CALLBACK = callback
  else
    normalized.OIDC_HUMAN_CALLBACK = human_callback
    allowed_hosts = allowed_hosts or DEFAULT_ALLOWED_HOSTS

    local allowed_hosts_err
    normalized.ALLOWED_HOSTS, allowed_hosts_err = normalize_allowed_hosts(allowed_hosts)

    if not normalized.ALLOWED_HOSTS then
      return nil, allowed_hosts_err
    end
  end

  if token_resource ~= nil then
    normalized.TOKEN_RESOURCE = token_resource
  end

  return immutable(normalized)
end

return M
