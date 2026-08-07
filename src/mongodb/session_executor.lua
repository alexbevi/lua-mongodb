local M = {}
local errors = require("mongodb.error")

local STATES = setmetatable({}, { __mode = "k" })
local METHODS = {}
local METATABLE = {
  __index = METHODS,
  __metatable = "mongodb.session_executor",
  __newindex = function()
    error("MongoDB session executors are immutable", 2)
  end,
}

local function command_options(options, on_attempt_error)
  local result = {}

  for key, value in pairs(options or {}) do
    if key ~= "no_session" and key ~= "session" and key ~= "session_context"
        and key ~= "read_concern"
    then
      result[key] = value
    end
  end

  result.on_attempt_error = on_attempt_error
  return result
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

local function prepared_command(state, command, options, session)
  if session == nil then
    return command
  end

  return state.manager:decorate(command, {
    read_concern = options and options.read_concern,
    session = session,
  })
end

function METHODS:command(database, command, options)
  local state = STATES[self]
  local session, owned, err = command_session(state, options)

  if err then
    return nil, err
  end

  local decorated
  decorated, err = prepared_command(state, command, options, session)

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

  response, err = state.executor:command(
    database,
    decorated,
    command_options(options, on_attempt_error)
  )

  if response and state.manager then
    state.manager:advance(response, session)
  elseif err and session then
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
  decorated, err = prepared_command(state, command, options, session)

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

function M.new(executor, manager)
  if type(executor) ~= "table" or type(executor.command) ~= "function"
      or type(executor.close) ~= "function"
  then
    error("session executor requires a command executor", 2)
  end

  if manager ~= nil and type(manager) ~= "table" then
    error("session executor manager must be a table", 2)
  end

  local value = {}

  STATES[value] = { executor = executor, manager = manager }
  return setmetatable(value, METATABLE)
end

return M
