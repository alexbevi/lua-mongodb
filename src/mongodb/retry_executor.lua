local errors = require("mongodb.error")

local M = {}

local STATES = setmetatable({}, { __mode = "k" })
local METHODS = {}
local next_operation_id = 1

local RETRYABLE_CODES = {
  [6] = true,
  [7] = true,
  [89] = true,
  [91] = true,
  [134] = true,
  [189] = true,
  [262] = true,
  [9001] = true,
  [10107] = true,
  [11600] = true,
  [11602] = true,
  [13435] = true,
  [13436] = true,
}

local METATABLE = {
  __index = METHODS,
  __metatable = "mongodb.retry_executor",
  __newindex = function()
    error("MongoDB retry executors are immutable", 2)
  end,
}

local function operation_id()
  local value = next_operation_id

  next_operation_id = value == 0x7fffffff and 1 or value + 1
  return value
end

local function attempt_options(options, id, deprioritized)
  local result = {}

  for key, value in pairs(options or {}) do
    if key ~= "retryable_read" and key ~= "on_attempt_error" then
      result[key] = value
    end
  end

  result.operation_id = id
  result.deprioritized_servers = deprioritized
  return result
end

local function retryable(err)
  return errors.is(err, errors.CATEGORY.NETWORK)
    or err:is_retryable()
    or RETRYABLE_CODES[err.code] == true
end

local function no_attempt(err)
  return errors.is(err, errors.CATEGORY.SERVER_SELECTION)
    or errors.is(err, errors.CATEGORY.POOL)
    or errors.is(err, errors.CATEGORY.TOPOLOGY)
end

local function notify(options, err)
  if options and options.on_attempt_error then
    options.on_attempt_error(err)
  end
end

function METHODS:command(database, command, options)
  local state = STATES[self]
  local enabled = state.enabled and options and options.retryable_read == true

  if not enabled then
    return state.executor:command(
      database,
      command,
      attempt_options(options, options and options.operation_id)
    )
  end

  local id = options.operation_id or operation_id()
  local response, err = state.executor:command(
    database,
    command,
    attempt_options(options, id)
  )

  if response or not err then
    return response, err
  end

  notify(options, err)

  if not retryable(err) then
    return nil, err
  end

  local deprioritized

  if err.server and err:has_label("SystemOverloadedError") then
    deprioritized = { err.server }
  end

  local retry_response, retry_err = state.executor:command(
    database,
    command,
    attempt_options(options, id, deprioritized)
  )

  if retry_response or not retry_err then
    return retry_response, retry_err
  end

  notify(options, retry_err)
  return nil, no_attempt(retry_err) and err or retry_err
end

function METHODS:measure(database, command, options)
  return STATES[self].executor:measure(
    database,
    command,
    attempt_options(options, options and options.operation_id)
  )
end

function METHODS:capabilities()
  local executor = STATES[self].executor

  if type(executor.capabilities) == "function" then
    return executor:capabilities()
  end
end

function METHODS:close()
  return STATES[self].executor:close()
end

function M.new(executor, options)
  if type(executor) ~= "table" or type(executor.command) ~= "function"
      or type(executor.close) ~= "function"
  then
    error("retry executor requires a command executor", 2)
  end

  options = options or {}

  if type(options) ~= "table" then
    error("retry executor options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "enabled" then
      error("unknown retry executor option: " .. tostring(key), 2)
    end
  end

  if options.enabled ~= nil and type(options.enabled) ~= "boolean" then
    error("retry executor enabled option must be a boolean", 2)
  end

  local value = {}

  STATES[value] = { enabled = options.enabled ~= false, executor = executor }
  return setmetatable(value, METATABLE)
end

return M
