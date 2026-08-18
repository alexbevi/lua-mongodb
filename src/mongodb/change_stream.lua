local M = {}

local STREAM_STATES = setmetatable({}, { __mode = "k" })
local STREAM_METHODS = {}

local function immutable()
  error("MongoDB change streams are immutable", 2)
end

local STREAM_METATABLE = {
  __index = function(_, key)
    return STREAM_METHODS[key]
  end,
  __metatable = "mongodb.change_stream",
  __newindex = immutable,
}

function STREAM_METHODS:next()
  return STREAM_STATES[self].cursor:next()
end

function STREAM_METHODS:iter()
  return function()
    return self:next()
  end
end

function STREAM_METHODS:is_closed()
  return STREAM_STATES[self].cursor:is_closed()
end

function STREAM_METHODS:close(options)
  return STREAM_STATES[self].cursor:close(options)
end

function M.new(cursor)
  if type(cursor) ~= "table"
      or type(cursor.next) ~= "function"
      or type(cursor.close) ~= "function"
      or type(cursor.is_closed) ~= "function"
  then
    error("change stream creation requires a cursor", 2)
  end

  local value = {}

  STREAM_STATES[value] = { cursor = cursor }
  return setmetatable(value, STREAM_METATABLE)
end

return M
