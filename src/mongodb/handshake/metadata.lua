local bson = require("mongodb.bson")

local M = {}

local DRIVER_NAME = "lua-mongodb"
local DRIVER_VERSION = "0.10.3"
local DRIVER_INFO_DELIMITER = "|"
local DOCKER_ENV_PATH = "/.dockerenv"
local INT32_MIN = -0x80000000
local INT32_MAX = 0x7fffffff
local MAX_METADATA_SIZE = 512

local function normalized_driver_info(value)
  if type(value) ~= "table" then
    error("driver_info must be a table", 3)
  end

  for key in pairs(value) do
    if key ~= "name" and key ~= "platform" and key ~= "version" then
      error("unknown driver_info field: " .. tostring(key), 3)
    end
  end

  local result = {}

  for _, field in ipairs({ "name", "version", "platform" }) do
    local item = value[field]

    if item ~= nil and item ~= "" then
      if type(item) ~= "string" then
        error("driver_info." .. field .. " must be a string", 3)
      elseif utf8.len(item) == nil then
        error("driver_info." .. field .. " must be valid UTF-8", 3)
      elseif item:find(DRIVER_INFO_DELIMITER, 1, true) then
        error("driver_info fields cannot contain '" .. DRIVER_INFO_DELIMITER .. "'", 3)
      end

      result[field] = item
    end
  end

  if result.name == nil then
    error("driver_info.name must be a non-empty string", 3)
  end

  return result
end

local function normalized_driver_infos(values)
  if values == nil then
    return {}
  elseif type(values) ~= "table" then
    error("driver_infos must be an array", 3)
  end

  local count = 0
  local maximum = 0

  for key in pairs(values) do
    if math.type(key) ~= "integer" or key < 1 then
      error("driver_infos must be a dense array", 3)
    end

    count = count + 1
    maximum = math.max(maximum, key)
  end

  if maximum ~= count then
    error("driver_infos must be a dense array", 3)
  end

  local result = {}

  for index = 1, count do
    result[index] = normalized_driver_info(values[index])
  end

  return result
end

local function driver_document(driver_infos, name, version)
  if name == nil then
    local names = { DRIVER_NAME }
    local versions = { DRIVER_VERSION }

    for _, info in ipairs(driver_infos) do
      names[#names + 1] = info.name

      if info.version ~= nil then
        versions[#versions + 1] = info.version
      end
    end

    name = table.concat(names, DRIVER_INFO_DELIMITER)
    version = table.concat(versions, DRIVER_INFO_DELIMITER)
  end

  return bson.document({
    { "name", name },
    { "version", version },
  }), name, version
end

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

function M.is_faas(environment)
  if type(environment) ~= "table" then
    error("environment metadata must be a table", 2)
  end

  return faas_name(environment) ~= nil
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

local function document(options, driver, operating_system, platform, environment)
  local entries = {}

  if options.app_name ~= nil then
    entries[#entries + 1] = {
      "application",
      bson.document({ { "name", options.app_name } }),
    }
  end

  entries[#entries + 1] = { "driver", driver }
  entries[#entries + 1] = { "os", operating_system }

  if platform ~= nil then
    entries[#entries + 1] = { "platform", platform }
  end

  if environment ~= nil then
    entries[#entries + 1] = { "env", environment }
  end

  return bson.document(entries)
end

local function required_environment_document(environment)
  if environment == nil then
    return nil
  end

  local name = environment:get("name")

  if name == nil then
    return nil
  end

  return bson.document({ { "name", name } })
end

local function required_os_document(operating_system)
  return bson.document({ { "type", operating_system:get("type") } })
end

local function utf8_prefix(value, keep, minimum)
  keep = math.max(minimum or 0, keep)

  while keep > (minimum or 0) and utf8.len(value:sub(1, keep)) == nil do
    keep = keep - 1
  end

  return value:sub(1, keep)
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

function M.normalize_driver_info(value)
  return normalized_driver_info(value)
end

function M.append_driver_info(values, value)
  local existing = normalized_driver_infos(values)
  local normalized = normalized_driver_info(value)

  for _, info in ipairs(existing) do
    if info.name == normalized.name
        and info.platform == normalized.platform
        and info.version == normalized.version
    then
      return existing, false
    end
  end

  existing[#existing + 1] = normalized
  return existing, true
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

  local driver_infos = normalized_driver_infos(options.driver_infos)

  for _, info in ipairs(driver_infos) do
    if info.platform ~= nil then
      platform = platform and platform .. DRIVER_INFO_DELIMITER .. info.platform
        or info.platform
    end
  end

  local driver, driver_name, driver_version = driver_document(driver_infos)
  local operating_system = os_document(options.os)
  local environment = environment_document(options.environment, options.files)
  local value = document(options, driver, operating_system, platform, environment)
  local bytes = encoded(value)

  if #bytes <= MAX_METADATA_SIZE then
    return value
  end

  environment = required_environment_document(environment)
  value = document(options, driver, operating_system, platform, environment)
  bytes = encoded(value)

  if #bytes <= MAX_METADATA_SIZE then
    return value
  end

  operating_system = required_os_document(operating_system)
  value = document(options, driver, operating_system, platform, environment)
  bytes = encoded(value)

  if #bytes <= MAX_METADATA_SIZE then
    return value
  end

  environment = nil
  value = document(options, driver, operating_system, platform, environment)
  bytes = encoded(value)

  if #bytes <= MAX_METADATA_SIZE then
    return value
  end

  local keep = math.max(0, #(platform or "") - (#bytes - MAX_METADATA_SIZE))

  local truncated_platform = keep > 0 and utf8_prefix(platform, keep) or nil

  value = document(options, driver, operating_system, truncated_platform, environment)
  bytes = encoded(value)

  if #bytes <= MAX_METADATA_SIZE then
    return value
  end

  keep = math.max(
    #DRIVER_VERSION,
    #driver_version - (#bytes - MAX_METADATA_SIZE)
  )
  driver_version = utf8_prefix(driver_version, keep, #DRIVER_VERSION)
  driver = driver_document(driver_infos, driver_name, driver_version)
  value = document(options, driver, operating_system, truncated_platform, environment)
  bytes = encoded(value)

  if #bytes <= MAX_METADATA_SIZE then
    return value
  end

  keep = math.max(#DRIVER_NAME, #driver_name - (#bytes - MAX_METADATA_SIZE))
  driver_name = utf8_prefix(driver_name, keep, #DRIVER_NAME)
  driver = driver_document(driver_infos, driver_name, driver_version)
  value = document(options, driver, operating_system, truncated_platform, environment)

  if #encoded(value) > MAX_METADATA_SIZE then
    error("required client metadata exceeds 512 bytes", 2)
  end

  return value
end

return M
