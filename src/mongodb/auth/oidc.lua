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
local CALLBACK_INTERVAL_SECONDS = 0.1
local HUMAN_CALLBACK_TIMEOUT_SECONDS = 300
local MACHINE_CALLBACK_TIMEOUT_SECONDS = 60
local CLIENT_STATES = setmetatable({}, { __mode = "k" })
local CONNECTION_STATES = setmetatable({}, { __mode = "k" })

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

  local properties = credentials.mechanism_properties
  local callback = properties.OIDC_CALLBACK

  if callback == nil and type(properties.OIDC_HUMAN_CALLBACK) == "function" then
    local host = options.server_host
    local allowed = false

    if type(host) == "string" and host ~= "" then
      for _, pattern in ipairs(properties.ALLOWED_HOSTS or {}) do
        if host == pattern then
          allowed = true
          break
        end

        if string.sub(pattern, 1, 2) == "*." then
          local suffix = string.sub(pattern, 2)

          if #host > #suffix and string.sub(host, -#suffix) == suffix then
            allowed = true
            break
          end
        end
      end
    end

    if not allowed then
      return nil, auth_error("MONGODB-OIDC human callback host is not allowed")
    end

    return properties.OIDC_HUMAN_CALLBACK, "human"
  end

  if type(callback) ~= "function" then
    return nil, auth_error("MONGODB-OIDC machine callback is not configured")
  end

  return callback, "machine"
end

local function machine_callback_context(runtime, credentials, options)
  local now = runtime.clock:now()

  if type(now) ~= "number" or now ~= now or now < 0 or now == math.huge then
    error("runtime monotonic clock must return a finite non-negative number", 3)
  end

  local deadline = now + MACHINE_CALLBACK_TIMEOUT_SECONDS

  if options.deadline ~= nil then
    local remaining = runtime_contract.remaining(runtime, options.deadline)
    deadline = now + math.min(remaining, MACHINE_CALLBACK_TIMEOUT_SECONDS)
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

local function callback_result(callback, context, runtime, options, kind)
  local called = table.pack(pcall(callback, context))

  if not called[1] then
    return nil, auth_error("MONGODB-OIDC " .. kind .. " callback failed")
  end

  local result = called[2]

  if type(result) ~= "table"
      or type(result.access_token) ~= "string"
      or result.access_token == ""
  then
    return nil, auth_error(
      "MONGODB-OIDC " .. kind .. " callback returned an invalid result"
    )
  end

  local expires_in_seconds = result.expires_in_seconds

  if expires_in_seconds ~= nil
      and (type(expires_in_seconds) ~= "number"
        or expires_in_seconds ~= expires_in_seconds
        or expires_in_seconds < 0
        or expires_in_seconds == math.huge)
  then
    return nil, auth_error(
      "MONGODB-OIDC " .. kind .. " callback returned an invalid result"
    )
  end

  if kind == "human" and result.refresh_token ~= nil
      and (type(result.refresh_token) ~= "string"
        or result.refresh_token == "")
  then
    return nil, auth_error(
      "MONGODB-OIDC human callback returned an invalid result"
    )
  end

  local valid, err = runtime_contract.check(
    runtime,
    context.deadline,
    options.cancellation
  )

  if not valid then
    return nil, auth_error(
      "MONGODB-OIDC " .. kind .. " callback exceeded its deadline",
      err
    )
  end

  return result
end

local function response_conversation_id(response)
  local conversation_id = response:get("conversationId")

  if bson.is_exact(conversation_id) then
    conversation_id = conversation_id:to_number()
  end

  if math.type(conversation_id) == "integer" then
    return conversation_id
  end
end

local function response_valid(response)
  if not bson.is_document(response) or response:get("done") ~= true then
    return false
  end

  local payload = response:get("payload")
  return response_conversation_id(response) ~= nil
    and bson.is_binary(payload)
    and payload.subtype == bson.BINARY_SUBTYPE.GENERIC
end

