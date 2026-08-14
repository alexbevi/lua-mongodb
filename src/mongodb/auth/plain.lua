local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

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

local function validate_inputs(commands, credentials, options)
  if type(commands) ~= "table" or type(commands.command) ~= "function" then
    error("PLAIN authentication requires a command executor", 3)
  end

  if type(credentials) ~= "table" then
    error("PLAIN credentials must be a table", 3)
  end

  if credentials.mechanism ~= "PLAIN" then
    error("PLAIN credentials must select the PLAIN mechanism", 3)
  end

  if type(credentials.username) ~= "string" or credentials.username == "" then
    error("PLAIN username must be a non-empty string", 3)
  end

  if type(credentials.password) ~= "string" then
    error("PLAIN password must be a string", 3)
  end

  if type(credentials.source) ~= "string" or credentials.source == "" then
    error("PLAIN source must be a non-empty string", 3)
  end

  if type(options) ~= "table" then
    error("PLAIN options must be a table", 3)
  end
end

function M.authenticate(commands, credentials, options)
  options = options or {}
  validate_inputs(commands, credentials, options)

  local response, err = commands:command(credentials.source, bson.document({
    { "saslStart", 1 },
    { "mechanism", "PLAIN" },
    { "payload", bson.binary(
      "\0" .. credentials.username .. "\0" .. credentials.password
    ) },
    { "autoAuthorize", 1 },
  }), {
    cancellation = options.cancellation,
    deadline = options.deadline,
  })

  if not response then
    return nil, auth_error("PLAIN authentication command failed", err)
  end

  if not bson.is_document(response) then
    return nil, auth_error("PLAIN server returned an invalid response")
  end

  local payload = response:get("payload")

  if response:get("done") ~= true
      or not bson.is_binary(payload)
      or payload.subtype ~= bson.BINARY_SUBTYPE.GENERIC
  then
    return nil, auth_error("PLAIN server returned an invalid response")
  end

  return true
end

return M
