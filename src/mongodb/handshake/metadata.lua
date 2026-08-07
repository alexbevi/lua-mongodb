local bson = require("mongodb.bson")

local M = {}

local DRIVER_NAME = "lua-mongodb"
local DRIVER_VERSION = "0.1.0-dev"
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

local function document(options, platform)
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

  local value = document(options, platform)
  local bytes = encoded(value)

  if #bytes <= MAX_METADATA_SIZE then
    return value
  end

  local keep = math.max(0, #(platform or "") - (#bytes - MAX_METADATA_SIZE))

  while keep > 0 and not utf8.len(platform:sub(1, keep)) do
    keep = keep - 1
  end

  value = document(options, platform and platform:sub(1, keep) or nil)

  if #encoded(value) > MAX_METADATA_SIZE then
    error("required client metadata exceeds 512 bytes", 2)
  end

  return value
end

return M
