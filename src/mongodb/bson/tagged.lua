local runtime_contract = require("mongodb.runtime")
local value = require("mongodb.bson.value")

local M = {}

local TAGGED_STATES = setmetatable({}, { __mode = "k" })
local GENERATOR_STATES = setmetatable({}, { __mode = "k" })

local UINT32_MAX = 0xffffffff
local COUNTER_MODULUS = 0x1000000
local REGEX_FLAG_ORDER = "ilmsux"

local function immutable_value()
  error("BSON values are immutable", 2)
end

local function state_for(tagged_value, expected_kind, level)
  local state = TAGGED_STATES[tagged_value]

  if not state or state.kind ~= expected_kind then
    error("expected BSON " .. expected_kind .. " value", level or 3)
  end

  return state
end

local function expose_methods(methods)
  return function(tagged_value, key)
    if methods[key] then
      return methods[key]
    end

    local state = TAGGED_STATES[tagged_value]
    return state and state[key] or nil
  end
end

local function new_tagged(state, metatable)
  local tagged_value = {}

  TAGGED_STATES[tagged_value] = state
  return setmetatable(tagged_value, metatable)
end

local function require_integer(name, number, minimum, maximum, level)
  if math.type(number) ~= "integer" or number < minimum or number > maximum then
    error(name .. " must be an integer from " .. minimum .. " through " .. maximum, level or 3)
  end
end

local function binary_to_hex(bytes)
  return (bytes:gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end))
end

