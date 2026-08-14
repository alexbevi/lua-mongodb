local errors = require("mongodb.error")

local M = {}

local SCRAM_MECHANISMS = {
  ["SCRAM-SHA-1"] = true,
  ["SCRAM-SHA-256"] = true,
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

    return config_error("auth_mechanism", "unsupported authentication mechanism")
  end

  if mechanism ~= nil and not SCRAM_MECHANISMS[mechanism] and mechanism ~= "PLAIN" then
    return config_error("auth_mechanism", "unsupported authentication mechanism")
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
