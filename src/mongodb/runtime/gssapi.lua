local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime.contract")

local M = {}

local BINDING_MODULE = "mongodb.runtime._gssapi"
local SUPPORTED_PLATFORMS = {
  linux = true,
  macos = true,
}

local function auth_error(message, code_name, operation)
  return errors.new({
    category = errors.CATEGORY.AUTHENTICATION,
    code_name = code_name,
    details = operation and { operation = operation } or nil,
    message = message,
  })
end

local function require_nonempty_string(name, value, level)
  if type(value) ~= "string" or value == "" then
    error(name .. " must be a non-empty string", level or 3)
  end
end

local function method(receiver, name)
  local outcome = table.pack(pcall(function()
    return receiver[name]
  end))

  if not outcome[1] or type(outcome[2]) ~= "function" then
    return nil
  end

  return outcome[2]
end

local function binding_call(receiver, name, message, ...)
  local callback = method(receiver, name)

  if callback == nil then
    return nil, auth_error(
      message,
      "GSSAPI_BINDING_INVALID",
      name
    )
  end

  local outcome = table.pack(pcall(callback, receiver, ...))

  if not outcome[1] or outcome[2] == nil then
    return nil, auth_error(
      message,
      "GSSAPI_BINDING_FAILURE",
      name
    )
  end

  return table.unpack(outcome, 2, outcome.n)
end

local function create_binding_context(binding, options)
  local outcome = table.pack(pcall(binding.create_context, options))

  if not outcome[1] or outcome[2] == nil then
    return nil, auth_error(
      "GSSAPI context creation failed",
      "GSSAPI_BINDING_FAILURE",
      "create_context"
    )
  end

  return outcome[2]
end

local function validate_capabilities(capabilities)
  if type(capabilities) ~= "table"
      or type(capabilities.default_credentials) ~= "boolean"
      or type(capabilities.password_credentials) ~= "boolean"
      or type(capabilities.platform) ~= "string"
      or not SUPPORTED_PLATFORMS[capabilities.platform]
  then
    error("GSSAPI binding returned invalid capabilities", 3)
  end

  if capabilities.available ~= nil and type(capabilities.available) ~= "boolean" then
    error("GSSAPI binding availability must be a boolean", 3)
  end

  return {
    default_credentials = capabilities.default_credentials,
    password_credentials = capabilities.password_credentials,
    platform = capabilities.platform,
  }, capabilities.available ~= false
end

local function reported_capabilities(binding)
  if type(binding) ~= "table" or type(binding.capabilities) ~= "function" then
    error("GSSAPI binding must provide capabilities and create_context functions", 3)
  end

  if type(binding.create_context) ~= "function" then
    error("GSSAPI binding must provide capabilities and create_context functions", 3)
  end

  local outcome = table.pack(pcall(binding.capabilities))

  if not outcome[1] then
    error("GSSAPI binding capability discovery failed", 3)
  end

  return validate_capabilities(outcome[2])
end

local function check_runtime(runtime, deadline, cancellation)
  local ok, err = runtime_contract.check(runtime, deadline, cancellation)

  if not ok then
    return nil, err
  end

  return true
end

