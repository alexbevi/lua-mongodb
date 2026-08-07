local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime")

local M = {}

local CONTEXTS = setmetatable({}, { __mode = "k" })
local MAIN = {}

local function context_key()
  return coroutine.running() or MAIN
end

local function copy_options(options)
  local result = {}

  for key, value in pairs(options or {}) do
    if key ~= "timeout_ms" then
      result[key] = value
    end
  end

  return result
end

function M.current()
  return CONTEXTS[context_key()]
end

function M.capture()
  return M.current()
end

local function without_wtimeout(value)
  if not bson.is_document(value) then
    return value
  end

  local entries = {}

  for key, item in value:iter() do
    if key ~= "wtimeout" and key ~= "wtimeoutMS" then
      entries[#entries + 1] = { key, item }
    end
  end

  return #entries > 0 and bson.document(entries) or nil
end

local function transformed_timeout(err)
  if not errors.is(err) then
    return err
  end

  if err.details and err.details.csot == true then
    return err
  end

  if not err:is_timeout() and err.code ~= 50 then
    return err
  end

  local labels = {}

  for index, label in ipairs(err.labels) do
    labels[index] = label
  end

  return errors.new({
    category = errors.CATEGORY.TIMEOUT,
    cause = err,
    details = { csot = true },
    labels = labels,
    message = "client-side operation timeout: " .. tostring(err),
    server = err.server,
  })
end

function M.prepare_command(command, minimum_round_trip_time_ms)
  local context = M.current()

  if context == nil then
    return command
  end

  local entries = {}
  local name = command:keys()[1]

  for key, value in command:iter() do
    if key ~= "maxTimeMS" or name == "getMore" or context.deadline == nil then
      if key == "writeConcern" then
        value = without_wtimeout(value)
      end

      if value ~= nil then
        entries[#entries + 1] = { key, value }
      end
    end
  end

  if context.deadline ~= nil and name ~= "getMore"
      and not context.omit_max_time_ms
  then
    local remaining_ms = (context.deadline - context.runtime.clock:now()) * 1000
    local budget = math.floor(remaining_ms - (minimum_round_trip_time_ms or 0))

    if budget <= 0 then
      return nil, transformed_timeout(runtime_contract.timeout_error())
    end

    entries[#entries + 1] = { "maxTimeMS", bson.int64(math.max(1, budget)) }
  end

  return bson.document(entries)
end

function M.run(runtime, inherited_timeout_ms, options, callback)
  options = options or {}

  if type(options) ~= "table" then
    error("operation options must be a table", 2)
  end

  local parent_context = M.current()

  if parent_context and parent_context.in_transaction_callback
      and options.timeout_ms ~= nil
  then
    return nil, errors.new({
      category = errors.CATEGORY.CLIENT,
      message = "timeout_ms cannot be overridden inside with_transaction",
    })
  end

  local timeout_ms = options.timeout_ms

  if timeout_ms == nil then
    timeout_ms = inherited_timeout_ms
  elseif math.type(timeout_ms) ~= "integer" or timeout_ms < 0 then
    error("timeout_ms must be a non-negative integer", 2)
  end

  local timeout_mode = options.timeout_mode

  if timeout_mode ~= nil and timeout_mode ~= "cursor_lifetime"
      and timeout_mode ~= "iteration"
  then
    error("timeout_mode must be cursor_lifetime or iteration", 2)
  end

  if timeout_mode ~= nil and timeout_ms == nil then
    return nil, errors.new({
      category = errors.CATEGORY.CLIENT,
      message = "timeout_mode requires timeout_ms",
    })
  end

  local prepared = copy_options(options)

  if timeout_ms == nil then
    return callback(prepared)
  end

  if type(runtime) ~= "table" or type(runtime.clock) ~= "table"
      or type(runtime.clock.now) ~= "function"
  then
    error("client-side operation timeout requires a runtime clock", 2)
  end

  local key = context_key()
  local parent = CONTEXTS[key]
  local deadline

  if timeout_ms > 0 then
    deadline = runtime_contract.deadline_after(runtime, timeout_ms / 1000)
  end

  if parent and parent.deadline and deadline then
    deadline = math.min(parent.deadline, deadline)
  elseif parent and parent.deadline and options.timeout_ms == nil then
    deadline = parent.deadline
  end

  local context = {
    deadline = deadline,
    explicit_timeout = options.timeout_ms ~= nil,
    omit_max_time_ms = timeout_mode == "iteration",
    runtime = runtime,
    timeout_mode = timeout_mode or "cursor_lifetime",
    timeout_ms = timeout_ms,
  }

  CONTEXTS[key] = context
  prepared.deadline = prepared.deadline and deadline
    and math.min(prepared.deadline, deadline) or prepared.deadline or deadline

  local outcome = table.pack(pcall(callback, prepared))

  CONTEXTS[key] = parent

  if not outcome[1] then
    error(outcome[2], 0)
  end

  if outcome[2] == nil and errors.is(outcome[3]) then
    outcome[3] = transformed_timeout(outcome[3])
  end

  return table.unpack(outcome, 2, outcome.n)
end

function M.transaction_callback(callback, ...)
  local context = M.current()

  if context == nil then
    return callback(...)
  end

  local previous = context.in_transaction_callback

  context.in_transaction_callback = true
  local outcome = table.pack(pcall(callback, ...))

  context.in_transaction_callback = previous

  if not outcome[1] then
    error(outcome[2], 0)
  end

  return table.unpack(outcome, 2, outcome.n)
end

function M.resume(context, refresh, callback)
  if context == nil then
    return callback({})
  end

  local key = context_key()
  local parent = CONTEXTS[key]
  local active = context

  if refresh then
    local deadline

    if context.timeout_ms > 0 then
      deadline = runtime_contract.deadline_after(
        context.runtime,
        context.timeout_ms / 1000
      )
    end

    active = {
      deadline = deadline,
      runtime = context.runtime,
      timeout_mode = context.timeout_mode,
      timeout_ms = context.timeout_ms,
    }
  end

  CONTEXTS[key] = active
  local outcome = table.pack(pcall(callback, { deadline = active.deadline }))

  CONTEXTS[key] = parent

  if not outcome[1] then
    error(outcome[2], 0)
  end

  if outcome[2] == nil and errors.is(outcome[3]) then
    outcome[3] = transformed_timeout(outcome[3])
  end

  return table.unpack(outcome, 2, outcome.n)
end

return M
