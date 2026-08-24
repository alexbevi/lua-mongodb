local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local DEFAULT_MAX_BSON_SIZE = 16 * 1024 * 1024
local DEFAULT_MAX_MESSAGE_SIZE = 48000000
local DEFAULT_MAX_WRITE_BATCH_SIZE = 100000
local HELLO_STATES = setmetatable({}, { __mode = "k" })
local HELLO_METATABLE = {
  __index = function(value, key)
    local state = HELLO_STATES[value]
    return state and state[key] or nil
  end,
  __metatable = "mongodb.command.hello",
  __newindex = function()
    error("hello capability models are immutable", 2)
  end,
}

local function protocol_error(message, details)
  return nil, errors.new({
    category = errors.CATEGORY.PROTOCOL,
    details = details,
    message = message,
  })
end

local function number_value(value)
  if type(value) == "number" then
    return value
  end

  if bson.is_exact(value) then
    return value:to_number()
  end
end

local function integer_field(document, name, default, minimum)
  local value = document:get(name)

  if value == nil then
    return default
  end

  value = number_value(value)

  if math.type(value) ~= "integer" or value < minimum then
    return protocol_error("hello response contains an invalid " .. name, { field = name })
  end

  return value
end

local function boolean_field(document, name, default)
  local value = document:get(name)

  if value == nil then
    return default
  end

  if type(value) ~= "boolean" then
    return protocol_error("hello response contains an invalid " .. name, { field = name })
  end

  return value
end

local function server_type(document)
  if document:get("serviceId") ~= nil then
    return "load_balancer"
  end

  if document:get("isreplicaset") == true then
    return "rs_ghost"
  end

  if document:get("setName") ~= nil then
    if document:get("isWritablePrimary") == true or document:get("ismaster") == true then
      return "rs_primary"
    end

    if document:get("secondary") == true then
      return "rs_secondary"
    end

    if document:get("arbiterOnly") == true then
      return "rs_arbiter"
    end

    return "rs_other"
  end

  if document:get("msg") == "isdbgrid" then
    return "mongos"
  end

  return "standalone"
end

function M.new(document)
  if not bson.is_document(document) then
    error("hello response must be a BSON document", 2)
  end

  local max_bson_size, err = integer_field(
    document,
    "maxBsonObjectSize",
    DEFAULT_MAX_BSON_SIZE,
    5
  )

  if not max_bson_size then
    return nil, err
  end

  local max_message_size
  max_message_size, err = integer_field(
    document,
    "maxMessageSizeBytes",
    DEFAULT_MAX_MESSAGE_SIZE,
    21
  )

  if not max_message_size then
    return nil, err
  end

  local max_write_batch_size
  max_write_batch_size, err = integer_field(
    document,
    "maxWriteBatchSize",
    DEFAULT_MAX_WRITE_BATCH_SIZE,
    1
  )

  if not max_write_batch_size then
    return nil, err
  end

  local min_wire_version
  min_wire_version, err = integer_field(document, "minWireVersion", 0, 0)

  if not min_wire_version then
    return nil, err
  end

  local max_wire_version
  max_wire_version, err = integer_field(document, "maxWireVersion", 0, 0)

  if not max_wire_version then
    return nil, err
  end

  local logical_session_timeout = document:get("logicalSessionTimeoutMinutes")

  if logical_session_timeout == bson.null then
    logical_session_timeout = nil
  elseif logical_session_timeout ~= nil then
    logical_session_timeout = number_value(logical_session_timeout)

    if math.type(logical_session_timeout) ~= "integer" or logical_session_timeout < 0 then
      return protocol_error(
        "hello response contains an invalid logicalSessionTimeoutMinutes",
        { field = "logicalSessionTimeoutMinutes" }
      )
    end
  end

  local hello_ok
  hello_ok, err = boolean_field(document, "helloOk", false)

  if hello_ok == nil then
    return nil, err
  end

  local connection_id = document:get("connectionId")

  if connection_id ~= nil then
    connection_id = number_value(connection_id)

    if math.type(connection_id) ~= "integer" then
      return protocol_error("hello response contains an invalid connectionId", {
        field = "connectionId",
      })
    end
  end

  local service_id = document:get("serviceId")

  if service_id ~= nil and not bson.is_tagged(service_id, "object_id") then
    return protocol_error("hello response contains an invalid serviceId", {
      field = "serviceId",
    })
  end

  local kind = server_type(document)
  local is_writable = kind == "standalone" or kind == "mongos"
    or kind == "load_balancer" or kind == "rs_primary"
  local is_readable = is_writable or kind == "rs_secondary"
  local value = {}

  HELLO_STATES[value] = {
    connection_id = connection_id,
    document = document,
    hello_ok = hello_ok,
    is_readable = is_readable,
    is_writable = is_writable,
    logical_session_timeout_minutes = logical_session_timeout,
    max_bson_size = max_bson_size,
    max_message_size = max_message_size,
    max_wire_version = max_wire_version,
    max_write_batch_size = max_write_batch_size,
    min_wire_version = min_wire_version,
    service_id = service_id,
    server_type = kind,
  }

  return setmetatable(value, HELLO_METATABLE)
end

return M
