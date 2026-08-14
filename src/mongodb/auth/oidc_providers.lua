local bson = require("mongodb.bson")
local json = require("mongodb.bson.json")
local errors = require("mongodb.error")

local M = {}

local DEFAULT_KUBERNETES_TOKEN_FILE =
  "/var/run/secrets/kubernetes.io/serviceaccount/token"
local MAX_TOKEN_BYTES = 1024 * 1024
local TEST_TOKEN_FILE = "OIDC_TOKEN_FILE"

local function provider_error(environment, original, details)
  local provider_details = { provider = environment }

  for name, value in pairs(details or {}) do
    provider_details[name] = value
  end

  local options = {
    category = errors.CATEGORY.AUTHENTICATION,
    details = provider_details,
    message = "MONGODB-OIDC built-in provider token resolution failed",
  }

  if errors.is(original) then
    options.code = original.code
    options.code_name = original.code_name
    provider_details.source_category = original.category
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

local function percent_encode(value)
  return (value:gsub("([^A-Za-z0-9_.~-])", function(character)
    return string.format("%%%02X", character:byte())
  end))
end

local function environment_value(runtime, name)
  local value = runtime.environment:get(name)

  if value ~= nil and type(value) ~= "string" then
    error("runtime environment must return strings or nil", 3)
  end

  return value
end

local function file_token(runtime, context, environment, path, strip)
  if path == nil or path == "" then
    return nil, provider_error(environment)
  end

  local token, err = runtime.file:read(path, {
    cancellation = context.cancellation,
    deadline = context.deadline,
    max_bytes = MAX_TOKEN_BYTES,
  })

  if token == nil then
    return nil, provider_error(environment, err)
  end

  if strip then
    token = token:match("^%s*(.-)%s*$")
  end

  if token == "" then
    return nil, provider_error(environment)
  end

  return { access_token = token }
end

local function test_provider(runtime, context)
  local path = environment_value(runtime, TEST_TOKEN_FILE)
  return file_token(runtime, context, "test", path, true)
end

local function kubernetes_provider(runtime, context)
  local path = environment_value(runtime, "AZURE_FEDERATED_TOKEN_FILE")

  if path == nil then
    path = environment_value(runtime, "AWS_WEB_IDENTITY_TOKEN_FILE")
  end

  if path == nil then
    path = DEFAULT_KUBERNETES_TOKEN_FILE
  end

  return file_token(runtime, context, "k8s", path, false)
end

local function azure_provider(runtime, context, credentials)
  local properties = credentials.mechanism_properties
  local url = "http://169.254.169.254/metadata/identity/oauth2/token"
    .. "?api-version=2018-02-01"
    .. "&resource=" .. percent_encode(properties.TOKEN_RESOURCE)

  if context.username ~= "" then
    url = url .. "&client_id=" .. percent_encode(context.username)
  end

  local response, err = runtime.http:request({
    headers = {
      accept = "application/json",
      metadata = "true",
    },
    max_response_bytes = MAX_TOKEN_BYTES,
    method = "GET",
    url = url,
  }, context.deadline, context.cancellation)

  if response == nil then
    return nil, provider_error("azure", err)
  end

  if type(response) ~= "table"
      or math.type(response.status) ~= "integer"
      or type(response.body) ~= "string"
  then
    return nil, provider_error("azure")
  end

  if response.status ~= 200 then
    return nil, provider_error("azure", nil, {
      response_body = response.body,
    })
  end

  local document

  document, err = json.decode(response.body, {
    max_depth = 8,
    max_input_size = MAX_TOKEN_BYTES,
    max_string_size = MAX_TOKEN_BYTES,
  })

  if not document or not bson.is_document(document) then
    return nil, provider_error("azure", err)
  end

  local access_token = document:get("access_token")
  local expires_in = document:get("expires_in")

  if type(access_token) ~= "string"
      or access_token == ""
      or type(expires_in) ~= "string"
      or not expires_in:match("^%d+$")
  then
    return nil, provider_error("azure")
  end

  expires_in = tonumber(expires_in)

  if expires_in == nil or expires_in <= 0 then
    return nil, provider_error("azure")
  end

  return {
    access_token = access_token,
    expires_in_seconds = expires_in,
  }
end

local function gcp_provider(runtime, context, credentials)
  local resource = credentials.mechanism_properties.TOKEN_RESOURCE
  local response, err = runtime.http:request({
    headers = { ["metadata-flavor"] = "Google" },
    max_response_bytes = MAX_TOKEN_BYTES,
    method = "GET",
    url = "http://metadata/computeMetadata/v1/instance/"
      .. "service-accounts/default/identity"
      .. "?audience=" .. percent_encode(resource),
  }, context.deadline, context.cancellation)

  if response == nil then
    return nil, provider_error("gcp", err)
  end

  if type(response) ~= "table"
      or math.type(response.status) ~= "integer"
      or type(response.body) ~= "string"
  then
    return nil, provider_error("gcp")
  end

  if response.status ~= 200 then
    return nil, provider_error("gcp", nil, {
      response_body = response.body,
    })
  end

  if response.body == "" then
    return nil, provider_error("gcp")
  end

  return { access_token = response.body }
end

local PROVIDERS = {
  azure = azure_provider,
  gcp = gcp_provider,
  k8s = kubernetes_provider,
  test = test_provider,
}

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
  local provider = PROVIDERS[environment]

  if provider == nil then
    return nil, provider_error(environment or "unknown")
  end

  return function(context)
    local result, err = provider(runtime, context, credentials)

    if not result then
      error(err, 0)
    end

    return result
  end
end

return M
