local M = {}

local MAX_OPERATION_ID = 0x7fffffff
local STATES = setmetatable({}, { __mode = "k" })
local METHODS = {}
local METATABLE = {
  __index = METHODS,
  __metatable = "mongodb.operation_id.generator",
  __newindex = function()
    error("MongoDB operation ID generators are immutable", 2)
  end,
}

function METHODS:next()
  local state = STATES[self]
  local value = state.next_id

  state.next_id = value == MAX_OPERATION_ID and 1 or value + 1
  return value
end

function M.generator(first_id)
  first_id = first_id or 1

  if math.type(first_id) ~= "integer"
      or first_id < 1
      or first_id > MAX_OPERATION_ID
  then
    error("first operation ID must be an integer from 1 through 2147483647", 2)
  end

  local generator = {}

  STATES[generator] = { next_id = first_id }
  return setmetatable(generator, METATABLE)
end

local default_generator = M.generator()

function M.next()
  return default_generator:next()
end

return M