local function idp_info(payload)
  local document, err = bson.decode(payload)

  if not document then
    return nil, err
  end

  local allowed = {
    clientId = true,
    issuer = true,
    requestScopes = true,
  }
  local seen = {}

  for name in document:iter() do
    if not allowed[name] or seen[name] then
      return nil
    end

    seen[name] = true
  end

  local issuer = document:get("issuer")
  local client_id = document:get("clientId")
  local request_scopes = document:get("requestScopes")

  if type(issuer) ~= "string" or issuer == ""
      or (client_id ~= nil and type(client_id) ~= "string")
      or (request_scopes ~= nil and not bson.is_array(request_scopes))
  then
    return nil
  end

  local normalized_scopes

  if request_scopes ~= nil then
    local values = {}

    for index, scope in request_scopes:iter() do
      if type(scope) ~= "string" then
        return nil
      end

      values[index] = scope
    end

    normalized_scopes = immutable(
      values,
      "OIDC callback contexts are immutable"
    )
  end

  return immutable({
    client_id = client_id,
    issuer = issuer,
    request_scopes = normalized_scopes,
  }, "OIDC callback contexts are immutable")
end

local function human_callback_context(runtime, credentials, options, info)
  local now = runtime.clock:now()

  if type(now) ~= "number" or now ~= now or now < 0 or now == math.huge then
    error("runtime monotonic clock must return a finite non-negative number", 3)
  end

  local deadline = now + HUMAN_CALLBACK_TIMEOUT_SECONDS
  local valid, err = runtime_contract.check(
    runtime,
    deadline,
    options.cancellation
  )

  if not valid then
    return nil, auth_error("MONGODB-OIDC human callback cannot start", err)
  end

  return immutable({
    cancellation = options.cancellation,
    deadline = deadline,
    idp_info = info,
    timeout_seconds = HUMAN_CALLBACK_TIMEOUT_SECONDS,
    username = credentials.username or "",
    version = 1,
  }, "OIDC callback contexts are immutable")
end

local function client_state(credentials, runtime)
  local state = CLIENT_STATES[credentials]

  if state == nil then
    state = {
      access_token = nil,
      callback_lock = runtime.lock:new(),
      last_callback_time = nil,
    }
    CLIENT_STATES[credentials] = state
  end

  return state
end

local function invalidate_token(commands, credentials, token)
  local state = CLIENT_STATES[credentials]

  if state ~= nil and state.access_token == token then
    state.access_token = nil
  end

  if CONNECTION_STATES[commands] == token then
    CONNECTION_STATES[commands] = nil
  end
end

local function is_authentication_failure(err)
  return errors.is(err, errors.CATEGORY.SERVER) and err.code == 18
end

local function fetch_token(callback, runtime, credentials, options, state)
  local context, err = machine_callback_context(runtime, credentials, options)

  if not context then
    return nil, err
  end

  local result
  result, err = callback_result(
    callback,
    context,
    runtime,
    options,
    "machine"
  )

  if not result then
    return nil, err
  end

  local token = { access_token = result.access_token }

  state.access_token = token
  return token
end

local function wait_for_callback_slot(runtime, options, state)
  if state.last_callback_time == nil then
    return true
  end

  local elapsed = runtime.clock:now() - state.last_callback_time
  local wait_time = CALLBACK_INTERVAL_SECONDS - elapsed

  if wait_time <= 0 then
    return true
  end

  if options.deadline ~= nil then
    wait_time = math.min(
      wait_time,
      runtime_contract.remaining(runtime, options.deadline)
    )
  end

  local waited, err = runtime.clock:sleep(wait_time, options.cancellation)

  if not waited then
    return nil, err
  end

  return runtime_contract.check(
    runtime,
    options.deadline,
    options.cancellation
  )
end

local function coordinated_token(callback, runtime, credentials, options, state)
  local acquired, err = state.callback_lock:acquire(
    options.deadline,
    options.cancellation
  )

  if not acquired then
    return nil, auth_error("MONGODB-OIDC machine callback wait failed", err)
  end

  local outcome = table.pack(pcall(function()
    if state.access_token ~= nil then
      return state.access_token
    end

    local waited
    waited, err = wait_for_callback_slot(runtime, options, state)

    if not waited then
      return nil, auth_error("MONGODB-OIDC machine callback wait failed", err)
    end

    state.last_callback_time = runtime.clock:now()
    return fetch_token(callback, runtime, credentials, options, state)
  end))

  state.callback_lock:release()

  if not outcome[1] then
    error(outcome[2], 0)
  end

  return table.unpack(outcome, 2, outcome.n)
end