local function wrap_context(runtime, binding_context)
  if type(binding_context) ~= "table" and type(binding_context) ~= "userdata" then
    return nil, auth_error(
      "GSSAPI binding returned an invalid context",
      "GSSAPI_BINDING_INVALID",
      "create_context"
    )
  end

  local context = { _closed = false }

  function context:step(challenge, deadline, cancellation)
    if self._closed then
      error("GSSAPI context is closed", 2)
    end

    if type(challenge) ~= "string" then
      error("GSSAPI challenge must be a string", 2)
    end

    local ok, err = check_runtime(runtime, deadline, cancellation)

    if not ok then
      return nil, err
    end

    local result
    result, err = binding_call(
      binding_context,
      "step",
      "GSSAPI token step failed",
      challenge
    )

    if result == nil then
      return nil, err
    elseif type(result) ~= "table"
        or type(result.token) ~= "string"
        or type(result.complete) ~= "boolean"
    then
      return nil, auth_error(
        "GSSAPI binding returned an invalid token step",
        "GSSAPI_BINDING_INVALID",
        "step"
      )
    end

    ok, err = check_runtime(runtime, deadline, cancellation)

    if not ok then
      return nil, err
    end

    return result
  end

  function context:security_layer(challenge, username, deadline, cancellation)
    if self._closed then
      error("GSSAPI context is closed", 2)
    end

    if type(challenge) ~= "string" or type(username) ~= "string" then
      error("GSSAPI security-layer challenge and username must be strings", 2)
    end

    local ok, err = check_runtime(runtime, deadline, cancellation)

    if not ok then
      return nil, err
    end

    local token
    token, err = binding_call(
      binding_context,
      "security_layer",
      "GSSAPI security-layer negotiation failed",
      challenge,
      username
    )

    if token == nil then
      return nil, err
    elseif type(token) ~= "string" then
      return nil, auth_error(
        "GSSAPI binding returned an invalid security-layer token",
        "GSSAPI_BINDING_INVALID",
        "security_layer"
      )
    end

    ok, err = check_runtime(runtime, deadline, cancellation)

    if not ok then
      return nil, err
    end

    return token
  end

  function context:close()
    if self._closed then
      return true
    end

    self._closed = true

    local closed, err = binding_call(
      binding_context,
      "close",
      "GSSAPI context cleanup failed"
    )

    if closed == nil then
      return nil, err
    elseif closed ~= true then
      return nil, auth_error(
        "GSSAPI binding returned an invalid cleanup result",
        "GSSAPI_BINDING_INVALID",
        "close"
      )
    end

    return true
  end

  return context
end

function M.new(runtime, binding)
  if type(runtime) ~= "table" then
    error("GSSAPI runtime must be a table", 2)
  end

  local capabilities, available = reported_capabilities(binding)

  if not available then
    return nil
  end

  local provider = {}

  function provider.capabilities()
    return {
      default_credentials = capabilities.default_credentials,
      password_credentials = capabilities.password_credentials,
      platform = capabilities.platform,
    }
  end

  function provider.create_context(_, options, deadline, cancellation)
    if type(options) ~= "table" then
      error("GSSAPI context options must be a table", 2)
    end

    require_nonempty_string("GSSAPI service principal", options.service_principal, 2)
    require_nonempty_string("GSSAPI username", options.username, 2)

    if options.password ~= nil and type(options.password) ~= "string" then
      error("GSSAPI password must be a string when provided", 2)
    end

    if options.password == nil and not capabilities.default_credentials then
      return nil, auth_error(
        "GSSAPI default credentials are unavailable",
        "GSSAPI_DEFAULT_CREDENTIALS_UNAVAILABLE"
      )
    elseif options.password ~= nil and not capabilities.password_credentials then
      return nil, auth_error(
        "GSSAPI password credentials are unsupported",
        "GSSAPI_PASSWORD_CREDENTIALS_UNSUPPORTED"
      )
    end

    local ok, err = check_runtime(runtime, deadline, cancellation)

    if not ok then
      return nil, err
    end

    local context
    context, err = create_binding_context(binding, options)

    if context == nil then
      return nil, err
    end

    ok, err = check_runtime(runtime, deadline, cancellation)

    if not ok then
      local close = method(context, "close")

      if close ~= nil then
        pcall(close, context)
      end

      return nil, err
    end

    return wrap_context(runtime, context)
  end

  return provider
end

function M.load(runtime, loader)
  loader = loader or require

  if type(loader) ~= "function" then
    error("GSSAPI loader must be a function", 2)
  end

  local loaded = table.pack(pcall(loader, BINDING_MODULE))

  if not loaded[1] or type(loaded[2]) ~= "table" then
    return nil
  end

  local built = table.pack(pcall(M.new, runtime, loaded[2]))

  if not built[1] then
    return nil
  end

  return built[2]
end

return M
