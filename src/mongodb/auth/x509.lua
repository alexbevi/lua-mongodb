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
    error("MONGODB-X509 authentication requires a command executor", 3)
  end

  if type(credentials) ~= "table" then
    error("MONGODB-X509 credentials must be a table", 3)
  end

  if credentials.mechanism ~= "MONGODB-X509" then
    error("MONGODB-X509 credentials must select the MONGODB-X509 mechanism", 3)
  end

  if credentials.source ~= "$external" then
    error("MONGODB-X509 credentials must use $external", 3)
  end

  if credentials.username ~= nil and type(credentials.username) ~= "string" then
    error("MONGODB-X509 username must be a string when provided", 3)
  end

  if type(options) ~= "table" then
    error("MONGODB-X509 options must be a table", 3)
  end
end

function M.authenticate(commands, credentials, options)
  options = options or {}
  validate_inputs(commands, credentials, options)

  local entries = {
    { "authenticate", 1 },
    { "mechanism", "MONGODB-X509" },
  }

  if credentials.username ~= nil then
    entries[#entries + 1] = { "user", credentials.username }
  end

  local response, err = commands:command(
    "$external",
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
    }
  )

  if not response then
    return nil, auth_error("MONGODB-X509 authentication command failed", err)
  end

  if not bson.is_document(response) then
    return nil, auth_error("MONGODB-X509 server returned an invalid response")
  end

  return true
end

return M
