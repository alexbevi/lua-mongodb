local runtime_contract = require("mongodb.runtime")
local operation_timeout = require("mongodb.operation_timeout")

local M = {}

local STATES = setmetatable({}, { __mode = "k" })
local METHODS = {}
local METATABLE = {
  __index = METHODS,
  __metatable = "mongodb.socket_timeout_executor",
  __newindex = function()
    error("MongoDB socket timeout executors are immutable", 2)
  end,
}

local function command_options(state, options)
  local result = {}

  for key, value in pairs(options or {}) do
    result[key] = value
  end

  if operation_timeout.current() == nil and state.timeout_ms > 0 then
    local function socket_deadline()
      local deadline = runtime_contract.deadline_after(
        state.runtime,
        state.timeout_ms / 1000
      )

      return result.deadline and math.min(result.deadline, deadline) or deadline
    end

    result.socket_deadline = socket_deadline()
    result.socket_deadline_factory = socket_deadline
  end

  return result
end

function METHODS:command(database, command, options)
  local state = STATES[self]
  return state.executor:command(database, command, command_options(state, options))
end

function METHODS:measure(database, command, options)
  local state = STATES[self]
  return state.executor:measure(database, command, command_options(state, options))
end

function METHODS:capabilities()
  return STATES[self].executor:capabilities()
end

function METHODS:close()
  return STATES[self].executor:close()
end

function M.new(executor, runtime, timeout_ms)
  if type(executor) ~= "table" or type(executor.command) ~= "function" then
    error("socket timeout executor requires a command executor", 2)
  end

  local value = {}

  STATES[value] = {
    executor = executor,
    runtime = runtime,
    timeout_ms = timeout_ms or 0,
  }
  return setmetatable(value, METATABLE)
end

return M
