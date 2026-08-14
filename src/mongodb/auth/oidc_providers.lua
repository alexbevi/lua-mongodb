local errors = require("mongodb.error")

local M = {}

local MAX_TOKEN_BYTES = 1024 * 1024
local TOKEN_FILE = "OIDC_TOKEN_FILE"

local function provider_error(environment, original)
  local options = {
    category = errors.CATEGORY.AUTHENTICATION,
    details = { provider = environment },
    message = "MONGODB-OIDC built-in provider token resolution failed",
  }

  if errors.is(original) then
    options.code = original.code
    options.code_name = original.code_name
    options.details.source_category = original.category
    options.labels = {}
    options.retryable = original.retryable
    options.server = original.server
    options.timeout = original.timeout

    for index, label in ipairs(original.labels) do
      options.labels[index] = label
    end
  end

  return errors.new(options)
end

local function test_provider(runtime, context)
  local path = runtime.environment:get(TOKEN_FILE)

  if path ~= nil and type(path) ~= "string" then
    error("runtime environment must return strings or nil", 3)
  end

  if path == nil or path == "" then
    return nil, provider_error("test")
  end

  local token, err = runtime.file:read(path, {
    cancellation = context.cancellation,
    deadline = context.deadline,
    max_bytes = MAX_TOKEN_BYTES,
  })

  if token == nil then
    return nil, provider_error("test", err)
  end

  token = token:match("^%s*(.-)%s*$")

  if token == "" then
    return nil, provider_error("test")
  end

  return { access_token = token }
end

function M.callback(runtime, credentials)
  if type(runtime) ~= "table"
      or type(runtime.environment) ~= "table"
      or type(runtime.environment.get) ~= "function"
      or type(runtime.file) ~= "table"
      or type(runtime.file.read) ~= "function"
  then
    error("OIDC providers require runtime environment and file adapters", 2)
  end

  if type(credentials) ~= "table"
      or type(credentials.mechanism_properties) ~= "table"
  then
    error("OIDC providers require normalized credentials", 2)
  end

  local environment = credentials.mechanism_properties.ENVIRONMENT

  if environment ~= "test" then
    return nil, provider_error(environment or "unknown")
  end

  return function(context)
    local result, err = test_provider(runtime, context)

    if not result then
      error(err, 0)
    end

    return result
  end
end

return M
