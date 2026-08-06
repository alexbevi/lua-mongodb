local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local hello_model = require("mongodb.command.hello")
local op_msg = require("mongodb.wire.op_msg")

local M = {}

local DEFAULT_MAX_BSON_SIZE = 16 * 1024 * 1024
local DEFAULT_MAX_MESSAGE_SIZE = 48000000
local EXECUTOR_STATES = setmetatable({}, { __mode = "k" })
local EXECUTOR_METHODS = {}
local EXECUTOR_METATABLE = {
  __index = EXECUTOR_METHODS,
  __metatable = "mongodb.command.executor",
  __newindex = function()
    error("command executors are immutable", 2)
  end,
}

local function protocol_error(message, details)
  return errors.new({
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

local function labels_from(document)
  local value = document:get("errorLabels")
  local labels = {}

  if not bson.is_array(value) then
    return labels
  end

  for _, label in value:iter() do
    if type(label) == "string" and label ~= "" then
      labels[#labels + 1] = label
    end
  end

  return labels
end

local function server_error(state, response)
  local message = response:get("errmsg")

  if type(message) ~= "string" or message == "" then
    message = response:get("$err")
  end

  if type(message) ~= "string" or message == "" then
    message = "command failed"
  end

  local code = number_value(response:get("code"))

  if math.type(code) ~= "integer" then
    code = nil
  end

  local code_name = response:get("codeName")

  if type(code_name) ~= "string" or code_name == "" then
    code_name = nil
  end

  local labels = labels_from(response)
  local retryable = false

  for _, label in ipairs(labels) do
    if label == "RetryableReadError" or label == "RetryableWriteError" then
      retryable = true
      break
    end
  end

  return errors.new({
    category = errors.CATEGORY.SERVER,
    code = code,
    code_name = code_name,
    details = { response = response },
    labels = labels,
    message = message,
    retryable = retryable,
    server = state.server,
    timeout = code == 50,
  })
end

local function append_server_api(entries, server_api)
  if not server_api then
    return
  end

  entries[#entries + 1] = { "apiVersion", server_api.version }

  if server_api.strict ~= nil then
    entries[#entries + 1] = { "apiStrict", server_api.strict }
  end

  if server_api.deprecation_errors ~= nil then
    entries[#entries + 1] = { "apiDeprecationErrors", server_api.deprecation_errors }
  end
end

local function envelope(command, database, server_api)
  local entries = command:entries()

  append_server_api(entries, server_api)
  entries[#entries + 1] = { "$db", database }
  return bson.document(entries)
end

local function monitored_envelope(body, sequences)
  local entries = body:entries()

  for _, sequence in ipairs(sequences or {}) do
    entries[#entries + 1] = {
      sequence.identifier,
      bson.array(sequence.documents or {}),
    }
  end

  return bson.document(entries)
end

local function close_with(state, err)
  state.connection:close()
  return nil, err
end

local function execute(state, database, command, options)
  options = options or {}

  if type(options) ~= "table" then
    error("command options must be a table", 3)
  end

  if type(database) ~= "string" or database == "" then
    error("command database must be a non-empty string", 3)
  end

  if not bson.is_document(command) then
    error("command must be a BSON document", 3)
  end

  if #command == 0 then
    error("command document must not be empty", 3)
  end

  local request_id = state.request_ids:next()
  local body = envelope(command, database, state.server_api)
  local bytes, err = op_msg.encode({
    body = body,
    max_bson_size = state.max_bson_size,
    max_message_size = state.max_message_size,
    request_id = request_id,
    sequences = options.sequences,
  })

  if not bytes then
    return nil, err
  end

  local span

  if options.monitor ~= false and state.monitoring and state.monitoring:has_listeners() then
    span = state.monitoring:start({
      command = monitored_envelope(body, options.sequences),
      connection_id = state.server,
      database_name = database,
      operation_id = options.operation_id,
      request_id = request_id,
      server_connection_id = state.server_connection_id,
      service_id = state.service_id,
    })
  end

  local written
  written, err = state.connection:write_all(bytes, options.deadline, options.cancellation)

  if not written then
    if span then
      span:failed(err)
    end

    return close_with(state, err)
  end

  local response_bytes
  response_bytes, err = state.connection:read_frame(
    state.max_message_size,
    options.deadline,
    options.cancellation
  )

  if not response_bytes then
    if span then
      span:failed(err)
    end

    return close_with(state, err)
  end

  local response
  response, err = op_msg.decode(response_bytes, {
    direction = "response",
    expected_response_to = request_id,
    max_bson_size = state.max_bson_size,
    max_message_size = state.max_message_size,
  })

  if not response then
    if span then
      span:failed(err)
    end

    return close_with(state, err)
  end

  if response.more_to_come then
    err = protocol_error("command response unexpectedly has moreToCome set")

    if span then
      span:failed(err)
    end

    return close_with(state, err)
  end

  local ok = number_value(response.body:get("ok"))

  if ok == nil then
    err = protocol_error("command response is missing a numeric ok field")

    if span then
      span:failed(err)
    end

    return close_with(state, err)
  end

  if ok == 0 then
    err = server_error(state, response.body)

    if span then
      span:failed(err)
    end

    return nil, err
  end

  if span then
    span:succeeded(response.body)
  end

  return response.body
end

local function metadata_document(options, platform)
  local entries = {}

  if options.app_name then
    entries[#entries + 1] = {
      "application",
      bson.document({ { "name", options.app_name } }),
    }
  end

  entries[#entries + 1] = {
    "driver",
    bson.document({
      { "name", "lua-mongodb" },
      { "version", options.driver_version or "0.1.0-dev" },
    }),
  }
  entries[#entries + 1] = {
    "os",
    bson.document({ { "type", options.os_type or "unknown" } }),
  }

  if platform ~= "" then
    entries[#entries + 1] = { "platform", platform }
  end

  return bson.document(entries)
end

local function metadata(options)
  if options.app_name ~= nil
    and (type(options.app_name) ~= "string" or options.app_name == "" or #options.app_name > 128)
  then
    error("app_name must be a non-empty string of at most 128 bytes", 3)
  end

  local platform = options.platform or _VERSION

  if type(platform) ~= "string" then
    error("platform metadata must be a string", 3)
  end

  local document = metadata_document(options, platform)
  local encoded = assert(bson.encode(document))

  if #encoded <= 512 then
    return document
  end

  local keep = math.max(0, #platform - (#encoded - 512))

  while keep > 0 and not utf8.len(platform:sub(1, keep)) do
    keep = keep - 1
  end

  document = metadata_document(options, platform:sub(1, keep))
  encoded = assert(bson.encode(document))

  if #encoded > 512 then
    error("required client metadata exceeds 512 bytes", 3)
  end

  return document
end

function EXECUTOR_METHODS:hello(options)
  local state = EXECUTOR_STATES[self]
  local command_name = (state.server_api ~= nil or state.hello_ok) and "hello" or "ismaster"
  local entries = { { command_name, 1 } }

  if command_name == "ismaster" then
    entries[#entries + 1] = { "helloOk", true }
  end

  entries[#entries + 1] = { "backpressure", "2" }

  if not state.handshake_complete then
    entries[#entries + 1] = { "client", state.metadata }
  end

  options = options or {}

  local response, err = execute(state, "admin", bson.document(entries), {
    cancellation = options.cancellation,
    deadline = options.deadline,
    monitor = false,
  })

  if not response then
    return nil, err
  end

  local hello
  hello, err = hello_model.new(response)

  if not hello then
    return close_with(state, err)
  end

  state.handshake_complete = true
  state.hello_ok = state.hello_ok or hello.hello_ok
  state.max_bson_size = hello.max_bson_size
  state.max_message_size = hello.max_message_size
  state.server_connection_id = hello.connection_id
  state.hello = hello
  return hello
end

function EXECUTOR_METHODS:command(database, command, options)
  local state = EXECUTOR_STATES[self]

  if not state.handshake_complete then
    return nil, errors.new({
      category = errors.CATEGORY.CLIENT,
      message = "connection handshake must complete before executing commands",
      server = state.server,
    })
  end

  return execute(state, database, command, options)
end

function EXECUTOR_METHODS:capabilities()
  return EXECUTOR_STATES[self].hello
end

function EXECUTOR_METHODS:close()
  return EXECUTOR_STATES[self].connection:close()
end

function M.new(connection, options)
  options = options or {}

  if type(options) ~= "table" then
    error("command executor options must be a table", 2)
  end

  if type(connection) ~= "table" or type(connection.write_all) ~= "function"
    or type(connection.read_frame) ~= "function" or type(connection.close) ~= "function"
  then
    error("command executor requires an exact-I/O connection", 2)
  end

  local value = {}

  EXECUTOR_STATES[value] = {
    connection = connection,
    handshake_complete = false,
    hello = nil,
    hello_ok = false,
    max_bson_size = DEFAULT_MAX_BSON_SIZE,
    max_message_size = DEFAULT_MAX_MESSAGE_SIZE,
    metadata = metadata(options),
    monitoring = options.monitoring,
    request_ids = options.request_ids or op_msg.request_ids(),
    server = options.server,
    server_connection_id = nil,
    server_api = options.server_api,
    service_id = nil,
  }

  return setmetatable(value, EXECUTOR_METATABLE)
end

return M
