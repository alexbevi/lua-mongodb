local M = {}

local DTYPE_VALUES = {
  FLOAT32 = 0x27,
  INT8 = 0x03,
  PACKED_BIT = 0x10,
}
local DTYPE_NAMES = {
  [DTYPE_VALUES.FLOAT32] = "FLOAT32",
  [DTYPE_VALUES.INT8] = "INT8",
  [DTYPE_VALUES.PACKED_BIT] = "PACKED_BIT",
}
local VECTOR_STATES = setmetatable({}, { __mode = "k" })

local function immutable_value()
  error("BSON vector values are immutable", 2)
end

local VECTOR_METATABLE = {
  __index = function(value, key)
    local state = VECTOR_STATES[value]
    return state and state[key] or nil
  end,
  __metatable = "mongodb.bson.vector",
  __newindex = immutable_value,
}

M.DTYPE = setmetatable({}, {
  __index = DTYPE_VALUES,
  __metatable = "mongodb.bson.vector_dtypes",
  __newindex = immutable_value,
  __pairs = function()
    return next, DTYPE_VALUES, nil
  end,
})

local function validate_dtype(dtype)
  if DTYPE_NAMES[dtype] == nil then
    error("vector dtype must be VECTOR_DTYPE.INT8, FLOAT32, or PACKED_BIT", 3)
  end
end

local function validate_padding(dtype, padding, length)
  if math.type(padding) ~= "integer" then
    error("vector padding must be an integer", 3)
  end

  if dtype == DTYPE_VALUES.PACKED_BIT then
    if padding < 0 or padding > 7 then
      error("PACKED_BIT vector padding must be from 0 through 7", 3)
    end

    if padding > 0 and length == 0 then
      error("an empty PACKED_BIT vector cannot have padding", 3)
    end
  elseif padding ~= 0 then
    error(DTYPE_NAMES[dtype] .. " vector padding must be zero", 3)
  end
end

local function validate_values(values)
  if type(values) ~= "table" then
    error("vector values must be a dense array", 3)
  end

  local length = #values

  for key in pairs(values) do
    if math.type(key) ~= "integer" or key < 1 or key > length then
      error("vector values must be a dense array", 3)
    end
  end

  return length
end


function M.encode(values, dtype, padding)
  validate_dtype(dtype)
  local length = validate_values(values)

  padding = padding == nil and 0 or padding
  validate_padding(dtype, padding, length)
  local parts = { string.char(dtype, padding) }

  for index = 1, length do
    local item = values[index]

    if dtype == DTYPE_VALUES.INT8 then
      if math.type(item) ~= "integer" or item < -128 or item > 127 then
        error("INT8 vector values must be integers from -128 through 127", 2)
      end

      parts[#parts + 1] = string.pack("<b", item)
    elseif dtype == DTYPE_VALUES.PACKED_BIT then
      if math.type(item) ~= "integer" or item < 0 or item > 255 then
        error("PACKED_BIT vector values must be integers from 0 through 255", 2)
      end

      parts[#parts + 1] = string.char(item)
    else
      if type(item) ~= "number" then
        error("FLOAT32 vector values must be numbers", 2)
      end

      parts[#parts + 1] = string.pack("<f", item)
    end
  end

  if padding > 0 and values[length] & ((1 << padding) - 1) ~= 0 then
    error("PACKED_BIT vector ignored bits must be zero", 2)
  end

  return table.concat(parts)
end

function M.decode(data, subtype, array_factory)
  if subtype ~= 9 then
    error("only BSON binary subtype 9 can be decoded as a vector", 2)
  end

  if #data < 2 then
    error("BSON vector data must contain dtype and padding bytes", 2)
  end

  local dtype = data:byte(1)
  local padding = data:byte(2)

  validate_dtype(dtype)
  local byte_length = #data - 2

  validate_padding(dtype, padding, byte_length)

  if dtype == DTYPE_VALUES.FLOAT32 and byte_length % 4 ~= 0 then
    error("FLOAT32 vector data length must be a multiple of four bytes", 2)
  end

  if dtype == DTYPE_VALUES.PACKED_BIT
    and padding > 0
    and data:byte(-1) & ((1 << padding) - 1) ~= 0
  then
    error("PACKED_BIT vector ignored bits must be zero", 2)
  end

  local values = {}

  if dtype == DTYPE_VALUES.FLOAT32 then
    for position = 3, #data, 4 do
      values[#values + 1] = string.unpack("<f", data, position)
    end
  elseif dtype == DTYPE_VALUES.INT8 then
    for position = 3, #data do
      values[#values + 1] = string.unpack("<b", data, position)
    end
  else
    for position = 3, #data do
      values[#values + 1] = data:byte(position)
    end
  end

  local result = {}

  VECTOR_STATES[result] = {
    data = array_factory(values),
    dtype = dtype,
    padding = padding,
  }
  return setmetatable(result, VECTOR_METATABLE)
end

return M
