local bson = require("mongodb.bson")
local command_security = require("mongodb.command.security")
local errors = require("mongodb.error")

local M = {}

local EVENT_STATES = setmetatable({}, { __mode = "k" })
local EVENT_METATABLE = {
  __index = function(event, key)
    local state = EVENT_STATES[event]
    return state and state[key] or nil
  end,
  __metatable = "mongodb.monitoring.event",
  __newindex = function()
    error("command monitoring events are immutable", 2)
  end,
}
local MONITOR_STATES = setmetatable({}, { __mode = "k" })
local MONITOR_METHODS = {}
local MONITOR_METATABLE = {
  __index = MONITOR_METHODS,
  __metatable = "mongodb.command_monitor",
  __newindex = function()
    error("command monitors are immutable", 2)
  end,
}
local SPAN_STATES = setmetatable({}, { __mode = "k" })
local SPAN_METHODS = {}
local SPAN_METATABLE = {
  __index = SPAN_METHODS,
  __metatable = "mongodb.command_monitor_span",
  __newindex = function()
    error("command monitor spans are immutable", 2)
  end,
}

local function new_event(fields)
  local event = {}

  EVENT_STATES[event] = fields
  return setmetatable(event, EVENT_METATABLE)
end

local function dense_listeners(listeners)
  if type(listeners) ~= "table" then
    error("command listeners must be an array", 3)
  end

  local copied = {}

  for index = 1, #listeners do
    local listener = listeners[index]

    if type(listener) ~= "table" then
      error("command listeners must be tables", 3)
    end

    for _, name in ipairs({ "started", "succeeded", "failed" }) do
      if listener[name] ~= nil and type(listener[name]) ~= "function" then
        error("command listener " .. name .. " callback must be a function", 3)
      end
    end

    copied[index] = listener
  end

  for key in pairs(listeners) do
    if math.type(key) ~= "integer" or key < 1 or key > #listeners then
      error("command listeners must be an array", 3)
    end
  end

  return copied
end

local function notify_listener_error(state, err)
  if state.on_listener_error then
    pcall(state.on_listener_error, err)
  end
end

local function publish(state, callback_name, event)
  for _, listener in ipairs(state.listeners) do
    local callback = listener[callback_name]

    if callback then
      local ok, err = pcall(callback, listener, event)

      if not ok then
        notify_listener_error(state, err)
      end
    end
  end
end

local function empty_document()
  return bson.document({})
end

local function redacted_failure(failure)
  if not errors.is(failure, errors.CATEGORY.SERVER) then
    return failure
  end

  local response = failure.details and failure.details.response

  return command_security.redact_server_response(response)
end

local function common_fields(span_state, event_type, duration_ms)
  local fields = {
    command_name = span_state.command_name,
    connection_id = span_state.connection_id,
    database_name = span_state.database_name,
    operation_id = span_state.operation_id,
    request_id = span_state.request_id,
    server_connection_id = span_state.server_connection_id,
    service_id = span_state.service_id,
    type = event_type,
  }

  if duration_ms ~= nil then
    fields.duration_ms = duration_ms
  end

  return fields
end

local function common_log_fields(span_state, message, duration_ms)
  local fields = {
    commandName = span_state.command_name,
    databaseName = span_state.database_name,
    driverConnectionId = span_state.driver_connection_id,
    message = message,
    requestId = span_state.request_id,
    serverHost = span_state.server_host,
    serverPort = span_state.server_port,
  }

  if duration_ms ~= nil then
    fields.durationMS = duration_ms
  end

  return fields
end

local function emit_log(span_state, outcome, value, duration_ms)
  local logger = span_state.monitor.logger

  if logger == nil then
    return
  end

  local messages = {
    failed = "Command failed",
    started = "Command started",
    succeeded = "Command succeeded",
  }
  local fields = common_log_fields(span_state, messages[outcome], duration_ms)
  local document_fields

  if outcome == "started" then
    fields.command = value
    document_fields = { command = span_state.sensitive }
  elseif outcome == "succeeded" then
    fields.reply = value
    document_fields = { reply = span_state.sensitive }
  else
    fields.failure = span_state.sensitive and redacted_failure(value) or value
  end

  logger:emit("command", "debug", fields, {
    document_fields = document_fields,
  })
