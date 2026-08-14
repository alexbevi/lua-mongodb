local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime")

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
local CALLBACK_TIMEOUT_SECONDS = 60

local function config_error(option, message)
  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    details = { option = option },
    message = message,
  })
end

local function auth_error(message, original)
  local options = {
    category = errors.CATEGORY.AUTHENTICATION,
    message = message,
  }

  if errors.is(original) then
    options.code = original.code
    options.code_name = original.code_name
    options.labels = {}
    options.retryable = original.retryable
      or errors.is(original, errors.CATEGORY.NETWORK)
    options.server = original.server
    options.timeout = original.timeout

    for index, label in ipairs(original.labels) do
      options.labels[index] = label
    end
  end

  return errors.new(options)
end

local function immutable(values, message)
  local proxy = {}

  setmetatable(proxy, {
    __index = values,
    __len = function()
      return #values
    end,
    __metatable = "mongodb.auth.oidc",
    __newindex = function()
      error(message or "authentication credentials are immutable", 2)
    end,
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

local function validate_auth_inputs(commands, runtime, credentials, options)
  if type(commands) ~= "table" or type(commands.command) ~= "function" then
    error("MONGODB-OIDC authentication requires a command executor", 3)
  end

  runtime_contract.validate(runtime)

  if type(credentials) ~= "table"
      or credentials.mechanism ~= "MONGODB-OIDC"
      or credentials.source ~= "$external"
  then
    error("MONGODB-OIDC credentials must select MONGODB-OIDC on $external", 3)
  end

  if type(credentials.mechanism_properties) ~= "table" then
    error("MONGODB-OIDC credentials require mechanism properties", 3)
  end

  if type(options) ~= "table" then
    error("MONGODB-OIDC options must be a table", 3)
  end

  local callback = credentials.mechanism_properties.OIDC_CALLBACK

  if type(callback) ~= "function" then
    return nil, auth_error("MONGODB-OIDC machine callback is not configured")
  end

  return callback
end

local function callback_context(runtime, credentials, options)
  local now = runtime.clock:now()

  if type(now) ~= "number" or now ~= now or now < 0 or now == math.huge then
    error("runtime monotonic clock must return a finite non-negative number", 3)
  end

  local deadline = now + CALLBACK_TIMEOUT_SECONDS

  if options.deadline ~= nil then
    local remaining = runtime_contract.remaining(runtime, options.deadline)
    deadline = now + math.min(remaining, CALLBACK_TIMEOUT_SECONDS)
  end

  local valid, err = runtime_contract.check(
    runtime,
    deadline,
    options.cancellation
  )

  if not valid then
    return nil, auth_error("MONGODB-OIDC machine callback cannot start", err)
  end

  return immutable({
    cancellation = options.cancellation,
    deadline = deadline,
    timeout_seconds = deadline - now,
    username = credentials.username or "",
    version = 1,
  }, "OIDC callback contexts are immutable")
end

local function callback_result(callback, context, runtime, options)
  local called = table.pack(pcall(callback, context))

  if not called[1] then
    return nil, auth_error("MONGODB-OIDC machine callback failed")
  end

  local result = called[2]

  if type(result) ~= "table"
      or type(result.access_token) ~= "string"
      or result.access_token == ""
  then
    return nil, auth_error("MONGODB-OIDC machine callback returned an invalid result")
  end

  local expires_in_seconds = result.expires_in_seconds

  if expires_in_seconds ~= nil
      and (type(expires_in_seconds) ~= "number"
        or expires_in_seconds ~= expires_in_seconds
        or expires_in_seconds < 0
        or expires_in_seconds == math.huge)
  then
    return nil, auth_error("MONGODB-OIDC machine callback returned an invalid result")
  end

  local valid, err = runtime_contract.check(
    runtime,
    context.deadline,
    options.cancellation
  )

  if not valid then
    return nil, auth_error("MONGODB-OIDC machine callback exceeded its deadline", err)
  end

  return result
end

local function response_valid(response)
  if not bson.is_document(response) or response:get("done") ~= true then
    return false
  end

  local conversation_id = response:get("conversationId")

  if bson.is_exact(conversation_id) then
    conversation_id = conversation_id:to_number()
  end

  local payload = response:get("payload")
  return math.type(conversation_id) == "integer"
    and bson.is_binary(payload)
    and payload.subtype == bson.BINARY_SUBTYPE.GENERIC
end

function M.authenticate(commands, runtime, credentials, options)
  options = options or {}
  local callback, err = validate_auth_inputs(
    commands,
    runtime,
    credentials,
    options
  )

  if not callback then
    return nil, err
  end

  local context
  context, err = callback_context(runtime, credentials, options)

  if not context then
    return nil, err
  end

  local result
  result, err = callback_result(callback, context, runtime, options)

  if not result then
    return nil, err
  end

  local payload
  payload, err = bson.encode(bson.document({ { "jwt", result.access_token } }))

  if not payload then
    return nil, auth_error("MONGODB-OIDC client payload encoding failed", err)
  end

  local response
  response, err = commands:command("$external", bson.document({
    { "saslStart", 1 },
    { "mechanism", "MONGODB-OIDC" },
    { "payload", bson.binary(payload) },
  }), {
    cancellation = options.cancellation,
    deadline = options.deadline,
  })

  if not response then
    return nil, auth_error("MONGODB-OIDC saslStart failed", err)
  end

  if not response_valid(response) then
    return nil, auth_error("MONGODB-OIDC server returned an invalid SASL response")
  end

  return true
end

return M
