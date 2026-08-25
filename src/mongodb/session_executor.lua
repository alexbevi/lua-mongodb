local M = {}
local errors = require("mongodb.error")
local operation_timeout = require("mongodb.operation_timeout")

local STATES = setmetatable({}, { __mode = "k" })
local METHODS = {}
local METATABLE = {
  __index = METHODS,
  __metatable = "mongodb.session_executor",
  __newindex = function()
    error("MongoDB session executors are immutable", 2)
  end,
}

local function command_options(
  options,
  on_attempt_error,
  retryable_write,
  in_transaction,
  session
)
  local result = {}

  for key, value in pairs(options or {}) do
    if key ~= "no_session" and key ~= "session" and key ~= "session_context"
        and key ~= "read_concern" and key ~= "retryable_read"
        and key ~= "transaction_control"
    then
      result[key] = value
    end
  end

  result.on_attempt_error = on_attempt_error
  result.retryable_read = options and options.retryable_read == true
    and not in_transaction
  result.retryable_write = retryable_write
  result.session = session
  return result
end

local function pin_transaction(options, session, in_transaction)
  if not in_transaction then
    session:unpin_server()
    return
  end

  local selected = options.on_server_selected

  options.server_address = session:get_pinned_server_address()
  options.on_server_selected = function(address, server_type)
    if selected then
      selected(address, server_type)
    end

    session:pin_server(address, server_type)
  end

  if not session:uses_connection_pinning() then
    return
  end

  local pinned_connection = session:get_pinned_connection()

  if pinned_connection then
    options.on_connection_pinned = nil
    options.pin_connection = nil
    options.pinned_connection = pinned_connection
  else
    options.on_connection_pinned = function(pin)
      assert(session:pin_connection(pin))
    end
    options.pin_connection = true
    options.pinned_connection = nil
  end
end

local function apply_error(state, session, err)
  local error_response = err.details and err.details.response

  if state.manager and error_response then
    state.manager:advance(error_response, session)
  end

  if errors.is(err, errors.CATEGORY.NETWORK)
      or errors.is(err, errors.CATEGORY.PROTOCOL)
  then
    session:mark_dirty()
  end
end

local function transaction_error(session, err, transaction_control)
  if transaction_control or not session:is_in_transaction() then
    return err
  end

  if errors.is(err, errors.CATEGORY.NETWORK)
      or errors.is(err, errors.CATEGORY.TIMEOUT)
  then
    err = errors.with_label(err, "TransientTransactionError")
  end

  err = errors.without_label(err, "RetryableWriteError")
  err = errors.without_label(err, "UnknownTransactionCommitResult")

  if err:has_label("TransientTransactionError") then
    session:unpin_server()
  end

  return err
end

local function command_session(state, options)
  options = options or {}

  if options.no_session then
    return nil, false
  end

  if options.session ~= nil then
    if state.manager == nil then
      return nil, false, errors.new({
        category = errors.CATEGORY.CLIENT,
        message = "deployment does not support sessions",
      })
    end

    return options.session, false
  end

  if state.manager == nil then
    return nil, false
  end

  local context = options.session_context

  if context and context.session then
    return context.session, false
  end

  local session, err = state.manager:start({ causal_consistency = false })

  if not session then
    return nil, false, err
  end

  if context then
    context.session = session
  end

  return session, context == nil
end

local function prepared_command(
  state,
  command,
  options,
  session,
  retryable_write,
  measurement
)
  if session == nil then
    return command
  end

  return state.manager:decorate(command, {
    max_wire_version = state.max_wire_version,
    read_concern = options and options.read_concern,
    read_preference = options and options.read_preference,
    retryable_write = retryable_write,
    session = session,
    transaction_control = options and options.transaction_control == true,
    measurement = measurement == true,
  })
end

function METHODS:command(database, command, options)
  local state = STATES[self]
  local requested_retryable_write = options and options.retryable_write == true
  local transaction_control = options and options.transaction_control == true
  local session, owned, err = command_session(state, options)
  local in_transaction = session and session:is_in_transaction() or false

  local retryable_write = requested_retryable_write
    and state.retryable_writes
    and (not in_transaction or transaction_control)

  if err then
    return nil, err
  end

  local decorated
  decorated, err = prepared_command(
    state,
    command,
    options,
    session,
    retryable_write
  )

  if not decorated then
    if owned then
      session:end_session()
    end

    return nil, err
  end

  local response
  local on_attempt_error

  if session then
    on_attempt_error = function(attempt_err)
      apply_error(state, session, attempt_err)
    end
  end

  local downstream_options = command_options(
    options,
    on_attempt_error,
    retryable_write,
    in_transaction,
    session
  )

  if session then
    pin_transaction(downstream_options, session, in_transaction)
  end

  local context = operation_timeout.current()
  local session_runtime, session_timeout_ms

  if session and type(session.get_timeout_context) == "function" then
    session_runtime, session_timeout_ms = session:get_timeout_context()
  end

  if session_timeout_ms ~= nil and options and options.session ~= nil
      and not (context and context.explicit_timeout)
  then
    response, err = operation_timeout.run(
      session_runtime,
      session_timeout_ms,
      downstream_options,
      function(prepared)
        return state.executor:command(database, decorated, prepared)
      end
    )
  else
    response, err = state.executor:command(database, decorated, downstream_options)
  end

  if response and state.manager then
    state.manager:advance(response, session)
  elseif err and session then
    err = transaction_error(session, err, transaction_control)
    apply_error(state, session, err)
  end

  if owned then
    session:end_session()
  end

  return response, err
end

function METHODS:measure(database, command, options)
  local state = STATES[self]
  local session, owned, err = command_session(state, options)

  if err then
    return nil, err
  end

  local decorated
  decorated, err = prepared_command(state, command, options, session, false, true)

  if not decorated then
    if owned then
      session:end_session()
    end

    return nil, err
  end

  local measurement
  measurement, err = state.executor:measure(
    database,
    decorated,
    command_options(options)
  )

  if owned then
    session:end_session()
  end

  return measurement, err
end

function METHODS:capabilities()
  local executor = STATES[self].executor

  if type(executor.capabilities) == "function" then
    return executor:capabilities()
  end
end

function METHODS.release_session_context(_, context)
  if type(context) ~= "table" then
    error("session context must be a table", 2)
  end

  local session = context.session

  if session == nil then
    return false
  end

  context.session = nil
  return session:end_session()
end

function METHODS:close()
  return STATES[self].executor:close()
end

function M.new(executor, manager, options)
  if type(executor) ~= "table" or type(executor.command) ~= "function"
      or type(executor.close) ~= "function"
  then
    error("session executor requires a command executor", 2)
  end

  if manager ~= nil and type(manager) ~= "table" then
    error("session executor manager must be a table", 2)
  end

  options = options or {}

  if type(options) ~= "table" then
    error("session executor options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "max_wire_version" and key ~= "retryable_writes" then
      error("unknown session executor option: " .. tostring(key), 2)
    end
  end

  if options.max_wire_version ~= nil
      and (math.type(options.max_wire_version) ~= "integer"
        or options.max_wire_version < 0)
  then
    error("max_wire_version must be a non-negative integer", 2)
  end

  if options.retryable_writes ~= nil
      and type(options.retryable_writes) ~= "boolean"
  then
    error("retryable_writes must be a boolean", 2)
  end

  local value = {}

  STATES[value] = {
    executor = executor,
    manager = manager,
    max_wire_version = options.max_wire_version,
    retryable_writes = options.retryable_writes == true,
  }
  return setmetatable(value, METATABLE)
end

return M