local function hex_to_binary(hex)
  if not hex:match("^[0-9a-fA-F]+$") then
    return nil
  end

  return (hex:gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local OBJECT_ID_METHODS = {}
local OBJECT_ID_METATABLE = {
  __index = expose_methods(OBJECT_ID_METHODS),
  __metatable = "mongodb.bson.object_id",
  __newindex = immutable_value,
}

OBJECT_ID_METATABLE.__eq = function(left, right)
  local left_state = TAGGED_STATES[left]
  local right_state = TAGGED_STATES[right]
  return left_state ~= nil and right_state ~= nil and left_state.binary == right_state.binary
end

OBJECT_ID_METATABLE.__lt = function(left, right)
  return state_for(left, "object_id", 2).binary < state_for(right, "object_id", 2).binary
end

OBJECT_ID_METATABLE.__le = function(left, right)
  return state_for(left, "object_id", 2).binary <= state_for(right, "object_id", 2).binary
end

OBJECT_ID_METATABLE.__tostring = function(object_id)
  return TAGGED_STATES[object_id].hex
end

function M.object_id(input)
  if type(input) ~= "string" then
    error("ObjectId input must be a 12-byte or 24-character string", 2)
  end

  local binary

  if #input == 12 then
    binary = input
  elseif #input == 24 then
    binary = hex_to_binary(input)

    if not binary then
      error("ObjectId hex input must contain exactly 24 hexadecimal characters", 2)
    end
  else
    error("ObjectId input must be a 12-byte or 24-character string", 2)
  end

  local timestamp = string.unpack(">I4", binary)

  return new_tagged({
    binary = binary,
    hex = binary_to_hex(binary),
    kind = "object_id",
    timestamp = timestamp,
  }, OBJECT_ID_METATABLE)
end

local GENERATOR_METHODS = {}
local GENERATOR_METATABLE = {
  __index = GENERATOR_METHODS,
  __metatable = "mongodb.bson.object_id_generator",
}

local function process_identity(runtime, level)
  local identity = runtime.process:identity()

  if math.type(identity) ~= "integer" or identity <= 0 then
    error("runtime process identity must be a positive integer", level or 3)
  end

  return identity
end

local function entropy_bytes(runtime, count, level)
  local entropy, err = runtime.entropy:bytes(count)

  if not entropy then
    return nil, err
  end

  if type(entropy) ~= "string" or #entropy ~= count then
    error("runtime entropy must return exactly the requested byte count", level or 3)
  end

  return entropy
end

function GENERATOR_METHODS:new()
  local state = GENERATOR_STATES[self]
  local identity = process_identity(state.runtime, 2)

  if identity ~= state.process_identity then
    local random, err = entropy_bytes(state.runtime, 5, 2)

    if not random then
      return nil, err
    end

    state.process_identity = identity
    state.random = random
  end

  local seconds = math.floor(state.runtime.clock:wall_time())

  require_integer("ObjectId Unix time", seconds, 0, UINT32_MAX, 2)

  local counter = state.counter
  state.counter = (counter + 1) % COUNTER_MODULUS

  local counter_bytes = string.pack(">I4", counter):sub(2)
  local binary = string.pack(">I4", seconds) .. state.random .. counter_bytes
  return M.object_id(binary)
end

function M.object_id_generator(runtime)
  runtime_contract.validate(runtime)

  local identity = process_identity(runtime, 2)
  local entropy, err = entropy_bytes(runtime, 8, 2)

  if not entropy then
    return nil, err
  end

  local generator = {}

  GENERATOR_STATES[generator] = {
    counter = string.unpack(">I4", "\0" .. entropy:sub(6, 8)),
    process_identity = identity,
    random = entropy:sub(1, 5),
    runtime = runtime,
  }

  return setmetatable(generator, GENERATOR_METATABLE)
end

local DATETIME_METHODS = {}
local DATETIME_METATABLE = {
  __index = expose_methods(DATETIME_METHODS),
  __metatable = "mongodb.bson.datetime",
  __newindex = immutable_value,
}

DATETIME_METATABLE.__eq = function(left, right)
  local left_state = TAGGED_STATES[left]
  local right_state = TAGGED_STATES[right]
  return left_state ~= nil and right_state ~= nil
    and left_state.milliseconds == right_state.milliseconds
end

DATETIME_METATABLE.__lt = function(left, right)
  return state_for(left, "datetime", 2).milliseconds
    < state_for(right, "datetime", 2).milliseconds
end

DATETIME_METATABLE.__le = function(left, right)
  return state_for(left, "datetime", 2).milliseconds
    <= state_for(right, "datetime", 2).milliseconds
end

function M.datetime(milliseconds)
  if math.type(milliseconds) ~= "integer" then
    error("BSON datetime milliseconds must be a signed 64-bit integer", 2)
  end

  return new_tagged({
    kind = "datetime",
    milliseconds = milliseconds,
  }, DATETIME_METATABLE)
end

local REGEX_METHODS = {}
local REGEX_METATABLE = {
  __index = expose_methods(REGEX_METHODS),
  __metatable = "mongodb.bson.regex",
  __newindex = immutable_value,
}

REGEX_METATABLE.__eq = function(left, right)
  local left_state = TAGGED_STATES[left]
  local right_state = TAGGED_STATES[right]
  return left_state ~= nil and right_state ~= nil
    and left_state.pattern == right_state.pattern
    and left_state.options == right_state.options
end

local function normalize_regex_options(options)
  if type(options) ~= "string" then
    error("BSON regex options must be a string", 3)
  end

  local present = {}

  for index = 1, #options do
    local option = options:sub(index, index)

    if not REGEX_FLAG_ORDER:find(option, 1, true) then
      error("unsupported BSON regex option: " .. option, 3)
    end

    present[option] = true
  end

  local normalized = {}

  for index = 1, #REGEX_FLAG_ORDER do
    local option = REGEX_FLAG_ORDER:sub(index, index)

    if present[option] then
      normalized[#normalized + 1] = option
    end
  end

  return table.concat(normalized)
end

function M.regex(pattern, options)
  if type(pattern) ~= "string" then
    error("BSON regex pattern must be a string", 2)
  end

  if pattern:find("\0", 1, true) then
    error("BSON regex pattern cannot contain NUL bytes", 2)
  end

  options = normalize_regex_options(options or "")

  return new_tagged({
    kind = "regex",
    options = options,
    pattern = pattern,
  }, REGEX_METATABLE)
end

local TIMESTAMP_METHODS = {}
local TIMESTAMP_METATABLE = {
  __index = expose_methods(TIMESTAMP_METHODS),
  __metatable = "mongodb.bson.timestamp",
  __newindex = immutable_value,
}

TIMESTAMP_METATABLE.__eq = function(left, right)
  local left_state = TAGGED_STATES[left]
  local right_state = TAGGED_STATES[right]
  return left_state ~= nil and right_state ~= nil
    and left_state.time == right_state.time
    and left_state.increment == right_state.increment
end

TIMESTAMP_METATABLE.__lt = function(left, right)
  local left_state = state_for(left, "timestamp", 2)
  local right_state = state_for(right, "timestamp", 2)
  return left_state.time < right_state.time
    or left_state.time == right_state.time and left_state.increment < right_state.increment
end

TIMESTAMP_METATABLE.__le = function(left, right)
  return left == right or left < right
end

function M.timestamp(time, increment)
  require_integer("BSON timestamp time", time, 0, UINT32_MAX, 2)
  require_integer("BSON timestamp increment", increment, 0, UINT32_MAX, 2)

  return new_tagged({
    increment = increment,
    kind = "timestamp",
    time = time,
  }, TIMESTAMP_METATABLE)
end

local CODE_METHODS = {}
local CODE_METATABLE = {
  __index = expose_methods(CODE_METHODS),
  __metatable = "mongodb.bson.code",
  __newindex = immutable_value,
}

function M.code(source, scope)
  if type(source) ~= "string" then
    error("BSON code source must be a string", 2)
  end

  if scope ~= nil and not value.is_document(scope) then
    error("BSON code scope must be an ordered document", 2)
  end

  return new_tagged({
    kind = "code",
    scope = scope,
    source = source,
  }, CODE_METATABLE)
end

local SYMBOL_METHODS = {}
local SYMBOL_METATABLE = {
  __index = expose_methods(SYMBOL_METHODS),
  __metatable = "mongodb.bson.symbol",
  __newindex = immutable_value,
}

SYMBOL_METATABLE.__eq = function(left, right)
  local left_state = TAGGED_STATES[left]
  local right_state = TAGGED_STATES[right]
  return left_state ~= nil and right_state ~= nil
    and left_state.kind == "symbol"
    and right_state.kind == "symbol"
    and left_state.value == right_state.value
end

function M.symbol(symbol_value)
  if type(symbol_value) ~= "string" then
    error("BSON symbol value must be a string", 2)
  end

  return new_tagged({
    kind = "symbol",
    value = symbol_value,
  }, SYMBOL_METATABLE)
end

local DB_POINTER_METHODS = {}
local DB_POINTER_METATABLE = {
  __index = expose_methods(DB_POINTER_METHODS),
  __metatable = "mongodb.bson.db_pointer",
  __newindex = immutable_value,
}

DB_POINTER_METATABLE.__eq = function(left, right)
  local left_state = TAGGED_STATES[left]
  local right_state = TAGGED_STATES[right]
  return left_state ~= nil and right_state ~= nil
    and left_state.kind == "db_pointer"
    and right_state.kind == "db_pointer"
    and left_state.namespace == right_state.namespace
    and left_state.object_id == right_state.object_id
end

function M.db_pointer(namespace, object_id)
  if type(namespace) ~= "string" then
    error("BSON DBPointer namespace must be a string", 2)
  end

  if not M.is(object_id, "object_id") then
    error("BSON DBPointer object_id must be an ObjectId", 2)
  end

  return new_tagged({
    kind = "db_pointer",
    namespace = namespace,
    object_id = object_id,
  }, DB_POINTER_METATABLE)
end

local UNDEFINED = new_tagged({ kind = "undefined" }, {
  __metatable = "mongodb.bson.undefined",
  __newindex = immutable_value,
  __tostring = function()
    return "undefined"
  end,
})

local MIN_KEY = new_tagged({ kind = "min_key" }, {
  __metatable = "mongodb.bson.min_key",
  __newindex = immutable_value,
  __tostring = function()
    return "MinKey"
  end,
})

local MAX_KEY = new_tagged({ kind = "max_key" }, {
  __metatable = "mongodb.bson.max_key",
  __newindex = immutable_value,
  __tostring = function()
    return "MaxKey"
  end,
})

M.min_key = MIN_KEY
M.max_key = MAX_KEY
M.undefined = UNDEFINED

function M.is(value_to_check, kind)
  local state = TAGGED_STATES[value_to_check]
  return state ~= nil and (kind == nil or state.kind == kind)
end

function M.kind(value_to_check)
  local state = TAGGED_STATES[value_to_check]
  return state and state.kind or nil
end

return M
