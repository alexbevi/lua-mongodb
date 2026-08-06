local M = {}

local BINARY_SUBTYPE_VALUES = {
  COLUMN = 7,
  ENCRYPTED = 6,
  FUNCTION = 1,
  GENERIC = 0,
  MD5 = 5,
  OLD_BINARY = 2,
  OLD_UUID = 3,
  SENSITIVE = 8,
  USER_DEFINED = 128,
  UUID = 4,
  VECTOR = 9,
}

local ARRAY_STATES = setmetatable({}, { __mode = "k" })
local BINARY_STATES = setmetatable({}, { __mode = "k" })
local DOCUMENT_STATES = setmetatable({}, { __mode = "k" })

local function immutable_value()
  error("BSON values are immutable", 2)
end

local function require_sequence(name, values)
  if type(values) ~= "table" then
    error(name .. " values must be an array", 3)
  end

  local length = #values

  for key in pairs(values) do
    if math.type(key) ~= "integer" or key < 1 or key > length then
      error(name .. " values must be a dense array", 3)
    end
  end

  return length
end

local ARRAY_METHODS = {}
local ARRAY_METATABLE = {
  __metatable = "mongodb.bson.array",
  __newindex = immutable_value,
}

function ARRAY_METHODS:get(index)
  if math.type(index) ~= "integer" or index < 1 then
    error("array index must be a positive integer", 2)
  end

  return ARRAY_STATES[self][index]
end

function ARRAY_METHODS:values()
  local state = ARRAY_STATES[self]
  local values = {}

  for index = 1, #state do
    values[index] = state[index]
  end

  return values
end

function ARRAY_METHODS:iter()
  local state = ARRAY_STATES[self]
  local index = 0

  return function()
    index = index + 1

    if index <= #state then
      return index, state[index]
    end
  end
end

ARRAY_METATABLE.__index = ARRAY_METHODS
ARRAY_METATABLE.__len = function(value)
  return #ARRAY_STATES[value]
end

local BINARY_METHODS = {}
local BINARY_METATABLE = {
  __metatable = "mongodb.bson.binary",
  __newindex = immutable_value,
}

BINARY_METATABLE.__eq = function(left, right)
  local left_state = BINARY_STATES[left]
  local right_state = BINARY_STATES[right]
  return left_state ~= nil and right_state ~= nil
    and left_state.data == right_state.data
    and left_state.subtype == right_state.subtype
end

BINARY_METATABLE.__index = function(value, key)
  if BINARY_METHODS[key] then
    return BINARY_METHODS[key]
  end

  local state = BINARY_STATES[value]
  return state and state[key] or nil
end

local DOCUMENT_METHODS = {}
local DOCUMENT_METATABLE = {
  __metatable = "mongodb.bson.document",
  __newindex = immutable_value,
}

function DOCUMENT_METHODS:get(key)
  if type(key) ~= "string" then
    error("document key must be a string", 2)
  end

  local entries = DOCUMENT_STATES[self]

  for index = #entries, 1, -1 do
    if entries[index][1] == key then
      return entries[index][2]
    end
  end
end

function DOCUMENT_METHODS:get_at(index)
  if math.type(index) ~= "integer" or index < 1 then
    error("document index must be a positive integer", 2)
  end

  local entry = DOCUMENT_STATES[self][index]

  if entry then
    return entry[1], entry[2]
  end
end

function DOCUMENT_METHODS:keys()
  local entries = DOCUMENT_STATES[self]
  local keys = {}

  for index = 1, #entries do
    keys[index] = entries[index][1]
  end

  return keys
end

function DOCUMENT_METHODS:entries()
  local state = DOCUMENT_STATES[self]
  local entries = {}

  for index = 1, #state do
    entries[index] = { state[index][1], state[index][2] }
  end

  return entries
end

function DOCUMENT_METHODS:iter()
  local entries = DOCUMENT_STATES[self]
  local index = 0

  return function()
    index = index + 1

    if index <= #entries then
      return entries[index][1], entries[index][2]
    end
  end
end

DOCUMENT_METATABLE.__index = DOCUMENT_METHODS
DOCUMENT_METATABLE.__len = function(value)
  return #DOCUMENT_STATES[value]
end

local NULL = setmetatable({}, {
  __metatable = "mongodb.bson.null",
  __newindex = immutable_value,
  __tostring = function()
    return "null"
  end,
})

M.BINARY_SUBTYPE = setmetatable({}, {
  __index = BINARY_SUBTYPE_VALUES,
  __metatable = "mongodb.bson.binary_subtypes",
  __newindex = immutable_value,
  __pairs = function()
    return next, BINARY_SUBTYPE_VALUES, nil
  end,
})
M.null = NULL

function M.array(values)
  local length = require_sequence("array", values)
  local state = {}
  local value = {}

  for index = 1, length do
    if values[index] == nil then
      error("array values cannot contain nil; use bson.null", 2)
    end

    state[index] = values[index]
  end

  ARRAY_STATES[value] = state
  return setmetatable(value, ARRAY_METATABLE)
end

function M.binary(data, subtype)
  if type(data) ~= "string" then
    error("binary data must be a string", 2)
  end

  if subtype == nil then
    subtype = 0
  end

  if math.type(subtype) ~= "integer" or subtype < 0 or subtype > 255 then
    error("binary subtype must be an integer from 0 through 255", 2)
  end

  local value = {}

  BINARY_STATES[value] = {
    data = data,
    subtype = subtype,
  }

  return setmetatable(value, BINARY_METATABLE)
end

function M.document(entries)
  local length = require_sequence("document", entries)
  local state = {}
  local value = {}

  for index = 1, length do
    local entry = entries[index]

    if type(entry) ~= "table" or #entry ~= 2 then
      error("each document entry must be a key-value pair", 2)
    end

    for key in pairs(entry) do
      if key ~= 1 and key ~= 2 then
        error("each document entry must be a key-value pair", 2)
      end
    end

    if type(entry[1]) ~= "string" then
      error("document keys must be strings", 2)
    end

    if entry[1]:find("\0", 1, true) then
      error("document keys cannot contain NUL bytes", 2)
    end

    if entry[2] == nil then
      error("document values cannot be nil; use bson.null", 2)
    end

    state[index] = { entry[1], entry[2] }
  end

  DOCUMENT_STATES[value] = state
  return setmetatable(value, DOCUMENT_METATABLE)
end

function M.is_array(value)
  return ARRAY_STATES[value] ~= nil
end

function M.is_binary(value)
  return BINARY_STATES[value] ~= nil
end

function M.is_document(value)
  return DOCUMENT_STATES[value] ~= nil
end

function M.is_null(value)
  return value == NULL
end

return M
