local errors = require("mongodb.error")

local M = {}

local SCRAM_MECHANISMS = {
  ["SCRAM-SHA-1"] = true,
  ["SCRAM-SHA-256"] = true,
}
local AWS_MECHANISM = "MONGODB-AWS"
local OIDC_MECHANISM = "MONGODB-OIDC"
local X509_MECHANISM = "MONGODB-X509"
local OIDC_ENVIRONMENTS = {
  azure = true,
  gcp = true,
  k8s = true,
  test = true,
}
local OIDC_PROPERTIES = {
  ENVIRONMENT = true,
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
    __metatable = "mongodb.config.credentials",
    __newindex = immutable_value,
    __pairs = function()
      return next, values, nil
    end,
  })

  return proxy
end

local function has_properties(properties)
  if type(properties) ~= "table" then
    return false
  end

  local iterator, state, key = pairs(properties)
  return iterator(state, key) ~= nil
end

function M.build(parsed, config)
  if type(parsed) ~= "table" or type(config) ~= "table" then
    error("credential construction requires parsed URI and normalized options tables", 2)
  end

  local mechanism = config.auth_mechanism

  if parsed.username == nil then
    if mechanism == nil then
      return nil
    end

    if SCRAM_MECHANISMS[mechanism] or mechanism == "PLAIN" then
      return config_error("username", mechanism .. " requires a username")
    end

    if mechanism ~= AWS_MECHANISM
        and mechanism ~= OIDC_MECHANISM
        and mechanism ~= X509_MECHANISM
    then
      return config_error("auth_mechanism", "unsupported authentication mechanism")
    end
  end

  if mechanism ~= nil
      and not SCRAM_MECHANISMS[mechanism]
      and mechanism ~= "PLAIN"
      and mechanism ~= AWS_MECHANISM
      and mechanism ~= OIDC_MECHANISM
      and mechanism ~= X509_MECHANISM
  then
    return config_error("auth_mechanism", "unsupported authentication mechanism")
  end

  if mechanism == AWS_MECHANISM then
    if parsed.username ~= nil then
      return config_error(
        "username",
        "MONGODB-AWS credentials must be resolved by a credential provider"
      )
    end

    if parsed.password ~= nil then
      return config_error(
        "password",
        "MONGODB-AWS credentials must be resolved by a credential provider"
      )
    end

    if config.auth_source ~= nil and config.auth_source ~= "$external" then
      return config_error("auth_source", "MONGODB-AWS source must be $external")
    end

    if has_properties(config.auth_mechanism_properties) then
      return config_error(
        "auth_mechanism_properties",
        "MONGODB-AWS URI mechanism properties are not supported"
      )
    end

    return immutable({
      mechanism = AWS_MECHANISM,
      source = "$external",
    })
  end

  if mechanism == X509_MECHANISM then
    if parsed.password ~= nil then
      return config_error("password", "MONGODB-X509 does not support a password")
    end

    if config.auth_source ~= nil and config.auth_source ~= "$external" then
      return config_error("auth_source", "MONGODB-X509 source must be $external")
    end

    if has_properties(config.auth_mechanism_properties) then
      return config_error(
        "auth_mechanism_properties",
        "MONGODB-X509 authentication does not support mechanism properties"
      )
    end

    return immutable({
      mechanism = X509_MECHANISM,
      source = "$external",
      username = parsed.username,
    })
  end

  if mechanism == OIDC_MECHANISM then
    if parsed.password ~= nil then
      return config_error("password", "MONGODB-OIDC does not support a password")
    end

    if config.auth_source ~= nil and config.auth_source ~= "$external" then
      return config_error("auth_source", "MONGODB-OIDC source must be $external")
    end

    local properties = config.auth_mechanism_properties or {}

    for name in pairs(properties) do
      if not OIDC_PROPERTIES[name] then
        return config_error(
          "auth_mechanism_properties",
          "MONGODB-OIDC URI mechanism property is not supported"
        )
      end
    end

    local environment = properties.ENVIRONMENT
    local token_resource = properties.TOKEN_RESOURCE

    if not OIDC_ENVIRONMENTS[environment] then
      return config_error(
        "auth_mechanism_properties",
        "MONGODB-OIDC requires a supported ENVIRONMENT"
      )
    end

    if environment == "test" and parsed.username ~= nil then
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
        "MONGODB-OIDC environment does not support TOKEN_RESOURCE"
      )
    end

    local normalized_properties = { ENVIRONMENT = environment }

    if token_resource ~= nil then
      normalized_properties.TOKEN_RESOURCE = token_resource
    end

    return immutable({
      mechanism = OIDC_MECHANISM,
      mechanism_properties = immutable(normalized_properties),
      source = "$external",
      username = parsed.username,
    })
  end

  if parsed.password == nil then
    return config_error(
      "password",
      (mechanism == "PLAIN" and "PLAIN" or "SCRAM") .. " authentication requires a password"
    )
  end

  if has_properties(config.auth_mechanism_properties) then
    return config_error(
      "auth_mechanism_properties",
      (mechanism == "PLAIN" and "PLAIN" or "SCRAM")
        .. " authentication does not support mechanism properties"
    )
  end

  return immutable({
    mechanism = mechanism,
    password = parsed.password,
    source = config.auth_source or parsed.database
      or (mechanism == "PLAIN" and "$external" or "admin"),
    username = parsed.username,
  })
end

return M
