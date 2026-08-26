local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local MAX_CONTEXT_ROUNDS = 10

local function auth_error(message, original)
  local options = {
    category = errors.CATEGORY.AUTHENTICATION,
    message = message,
  }

  if errors.is(original) then
    options.code = original.code
    options.code_name = original.code_name
    options.details = { source_category = original.category }
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

local function invalid_provider_result()
  return nil, errors.new({
    category = errors.CATEGORY.INTERNAL,
    details = { operation = "gssapi_dns" },
    message = "runtime GSSAPI DNS provider returned an invalid result",
  })
end

local function control_error(err)
  return errors.is(err, errors.CATEGORY.CANCELLED)
    or errors.is(err, errors.CATEGORY.TIMEOUT)
end

local function forward_host(runtime, host, deadline, cancellation)
  local dns = runtime.dns

  if type(dns) ~= "table" or type(dns.resolve_host) ~= "function" then
    return host
  end

  local result, err = dns:resolve_host(host, deadline, cancellation)

  if not result then
    if control_error(err) then
      return nil, err
    end

    return host
  end

  if type(result) ~= "table"
      or type(result.address) ~= "string" or result.address == ""
      or type(result.canonical_name) ~= "string" or result.canonical_name == ""
  then
    return invalid_provider_result()
  end

  return result.canonical_name:lower(), nil, result.address
end

local function reverse_host(runtime, host, address, deadline, cancellation)
  local dns = runtime.dns

  if type(dns) ~= "table" or type(dns.resolve_address) ~= "function" then
    return host
  end

  local result, err = dns:resolve_address(address, deadline, cancellation)

  if not result then
    if control_error(err) then
      return nil, err
    end

    return host
  elseif type(result) ~= "string" or result == "" then
    return invalid_provider_result()
  end

  return result:lower()
end

function M.service_host(runtime, credential, server_host, deadline, cancellation)
  if type(runtime) ~= "table" or type(credential) ~= "table"
      or type(server_host) ~= "string" or server_host == "" then
    error("GSSAPI service-host resolution requires runtime, credential, and host", 2)
  end

  local properties = credential.mechanism_properties or {}
  local host = properties.SERVICE_HOST or server_host
  local mode = properties.CANONICALIZE_HOST_NAME or "none"

  if mode == "none" then
    return host
  elseif mode ~= "forward" and mode ~= "forwardAndReverse" then
    error("normalized GSSAPI hostname canonicalization mode is invalid", 2)
  end

  local canonical, err, address = forward_host(
    runtime, host, deadline, cancellation
  )

  if not canonical or mode == "forward" or address == nil then
    return canonical, err
  end

  return reverse_host(runtime, host, address, deadline, cancellation)
end

local function validate_authentication_inputs(
  commands,
  runtime,
  credential,
  options
)
  if type(commands) ~= "table" or type(commands.command) ~= "function" then
    error("GSSAPI authentication requires a command executor", 3)
  end

  if type(runtime) ~= "table" then
    error("GSSAPI authentication requires a runtime", 3)
  end

  if type(credential) ~= "table"
      or credential.mechanism ~= "GSSAPI"
      or credential.source ~= "$external"
      or type(credential.username) ~= "string"
      or credential.username == ""
      or type(credential.mechanism_properties) ~= "table"
  then
    error("GSSAPI credentials must select GSSAPI on $external", 3)
  end

  if credential.password ~= nil and type(credential.password) ~= "string" then
    error("GSSAPI password must be a string when provided", 3)
  end

  if type(options) ~= "table"
      or type(options.server_host) ~= "string"
      or options.server_host == ""
  then
    error("GSSAPI options require a server host", 3)
  end
end

local function provider_call(receiver, method, message, ...)
  local callback = receiver[method]

  if type(callback) ~= "function" then
    return nil, auth_error(message)
  end

  local outcome = table.pack(pcall(callback, receiver, ...))

  if not outcome[1] then
    return nil, auth_error(message)
  elseif outcome[2] == nil then
    return nil, auth_error(message, outcome[3])
  end

  return outcome[2], outcome[3]
end

local function provider_step(context, challenge, deadline, cancellation)
  local result, err = provider_call(
    context,
    "step",
    "GSSAPI provider token step failed",
    challenge,
    deadline,
    cancellation
  )

  if not result then
    return nil, err
  elseif type(result) ~= "table"
      or type(result.token) ~= "string"
      or type(result.complete) ~= "boolean"
  then
    return nil, auth_error("GSSAPI provider returned an invalid token step")
  end

  return result
end

