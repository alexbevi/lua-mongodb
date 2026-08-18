local errors = require("mongodb.error")

local M = {}

local STATES = setmetatable({}, { __mode = "k" })
local METHODS = {}
local METATABLE = {
  __index = METHODS,
  __metatable = "mongodb.standalone_executor",
  __newindex = function()
    error("MongoDB standalone executors are immutable", 2)
  end,
}

local function ensure_executor(state, options)
  if state.closed then
    return nil, errors.new({
      category = errors.CATEGORY.CLIENT,
      message = "standalone executor is closed",
    })
  end

  if state.executor then
    return state.executor
  end

  local executor, err = state.factory(options or {})

  if not executor then
    return nil, err
  end

  state.executor = executor
  return executor
end

local function discard_failed(state, err)
  if errors.is(err, errors.CATEGORY.NETWORK)
      or errors.is(err, errors.CATEGORY.PROTOCOL)
      or errors.is(err, errors.CATEGORY.CANCELLED)
  then
    state.executor:close()
    state.executor = nil
  end
end

function METHODS:command(database, command, options)
  local state = STATES[self]
  local executor, err = ensure_executor(state, options)

  if not executor then
    return nil, err
  end

  local response
  response, err = executor:command(database, command, options)

  if err then
    discard_failed(state, err)
  end

  return response, err
end


function METHODS:measure(database, command, options)
  local state = STATES[self]
  local executor, err = ensure_executor(state, options)

  if not executor then
    return nil, err
  end

  local measurement
  measurement, err = executor:measure(database, command, options)

  return measurement, err
end


function METHODS:capabilities()
  return STATES[self].capabilities
end

function METHODS:close()
  local state = STATES[self]

  if state.closed then
    return false
  end

  state.closed = true

  if state.executor then
    state.executor:close()
    state.executor = nil
  end

  return true
end

function M.new(executor, factory, capabilities)
  if type(executor) ~= "table" or type(executor.command) ~= "function"
      or type(executor.close) ~= "function"
  then
    error("standalone executor requires an initial command executor", 2)
  end

  if type(factory) ~= "function" then
    error("standalone executor requires a connection factory", 2)
  end

  local value = {}

  STATES[value] = {
    capabilities = capabilities,
    closed = false,
    executor = executor,
    factory = factory,
  }
  return setmetatable(value, METATABLE)
end

return M