local function authenticate_token(commands, credentials, options, token)
  local payload, err = bson.encode(bson.document({
    { "jwt", token.access_token },
  }))

  if not payload then
    return nil, auth_error("MONGODB-OIDC client payload encoding failed", err)
  end

  CONNECTION_STATES[commands] = token
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
    local authentication_failure = is_authentication_failure(err)

    if authentication_failure then
      invalidate_token(commands, credentials, token)
    end

    return nil, auth_error("MONGODB-OIDC saslStart failed", err),
      authentication_failure
  end

  if not response_valid(response) then
    return nil, auth_error("MONGODB-OIDC server returned an invalid SASL response")
  end

  return true
end

local function human_sasl_start(commands, credentials, options)
  local principal_entries = {}

  if type(credentials.username) == "string" and credentials.username ~= "" then
    principal_entries[1] = { "n", credentials.username }
  end

  local payload, err = bson.encode(bson.document(principal_entries))

  if not payload then
    return nil, auth_error("MONGODB-OIDC principal payload encoding failed", err)
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

  if not bson.is_document(response) or response:get("done") ~= false then
    return nil, auth_error("MONGODB-OIDC server returned an invalid IdP response")
  end

  local conversation_id = response_conversation_id(response)
  local response_payload = response:get("payload")

  if conversation_id == nil
      or not bson.is_binary(response_payload)
      or response_payload.subtype ~= bson.BINARY_SUBTYPE.GENERIC
  then
    return nil, auth_error("MONGODB-OIDC server returned an invalid IdP response")
  end

  local info = idp_info(response_payload.data)

  if not info then
    return nil, auth_error("MONGODB-OIDC server returned an invalid IdP response")
  end

  return {
    conversation_id = conversation_id,
    idp_info = info,
  }
end

local function authenticate_human(
  commands,
  runtime,
  credentials,
  options,
  callback
)
  local start, err = human_sasl_start(commands, credentials, options)

  if not start then
    return nil, err
  end

  local context
  context, err = human_callback_context(
    runtime,
    credentials,
    options,
    start.idp_info
  )

  if not context then
    return nil, err
  end

  local result
  result, err = callback_result(
    callback,
    context,
    runtime,
    options,
    "human"
  )

  if not result then
    return nil, err
  end

  local payload
  payload, err = bson.encode(bson.document({
    { "jwt", result.access_token },
  }))

  if not payload then
    return nil, auth_error("MONGODB-OIDC client payload encoding failed", err)
  end

  local response
  response, err = commands:command("$external", bson.document({
    { "saslContinue", 1 },
    { "conversationId", start.conversation_id },
    { "payload", bson.binary(payload) },
  }), {
    cancellation = options.cancellation,
    deadline = options.deadline,
  })

  if not response then
    return nil, auth_error("MONGODB-OIDC saslContinue failed", err)
  end

  if not response_valid(response)
      or response_conversation_id(response) ~= start.conversation_id
  then
    return nil, auth_error("MONGODB-OIDC server returned an invalid SASL response")
  end

  return true
end

function M.invalidate(commands, credentials)
  if type(commands) ~= "table" or type(credentials) ~= "table" then
    error("MONGODB-OIDC invalidation requires a connection and credentials", 2)
  end

  local token = CONNECTION_STATES[commands]

  if token ~= nil then
    invalidate_token(commands, credentials, token)
  end

  return true
end

function M.authenticate(commands, runtime, credentials, options)
  options = options or {}
  local callback, callback_kind = validate_auth_inputs(
    commands,
    runtime,
    credentials,
    options
  )

  if not callback then
    return nil, callback_kind
  end

  if callback_kind == "human" then
    return authenticate_human(
      commands,
      runtime,
      credentials,
      options,
      callback
    )
  end

  local err
  local state = client_state(credentials, runtime)
  local token = state.access_token

  if token ~= nil then
    local authenticated
    local authentication_failure
    authenticated, err, authentication_failure = authenticate_token(
      commands,
      credentials,
      options,
      token
    )

    if authenticated or not authentication_failure then
      return authenticated, err
    end
  end

  token = state.access_token

  if token == nil then
    token, err = coordinated_token(
      callback,
      runtime,
      credentials,
      options,
      state
    )

    if not token then
      return nil, err
    end
  end

  return authenticate_token(commands, credentials, options, token)
end

return M