local function response_values(response, expected_done, expected_id)
  if not bson.is_document(response) or response:get("done") ~= expected_done then
    return nil, auth_error("GSSAPI server returned an invalid SASL response")
  end

  local payload = response:get("payload")

  if not bson.is_binary(payload)
      or payload.subtype ~= bson.BINARY_SUBTYPE.GENERIC
  then
    return nil, auth_error("GSSAPI server returned an invalid SASL payload")
  end

  local identifier = response:get("conversationId")

  if bson.is_exact(identifier) then
    identifier = identifier:to_number()
  end

  if math.type(identifier) ~= "integer" then
    return nil, auth_error("GSSAPI server returned an invalid conversation id")
  elseif expected_id ~= nil and identifier ~= expected_id then
    return nil, auth_error("GSSAPI server changed the conversation id")
  end

  return {
    conversation_id = identifier,
    payload = payload.data,
  }
end

local function command_options(options)
  return {
    cancellation = options.cancellation,
    deadline = options.deadline,
  }
end

local function continue_command(commands, identifier, token, options)
  local response, err = commands:command("$external", bson.document({
    { "saslContinue", 1 },
    { "conversationId", identifier },
    { "payload", bson.binary(token) },
  }), command_options(options))

  if not response then
    return nil, auth_error("GSSAPI saslContinue failed", err)
  end

  return response
end

local function run_conversation(commands, context, options)
  local initial, err = provider_step(
    context,
    "",
    options.deadline,
    options.cancellation
  )

  if not initial then
    return nil, err
  elseif initial.complete then
    return nil, auth_error("GSSAPI provider completed before saslStart")
  end

  local response
  response, err = commands:command("$external", bson.document({
    { "saslStart", 1 },
    { "mechanism", "GSSAPI" },
    { "payload", bson.binary(initial.token) },
    { "autoAuthorize", 1 },
  }), command_options(options))

  if not response then
    return nil, auth_error("GSSAPI saslStart failed", err)
  end

  local values
  values, err = response_values(response, false)

  if not values then
    return nil, err
  end

  for _ = 1, MAX_CONTEXT_ROUNDS do
    local result
    result, err = provider_step(
      context,
      values.payload,
      options.deadline,
      options.cancellation
    )

    if not result then
      return nil, err
    end

    response, err = continue_command(
      commands,
      values.conversation_id,
      result.token,
      options
    )

    if not response then
      return nil, err
    end

    values, err = response_values(response, false, values.conversation_id)

    if not values then
      return nil, err
    elseif result.complete then
      local final_token
      final_token, err = provider_call(
        context,
        "security_layer",
        "GSSAPI security-layer negotiation failed",
        values.payload,
        options.username,
        options.deadline,
        options.cancellation
      )

      if not final_token then
        return nil, err
      elseif type(final_token) ~= "string" then
        return nil, auth_error(
          "GSSAPI provider returned an invalid security-layer token"
        )
      end

      response, err = continue_command(
        commands,
        values.conversation_id,
        final_token,
        options
      )

      if not response then
        return nil, err
      end

      values, err = response_values(response, true, values.conversation_id)

      if not values then
        return nil, err
      end

      return true
    end
  end

  return nil, auth_error("GSSAPI authentication exceeded its round limit")
end

local function close_context(context)
  local closed, err = provider_call(
    context,
    "close",
    "GSSAPI context cleanup failed"
  )

  if not closed then
    return nil, err
  elseif closed ~= true then
    return nil, auth_error("GSSAPI provider returned an invalid cleanup result")
  end

  return true
end

function M.authenticate(commands, runtime, credential, options)
  options = options or {}
  validate_authentication_inputs(commands, runtime, credential, options)

  local provider = runtime.gssapi

  if type(provider) ~= "table" then
    return nil, auth_error("GSSAPI runtime provider is unavailable")
  end

  local host, err = M.service_host(
    runtime,
    credential,
    options.server_host,
    options.deadline,
    options.cancellation
  )

  if not host then
    return nil, auth_error("GSSAPI hostname canonicalization failed", err)
  end

  local properties = credential.mechanism_properties
  local principal = (properties.SERVICE_NAME or "mongodb") .. "@" .. host

  if properties.SERVICE_REALM ~= nil then
    principal = principal .. "@" .. properties.SERVICE_REALM
  end

  local context
  context, err = provider_call(
    provider,
    "create_context",
    "GSSAPI context creation failed",
    {
      password = credential.password,
      service_principal = principal,
      username = credential.username,
    },
    options.deadline,
    options.cancellation
  )

  if not context then
    return nil, err
  elseif type(context) ~= "table" then
    return nil, auth_error("GSSAPI provider returned an invalid context")
  end

  local succeeded, authenticated, conversation_err = pcall(
    run_conversation,
    commands,
    context,
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      username = credential.username,
    }
  )
  local closed, close_err = close_context(context)

  if not succeeded then
    error(authenticated, 0)
  elseif not authenticated then
    return nil, conversation_err
  elseif not closed then
    return nil, close_err
  end

  return true
end

return M
