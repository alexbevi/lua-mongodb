local bson = require("mongodb.bson")

local M = {}

local DRIVER_NAME = "lua-mongodb"
local DRIVER_VERSION = "0.1.0-dev"
local DOCKER_ENV_PATH = "/.dockerenv"
local INT32_MIN = -0x80000000
local INT32_MAX = 0x7fffffff
local MAX_METADATA_SIZE = 512

local function optional_string(name, value)
  if value == nil or value == "" then
    return nil
  end

  if type(value) ~= "string" then
    error(name .. " must be a string", 3)
  end

  return value
end

local function os_document(facts)
  facts = facts or {}

  if type(facts) ~= "table" then
    error("os metadata must be a table", 3)
  end

  local entries = {
    { "type", optional_string("os.type", facts.type) or "unknown" },
  }

  for _, field in ipairs({ "name", "architecture", "version" }) do
    local value = optional_string("os." .. field, facts[field])

    if value ~= nil then
      entries[#entries + 1] = { field, value }
    end
  end

  return bson.document(entries)
end

local function populated(environment, name)
  local value = environment[name]

  return type(value) == "string" and value ~= ""
end

local function optional_environment_string(environment, name)
  local value = environment[name]

  if type(value) ~= "string" or value == "" or utf8.len(value) == nil then
    return nil
  end

  return value
end

local function optional_environment_int32(environment, name)
  local value = environment[name]

  if type(value) ~= "string" or value == "" then
    return nil
  end

  value = value:match("^%s*(.-)%s*$")

  if not value:match("^%d+$") and not value:match("^[+-]%d+$") then
    return nil
  end

  local number = math.tointeger(tonumber(value))

  if number == nil or number < INT32_MIN or number > INT32_MAX then
    return nil
  end

  return number
end

local function faas_name(environment)
  local aws = populated(environment, "AWS_LAMBDA_RUNTIME_API")
    or (populated(environment, "AWS_EXECUTION_ENV")
      and environment.AWS_EXECUTION_ENV:sub(1, 11) == "AWS_Lambda_")
  local azure = populated(environment, "FUNCTIONS_WORKER_RUNTIME")
  local gcp = populated(environment, "K_SERVICE")
    or populated(environment, "FUNCTION_NAME")
  local vercel = populated(environment, "VERCEL")

  if aws and vercel and not azure and not gcp then
    return "vercel"
  end

  local count = (aws and 1 or 0) + (azure and 1 or 0)
    + (gcp and 1 or 0) + (vercel and 1 or 0)

  if count ~= 1 then
    return nil
  elseif aws then
    return "aws.lambda"
  elseif azure then
    return "azure.func"
  elseif gcp then
    return "gcp.func"
  end

  return "vercel"
end

local function environment_document(environment, files)
  environment = environment or {}
  files = files or {}

  if type(environment) ~= "table" then
    error("environment metadata must be a table", 3)
  elseif type(files) ~= "table" then
    error("filesystem metadata must be a table", 3)
  end

  local name = faas_name(environment)
  local fields = {}

  if name ~= nil then
    fields.name = name

    if name == "aws.lambda" then
      fields.memory_mb = optional_environment_int32(
        environment,
        "AWS_LAMBDA_FUNCTION_MEMORY_SIZE"
      )
      fields.region = optional_environment_string(environment, "AWS_REGION")
    elseif name == "gcp.func" then
      fields.memory_mb = optional_environment_int32(environment, "FUNCTION_MEMORY_MB")
      fields.region = optional_environment_string(environment, "FUNCTION_REGION")
      fields.timeout_sec = optional_environment_int32(
        environment,
        "FUNCTION_TIMEOUT_SEC"
      )
    elseif name == "vercel" then
      fields.region = optional_environment_string(environment, "VERCEL_REGION")
    end
  end

  local container_entries = {}

  if files[DOCKER_ENV_PATH] == true then
    container_entries[#container_entries + 1] = { "runtime", "docker" }
  end

  if populated(environment, "KUBERNETES_SERVICE_HOST") then
    container_entries[#container_entries + 1] = { "orchestrator", "kubernetes" }
  end

  local entries = {}

  for _, field in ipairs({ "name", "timeout_sec", "memory_mb", "region" }) do
    if fields[field] ~= nil then
      entries[#entries + 1] = { field, fields[field] }
    end
  end

  if #container_entries > 0 then
    entries[#entries + 1] = { "container", bson.document(container_entries) }
  end

  return #entries > 0 and bson.document(entries) or nil
end

local function document(options, platform, environment)
  local entries = {}

  if options.app_name ~= nil then
    entries[#entries + 1] = {
      "application",
      bson.document({ { "name", options.app_name } }),
    }
  end

  entries[#entries + 1] = {
    "driver",
    bson.document({
      { "name", DRIVER_NAME },
      { "version", DRIVER_VERSION },
    }),
  }
  entries[#entries + 1] = { "os", os_document(options.os) }

  if platform ~= nil then
    entries[#entries + 1] = { "platform", platform }
  end

  if environment ~= nil then
    entries[#entries + 1] = { "env", environment }
  end

  return bson.document(entries)
end

local function encoded(document_value)
  local bytes, err = bson.encode(document_value)

  if not bytes then
    error("client metadata must contain valid BSON strings: " .. tostring(err), 3)
  end

  return bytes
end

function M.driver_version()
  return DRIVER_VERSION
end

function M.new(options)
  options = options or {}

  if type(options) ~= "table" then
    error("client metadata options must be a table", 2)
  end

  if options.app_name ~= nil then
    if type(options.app_name) ~= "string" or options.app_name == ""
        or #options.app_name > 128
    then
      error("app_name must be a non-empty string of at most 128 bytes", 2)
    end
  end

  local platform = options.platform

  if platform == nil then
    platform = _VERSION
  else
    platform = optional_string("platform metadata", platform)
  end

  local environment = environment_document(options.environment, options.files)
  local value = document(options, platform, environment)
  local bytes = encoded(value)

  if #bytes <= MAX_METADATA_SIZE then
    return value
  end

  local keep = math.max(0, #(platform or "") - (#bytes - MAX_METADATA_SIZE))

  while keep > 0 and not utf8.len(platform:sub(1, keep)) do
    keep = keep - 1
  end

  value = document(options, platform and platform:sub(1, keep) or nil, environment)

  if #encoded(value) > MAX_METADATA_SIZE then
    error("required client metadata exceeds 512 bytes", 2)
  end

  return value
end

return M
