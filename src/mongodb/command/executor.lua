local bson = require("mongodb.bson")
local command_security = require("mongodb.command.security")
local errors = require("mongodb.error")
local handshake_metadata = require("mongodb.handshake.metadata")
local hello_model = require("mongodb.command.hello")
local operation_timeout = require("mongodb.operation_timeout")
local op_compressed = require("mongodb.wire.op_compressed")
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

local function client_error(state, message)
  return errors.new({
    category = errors.CATEGORY.CLIENT,
    message = message,
    server = state.server,
  })
end

local function available_compressors(values, compression)
  if values == nil then
    return {}
  end

  if type(values) ~= "table" then
    error("command executor compressors must be an array", 3)
  end

  local length = #values
  local available = {}

  for key in pairs(values) do
    if math.type(key) ~= "integer" or key < 1 or key > length then
      error("command executor compressors must be a dense array", 3)
    end
  end

  for index = 1, length do
    local name = values[index]

    if type(name) ~= "string" or name == "" then
      error("command executor compressors must contain non-empty strings", 3)
    end

    if compression[name] ~= nil then
      available[#available + 1] = name
    end
  end

  return available
end

local function negotiated_compressor(state, response)
  local values = response:get("compression")

  if values == nil then
    return nil
  end

  if not bson.is_array(values) then
    return nil, protocol_error("hello response contains an invalid compression field", {
      field = "compression",
    })
  end

  local supported = {}

  for _, name in values:iter() do
    if type(name) ~= "string" or name == "" then
      return nil, protocol_error("hello response contains an invalid compression field", {
        field = "compression",
      })
    end

    supported[name] = true
  end

  for _, name in ipairs(state.compressors) do
    if supported[name] then
      return state.compression[name]
    end
  end
end

local function compressor_for(state, command_name)
  local lower_name = command_name:lower()

  if lower_name == "hello" or lower_name == "ismaster"
      or command_security.is_always_sensitive(lower_name)
  then
    return nil
  end

  return state.compressor
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

local function server_error(state, response, sensitive)
  if sensitive then
    response = command_security.redact_server_response(response)
  end

  local message = sensitive and "sensitive command failed" or response:get("errmsg")

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

local function receive_response(state, expected_response_to, options, span, sensitive)
  local io_deadline = options.socket_deadline or options.deadline
  local response_bytes, err = state.connection:read_frame(
    state.max_message_size,
    io_deadline,
    options.cancellation
  )

  if not response_bytes then
    if span then
      span:failed(err)
    end

    return close_with(state, err)
  end

  local response

  if string.unpack("<i4", response_bytes, 13) == op_compressed.OP_CODE then
    response_bytes, err = op_compressed.decode(response_bytes, {
      compression = state.compression,
      max_message_size = state.max_message_size,
    })

    if not response_bytes then
      if span then
        span:failed(err)
      end

      return close_with(state, err)
    end
  end

  response, err = op_msg.decode(response_bytes, {
    direction = "response",
    expected_response_to = expected_response_to,
    max_bson_size = state.max_bson_size,
    max_message_size = state.max_message_size,
  })

  if not response then
    if span then
      span:failed(err)
    end

    return close_with(state, err)
  end

  if response.more_to_come and not options.exhaust_allowed then
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
    err = server_error(state, response.body, sensitive)

    if span then
      span:failed(err)
    end

    return nil, err
  end

  if options.exhaust_allowed then
    state.more_to_come = response.more_to_come
    state.next_response_to = response.request_id
  end

  if span then
    span:succeeded(response.body)
  end

  return response.body
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

  local err

  if options.apply_operation_timeout ~= false then
    command, err = operation_timeout.prepare_command(
      command,
      options.minimum_round_trip_time_ms
    )

    if not command then
      return nil, err
    end
  end

  if state.more_to_come then
    error("cannot send a command while an exhaust response is pending", 3)
  end

  local request_id = state.request_ids:next()
  local io_deadline = options.socket_deadline or options.deadline
  local body = envelope(command, database, state.server_api)
  local command_name = command:get_at(1)
  local flags = 0

  if options.no_response then
    flags = flags | op_msg.FLAG.MORE_TO_COME
  end

  if options.exhaust_allowed then
    flags = flags | op_msg.FLAG.EXHAUST_ALLOWED
  end

  local bytes
  bytes, err = op_msg.encode({
    body = body,
    flags = flags,
    max_bson_size = state.max_bson_size,
    max_message_size = state.max_message_size,
    max_sequence_document_size = options.max_sequence_document_size,
    request_id = request_id,
    sequences = options.sequences,
  })

  if not bytes then
    return nil, err
  end

  local compressor = compressor_for(state, command_name)

  if compressor then
    bytes, err = op_compressed.encode({
      body = bytes:sub(17),
      compression_level = state.zlib_compression_level,
      compressor = compressor,
      max_message_size = state.max_message_size,
      original_opcode = op_msg.OP_CODE,
      request_id = request_id,
    })

    if not bytes then
      return nil, err
    end
  end

  local span
  local sensitive = command_security.is_sensitive(command_name, command)

  if options.monitor ~= false and state.monitoring and state.monitoring:has_listeners() then
    span = state.monitoring:start({
      command = monitored_envelope(body, options.sequences),
      connection_id = state.server,
      database_name = database,
      operation_id = options.operation_id,
      request_id = request_id,
      server_connection_id = state.server_connection_id,
      server_host = state.server_host,
      server_port = state.server_port,
      service_id = state.service_id,
    })
  end

  local written
  written, err = state.connection:write_all(bytes, io_deadline, options.cancellation)

  if not written then
    if span then
      span:failed(err)
    end

    return close_with(state, err)
  end

  if options.no_response then
    local reply = bson.document({ { "ok", 1 } })

    if span then
      span:succeeded(reply)
    end

    return reply
  end

  return receive_response(state, request_id, options, span, sensitive)
end

function EXECUTOR_METHODS:hello(options)
  local state = EXECUTOR_STATES[self]
  local command_name = (state.load_balanced or state.server_api ~= nil or state.hello_ok)
    and "hello" or "ismaster"
  local entries = { { command_name, 1 } }

  if command_name == "ismaster" then
    entries[#entries + 1] = { "helloOk", true }
  end

  entries[#entries + 1] = { "backpressure", "2" }

  if not state.handshake_complete then
    entries[#entries + 1] = { "client", state.metadata }
    entries[#entries + 1] = { "compression", bson.array(state.compressors) }

    if state.load_balanced then
      entries[#entries + 1] = { "loadBalanced", true }
    end
  end

  options = options or {}

  if type(options) ~= "table" then
    error("hello options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "cancellation" and key ~= "deadline"
        and key ~= "max_await_time_ms" and key ~= "sasl_supported_mechs"
        and key ~= "speculative_authenticate"
        and key ~= "topology_version"
    then
      error("unknown hello option: " .. tostring(key), 2)
    end
  end

  if options.max_await_time_ms ~= nil
      and (math.type(options.max_await_time_ms) ~= "integer"
        or options.max_await_time_ms < 0)
  then
    error("max_await_time_ms must be a non-negative integer", 2)
  end

  if options.topology_version ~= nil
      and not bson.is_document(options.topology_version)
  then
    error("topology_version must be a BSON document", 2)
  end

  if (options.max_await_time_ms == nil) ~= (options.topology_version == nil) then
    error("awaitable hello requires topology_version and max_await_time_ms", 2)
  end

  if options.topology_version then
    entries[#entries + 1] = { "topologyVersion", options.topology_version }
    entries[#entries + 1] = { "maxAwaitTimeMS", options.max_await_time_ms }
  end

  if options.sasl_supported_mechs ~= nil then
    if type(options.sasl_supported_mechs) ~= "string"
        or options.sasl_supported_mechs == ""
    then
      error("sasl_supported_mechs must be a non-empty string", 2)
    end

    entries[#entries + 1] = {
      "saslSupportedMechs",
      options.sasl_supported_mechs,
    }
  end

  if options.speculative_authenticate ~= nil then
    if not bson.is_document(options.speculative_authenticate) then
      error("speculative_authenticate must be a BSON document", 2)
    end

    entries[#entries + 1] = {
      "speculativeAuthenticate",
      options.speculative_authenticate,
    }
  end

  local response
  local err

  if state.more_to_come then
    response, err = receive_response(state, state.next_response_to, {
      cancellation = options.cancellation,
      deadline = options.deadline,
      exhaust_allowed = true,
    })
  else
    response, err = execute(state, "admin", bson.document(entries), {
      apply_operation_timeout = false,
      cancellation = options.cancellation,
      deadline = options.deadline,
      exhaust_allowed = options.topology_version ~= nil,
      monitor = false,
    })
  end

  if not response then
    return nil, err
  end

  local hello
  hello, err = hello_model.new(response)

  if not hello then
    return close_with(state, err)
  end

  if state.load_balanced and hello.service_id == nil then
    return close_with(state, client_error(
      state,
      "Driver attempted to initialize in load balancing mode, "
        .. "but the server does not support this mode."
    ))
  end

  if not state.handshake_complete then
    state.compressor, err = negotiated_compressor(state, response)

    if err then
      return close_with(state, err)
    end
  end

  state.handshake_complete = true
  state.hello_ok = state.hello_ok or hello.hello_ok
  state.max_bson_size = hello.max_bson_size
  state.max_message_size = hello.max_message_size
  state.server_connection_id = hello.connection_id
  state.service_id = hello.service_id
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

function EXECUTOR_METHODS:measure(database, command, options)
  local state = EXECUTOR_STATES[self]

  if not state.handshake_complete then
    return nil, errors.new({
      category = errors.CATEGORY.CLIENT,
      message = "connection handshake must complete before measuring commands",
      server = state.server,
    })
  end

  options = options or {}

  if type(options) ~= "table" then
    error("command measure options must be a table", 2)
  end

  if type(database) ~= "string" or database == "" then
    error("command database must be a non-empty string", 2)
  end

  if not bson.is_document(command) then
    error("command must be a BSON document", 2)
  end

  local prepared, err = operation_timeout.prepare_command(
    command,
    options.minimum_round_trip_time_ms
  )

  if not prepared then
    return nil, err
  end

  return op_msg.measure({
    body = envelope(prepared, database, state.server_api),
    direction = "request",
    max_bson_size = state.max_bson_size,
    max_message_size = state.max_message_size,
    max_sequence_document_size = options.max_sequence_document_size,
    request_id = 1,
    sequences = options.sequences,
  })
end

function EXECUTOR_METHODS:capabilities()
  return EXECUTOR_STATES[self].hello
end

function EXECUTOR_METHODS:compressor()
  return EXECUTOR_STATES[self].compressor
end

function EXECUTOR_METHODS:compressor_for(command_name)
  if type(command_name) ~= "string" or command_name == "" then
    error("command name must be a non-empty string", 2)
  end

  return compressor_for(EXECUTOR_STATES[self], command_name)
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

  if options.metadata ~= nil and not bson.is_document(options.metadata) then
    error("command executor metadata must be a BSON document", 2)
  end

  if options.compression ~= nil and type(options.compression) ~= "table" then
    error("command executor compression capabilities must be a table", 2)
  end

  if options.load_balanced ~= nil and type(options.load_balanced) ~= "boolean" then
    error("command executor load_balanced must be a boolean", 2)
  end

  local zlib_compression_level = options.zlib_compression_level or -1

  if math.type(zlib_compression_level) ~= "integer"
      or zlib_compression_level < -1
      or zlib_compression_level > 9
  then
    error("command executor zlib compression level must be an integer from -1 through 9", 2)
  end

  local compression = options.compression or {}
  local value = {}

  EXECUTOR_STATES[value] = {
    compression = compression,
    compressor = nil,
    compressors = available_compressors(options.compressors, compression),
    connection = connection,
    handshake_complete = false,
    hello = nil,
    hello_ok = false,
    load_balanced = options.load_balanced == true,
    max_bson_size = DEFAULT_MAX_BSON_SIZE,
    max_message_size = DEFAULT_MAX_MESSAGE_SIZE,
    metadata = options.metadata or handshake_metadata.new(),
    monitoring = options.monitoring,
    more_to_come = false,
    next_response_to = nil,
    request_ids = options.request_ids or op_msg.request_ids(),
    server = options.server,
    server_connection_id = nil,
    server_host = options.server_host,
    server_port = options.server_port,
    server_api = options.server_api,
    service_id = nil,
    zlib_compression_level = zlib_compression_level,
  }

  return setmetatable(value, EXECUTOR_METATABLE)
end

return M