end

local function finish(span, outcome, value)
  local span_state = SPAN_STATES[span]

  if span_state.finished then
    error("command monitor span already finished", 3)
  end

  span_state.finished = true
  local duration_ms = math.max(
    0,
    (span_state.monitor.clock:now() - span_state.started_at) * 1000
  )
  local fields = common_fields(span_state, "command_" .. outcome, duration_ms)

  if outcome == "succeeded" then
    fields.reply = span_state.sensitive and empty_document() or value
  else
    fields.failure = span_state.sensitive and redacted_failure(value) or value
  end

  local event = new_event(fields)

  emit_log(span_state, outcome, value, duration_ms)
  publish(span_state.monitor, outcome, event)
  return event
end

function SPAN_METHODS:succeeded(reply)
  if not bson.is_document(reply) then
    error("command success reply must be a BSON document", 2)
  end

  return finish(self, "succeeded", reply)
end

function SPAN_METHODS:failed(failure)
  if not errors.is(failure) then
    error("command failure must be a structured error", 2)
  end

  return finish(self, "failed", failure)
end

function MONITOR_METHODS:start(fields)
  if type(fields) ~= "table" then
    error("command monitoring fields must be a table", 2)
  end

  if not bson.is_document(fields.command) then
    error("monitored command must be a BSON document", 2)
  end

  if type(fields.database_name) ~= "string" or fields.database_name == "" then
    error("monitored database_name must be a non-empty string", 2)
  end

  if math.type(fields.request_id) ~= "integer" then
    error("monitored request_id must be an integer", 2)
  end

  if fields.operation_id ~= nil and math.type(fields.operation_id) ~= "integer" then
    error("monitored operation_id must be an integer", 2)
  end

  if fields.driver_connection_id ~= nil
      and math.type(fields.driver_connection_id) ~= "integer"
  then
    error("monitored driver_connection_id must be an integer", 2)
  end

  local command_name = fields.command:get_at(1)

  if not command_name then
    error("monitored command must not be empty", 2)
  end

  local monitor_state = MONITOR_STATES[self]
  local sensitive = command_security.is_sensitive(command_name, fields.command)
  local operation_id = fields.operation_id or fields.request_id
  local span = {}

  SPAN_STATES[span] = {
    command_name = command_name,
    connection_id = fields.connection_id,
    database_name = fields.database_name,
    driver_connection_id = fields.driver_connection_id,
    finished = false,
    monitor = monitor_state,
    operation_id = operation_id,
    request_id = fields.request_id,
    sensitive = sensitive,
    server_connection_id = fields.server_connection_id,
    server_host = fields.server_host,
    server_port = fields.server_port,
    service_id = fields.service_id,
    started_at = monitor_state.clock:now(),
  }

  local event_fields = common_fields(SPAN_STATES[span], "command_started")

  event_fields.command = sensitive and empty_document() or fields.command
  emit_log(SPAN_STATES[span], "started", fields.command)
  publish(monitor_state, "started", new_event(event_fields))
  return setmetatable(span, SPAN_METATABLE)
end

function MONITOR_METHODS:has_listeners()
  local state = MONITOR_STATES[self]

  return #state.listeners > 0
    or state.logger ~= nil and state.logger:enabled("command", "debug")
end

function M.new(options)
  options = options or {}

  if type(options) ~= "table" then
    error("command monitoring options must be a table", 2)
  end

  local clock = options.clock

  if type(clock) ~= "table" or type(clock.now) ~= "function" then
    error("command monitoring requires a monotonic clock capability", 2)
  end

  if options.on_listener_error ~= nil and type(options.on_listener_error) ~= "function" then
    error("on_listener_error must be a function", 2)
  end

  if options.logger ~= nil
      and (type(options.logger) ~= "table"
        or type(options.logger.enabled) ~= "function"
        or type(options.logger.emit) ~= "function")
  then
    error("command monitoring logger must support enabled and emit", 2)
  end

  local monitor = {}

  MONITOR_STATES[monitor] = {
    clock = clock,
    logger = options.logger,
    listeners = dense_listeners(options.listeners or {}),
    on_listener_error = options.on_listener_error,
  }

  return setmetatable(monitor, MONITOR_METATABLE)
end

return M
