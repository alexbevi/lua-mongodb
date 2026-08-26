local errors = require("mongodb.error")
local oidc = require("mongodb.auth.oidc")

local M = {}

local AWS_MECHANISM = "MONGODB-AWS"
local GSSAPI_MECHANISM = "GSSAPI"
local OIDC_MECHANISM = "MONGODB-OIDC"
local X509_MECHANISM = "MONGODB-X509"
local SUPPORTED_MECHANISMS = {
  [AWS_MECHANISM] = true,
  [GSSAPI_MECHANISM] = true,
  [OIDC_MECHANISM] = true,
  ["PLAIN"] = true,
  ["SCRAM-SHA-1"] = true,
  ["SCRAM-SHA-256"] = true,
  [X509_MECHANISM] = true,
}
local USERNAME_MECHANISMS = {
  [GSSAPI_MECHANISM] = true,
  ["PLAIN"] = true,
  ["SCRAM-SHA-1"] = true,
  ["SCRAM-SHA-256"] = true,
}
local GSSAPI_PROPERTIES = {
  CANONICALIZE_HOST_NAME = true,
  SERVICE_HOST = true,
  SERVICE_NAME = true,
  SERVICE_REALM = true,
}
local GSSAPI_CANONICALIZATION = {
  ["false"] = "none",
  ["forward"] = "forward",
  ["forwardAndReverse"] = "forwardAndReverse",
  ["none"] = "none",
  ["true"] = "forwardAndReverse",
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

local function normalize_gssapi_canonicalization(value)
  local key = value

  if type(value) == "boolean" then
    key = tostring(value)
  end

  local normalized = GSSAPI_CANONICALIZATION[key]

  if not normalized then
    return config_error(
      "auth_mechanism_properties",
      "GSSAPI hostname canonicalization mode is invalid"
    )
  end

  return normalized
end

local function normalize_gssapi_properties(properties)
  local normalized = { SERVICE_NAME = "mongodb" }
  local seen = {}

  for name, value in pairs(properties) do
    local canonical_name = type(name) == "string" and name:upper() or nil

    if not canonical_name or not GSSAPI_PROPERTIES[canonical_name] then
      return config_error(
        "auth_mechanism_properties",
        "GSSAPI mechanism property is unsupported"
      )
    elseif seen[canonical_name] then
      return config_error(
        "auth_mechanism_properties",
        "GSSAPI mechanism property is duplicated"
      )
    end

    seen[canonical_name] = true

    if canonical_name == "CANONICALIZE_HOST_NAME" then
      local canonicalization, canonicalization_err =
        normalize_gssapi_canonicalization(value)

      if not canonicalization then
        return nil, canonicalization_err
      end

      normalized[canonical_name] = canonicalization
    elseif type(value) ~= "string" then
      return config_error(
        "auth_mechanism_properties",
        "GSSAPI mechanism property must be a string"
      )
    else
      normalized[canonical_name] = value
    end
  end

  return immutable(normalized)
end

local function build_gssapi(parsed, config)
  if parsed.username == "" then
    return config_error("username", "GSSAPI requires a username")
  end

  if config.auth_source ~= nil and config.auth_source ~= "$external" then
    return config_error("auth_source", "GSSAPI source must be $external")
  end

  local normalized_properties, properties_err = normalize_gssapi_properties(
    config.auth_mechanism_properties or {}
  )

  if not normalized_properties then
    return nil, properties_err
  end

  return immutable({
    mechanism = GSSAPI_MECHANISM,
    mechanism_properties = normalized_properties,
    password = parsed.password,
    source = "$external",
    username = parsed.username,
  })
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

    if USERNAME_MECHANISMS[mechanism] then
      return config_error("username", mechanism .. " requires a username")
    end

    if not SUPPORTED_MECHANISMS[mechanism] then
      return config_error("auth_mechanism", "unsupported authentication mechanism")
    end
  end

  if mechanism ~= nil and not SUPPORTED_MECHANISMS[mechanism] then
    return config_error("auth_mechanism", "unsupported authentication mechanism")
  end

  if mechanism == GSSAPI_MECHANISM then
    return build_gssapi(parsed, config)
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

    local normalized_properties, properties_err = oidc.configure(
      parsed.username,
      config.auth_mechanism_properties or {}
    )

    if not normalized_properties then
      return nil, properties_err
    end

    return immutable({
      mechanism = OIDC_MECHANISM,
      mechanism_properties = normalized_properties,
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
