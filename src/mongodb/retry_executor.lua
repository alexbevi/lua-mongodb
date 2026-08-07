local bson = require("mongodb.bson")
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
    if key ~= "retryable_read" and key ~= "retryable_write"
        and key ~= "on_attempt_error"
    then
      result[key] = value
    end
  end

  result.operation_id = id
  result.deprioritized_servers = deprioritized
  return result
end

local function retryable_read(err)
  return errors.is(err, errors.CATEGORY.NETWORK)
    or err:is_retryable()
    or RETRYABLE_CODES[err.code] == true
end

local function retryable_write(err)
  return errors.is(err, errors.CATEGORY.NETWORK)
    or err:has_label("RetryableWriteError")
    or (err:has_label("RetryableError")
      and err:has_label("SystemOverloadedError"))
end

local function labels_from(value)
  local labels = {}

  if bson.is_array(value) then
    for _, label in value:iter() do
      if type(label) == "string" then
        labels[#labels + 1] = label
      end
    end
  end

  return labels
end

local function write_concern_error(response)
  if not bson.is_document(response) then
    return nil
  end

  local concern = response:get("writeConcernError")

  if not bson.is_document(concern) then
    return nil
  end

  local labels = labels_from(response:get("errorLabels"))
  local code = concern:get("code")

  if bson.is_exact(code) then
    code = code:to_number()
  end

  local err = errors.new({
    category = errors.CATEGORY.WRITE,
    code = code,
    code_name = concern:get("codeName"),
    details = { response = response },
    labels = labels,
    message = concern:get("errmsg") or "write concern failed",
  })

  if retryable_write(err) then
    return err
  end
end

local function labelled_write_error(err)
  if errors.is(err, errors.CATEGORY.NETWORK)
      and not err:has_label("RetryableWriteError")
  then
    return errors.with_label(err, "RetryableWriteError")
  end

  return err
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
  local read = state.enabled_reads and options and options.retryable_read == true
  local write = state.enabled_writes and options and options.retryable_write == true
  local enabled = read or write

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

  if write and response then
    err = write_concern_error(response)

    if err then
      response = nil
    end
  end

  if write and err then
    err = labelled_write_error(err)
  end

  if response or not err then
    return response, err
  end

  notify(options, err)

  if not (read and retryable_read(err) or write and retryable_write(err)) then
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

  if write and retry_response then
    retry_err = write_concern_error(retry_response)

    if retry_err then
      retry_response = nil
    end
  end

  if write and retry_err then
    retry_err = labelled_write_error(retry_err)
  end

  if retry_response or not retry_err then
    return retry_response, retry_err
  end

  notify(options, retry_err)

  if write then
    local retry_attempted = not no_attempt(retry_err)
      and not retry_err:has_label("NoWritesPerformed")

    if retry_attempted then
      return nil, retry_err
    end

    return nil, err
  end

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
    if key ~= "enabled" and key ~= "enabled_reads" and key ~= "enabled_writes" then
      error("unknown retry executor option: " .. tostring(key), 2)
    end
  end

  for _, name in ipairs({ "enabled", "enabled_reads", "enabled_writes" }) do
    if options[name] ~= nil and type(options[name]) ~= "boolean" then
      error("retry executor " .. name .. " option must be a boolean", 2)
    end
  end

  local value = {}
  local enabled_reads = options.enabled_reads

  if enabled_reads == nil then
    enabled_reads = options.enabled ~= false
  end

  STATES[value] = {
    enabled_reads = enabled_reads,
    enabled_writes = options.enabled_writes == true,
    executor = executor,
  }
  return setmetatable(value, METATABLE)
end

return M
