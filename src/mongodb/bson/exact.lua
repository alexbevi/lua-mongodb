local M = {}

local EXACT_STATES = setmetatable({}, { __mode = "k" })

local EXPONENT_BIAS = 6176
local EXPONENT_MIN = -6176
local EXPONENT_MAX = 6111
local ADJUSTED_EXPONENT_MAX = 6144
local MAX_DIGITS = 34

local function immutable_value()
  error("BSON values are immutable", 2)
end

local function state_index(methods)
  return function(exact_value, key)
    if methods[key] then
      return methods[key]
    end

    local state = EXACT_STATES[exact_value]
    return state and state[key] or nil
  end
end

local function new_exact(state, metatable)
  local exact_value = {}

  EXACT_STATES[exact_value] = state
  return setmetatable(exact_value, metatable)
end

local function binary_to_hex(bytes)
  return (bytes:gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end))
end

local function require_integer(name, number, minimum, maximum, level)
  if math.type(number) ~= "integer" or number < minimum or number > maximum then
    error(name .. " is outside its signed BSON range", level or 3)
  end
end

local NUMBER_METHODS = {}

function NUMBER_METHODS:to_number()
  return EXACT_STATES[self].value
end

local function number_metatable(kind)
  local metatable = {
    __index = state_index(NUMBER_METHODS),
    __metatable = "mongodb.bson." .. kind,
    __newindex = immutable_value,
  }

  metatable.__eq = function(left, right)
    local left_state = EXACT_STATES[left]
    local right_state = EXACT_STATES[right]
    return left_state ~= nil and right_state ~= nil
      and left_state.kind == right_state.kind
      and left_state.bytes == right_state.bytes
  end

  metatable.__tostring = function(number)
    return tostring(EXACT_STATES[number].value)
  end

  return metatable
end

local INT32_METATABLE = number_metatable("int32")
local INT64_METATABLE = number_metatable("int64")
local DOUBLE_METATABLE = number_metatable("double")

function M.int32(number)
  require_integer("BSON int32 value", number, -0x80000000, 0x7fffffff, 2)

  return new_exact({
    bytes = string.pack("<i4", number),
    kind = "int32",
    value = number,
  }, INT32_METATABLE)
end

function M.int64(number)
  if math.type(number) ~= "integer" then
    error("BSON int64 value must be a Lua integer", 2)
  end

  return new_exact({
    bytes = string.pack("<i8", number),
    kind = "int64",
    value = number,
  }, INT64_METATABLE)
end

function M.double(number)
  if type(number) ~= "number" then
    error("BSON double value must be a number", 2)
  end

  local bytes = string.pack("<d", number)

  return new_exact({
    bytes = bytes,
    kind = "double",
    value = string.unpack("<d", bytes),
  }, DOUBLE_METATABLE)
end

function M.double_from_bytes(bytes)
  if type(bytes) ~= "string" or #bytes ~= 8 then
    error("BSON double bytes must be an 8-byte string", 2)
  end

  return new_exact({
    bytes = bytes,
    kind = "double",
    value = string.unpack("<d", bytes),
  }, DOUBLE_METATABLE)
end

local function parse_exponent(exponent_text)
  if exponent_text == nil then
    return 0
  end

  local sign = 1
  local first = exponent_text:sub(1, 1)

  if first == "+" or first == "-" then
    if first == "-" then
      sign = -1
    end

    exponent_text = exponent_text:sub(2)
  end

  if exponent_text == "" or not exponent_text:match("^%d+$") then
    return nil
  end

  local exponent = 0

  for index = 1, #exponent_text do
    exponent = math.min(exponent * 10 + tonumber(exponent_text:sub(index, index)), 100000)
  end

  return exponent * sign
end

local function parse_finite(input)
  local negative = false
  local first = input:sub(1, 1)

  if first == "+" or first == "-" then
    negative = first == "-"
    input = input:sub(2)
  end

  local mantissa = input
  local exponent_text
  local exponent_start = input:find("[eE]")

  if exponent_start then
    mantissa = input:sub(1, exponent_start - 1)
    exponent_text = input:sub(exponent_start + 1)

    if exponent_text:find("[eE]") then
      return nil
    end
  end

  local integer_digits
  local fraction_digits

  if mantissa:find("%.") then
    integer_digits, fraction_digits = mantissa:match("^(%d*)%.(%d*)$")

    if not integer_digits or integer_digits == "" and fraction_digits == "" then
      return nil
    end
  else
    integer_digits = mantissa:match("^(%d+)$")
    fraction_digits = ""

    if not integer_digits then
      return nil
    end
  end

  local explicit_exponent = parse_exponent(exponent_text)

  if explicit_exponent == nil then
    return nil
  end

  local coefficient = (integer_digits .. fraction_digits):gsub("^0+", "")
  local exponent = explicit_exponent - #fraction_digits

  if coefficient == "" then
    return {
      coefficient = "0",
      exponent = math.max(EXPONENT_MIN, math.min(EXPONENT_MAX, exponent)),
      negative = negative,
    }
  end

  while #coefficient > MAX_DIGITS do
    if coefficient:sub(-1) ~= "0" then
      return nil, "Decimal128 value cannot be represented exactly"
    end

    coefficient = coefficient:sub(1, -2)
    exponent = exponent + 1
  end

  while exponent > EXPONENT_MAX and #coefficient < MAX_DIGITS do
    coefficient = coefficient .. "0"
    exponent = exponent - 1
  end

  while exponent < EXPONENT_MIN and coefficient:sub(-1) == "0" do
    coefficient = coefficient:sub(1, -2)
    exponent = exponent + 1
  end

  if exponent < EXPONENT_MIN then
    return nil, "Decimal128 value is inexact below the minimum exponent"
  end

  if exponent > EXPONENT_MAX or exponent + #coefficient - 1 > ADJUSTED_EXPONENT_MAX then
    return nil, "Decimal128 value overflows the maximum exponent"
  end

  return {
    coefficient = coefficient,
    exponent = exponent,
    negative = negative,
  }
end

local function coefficient_to_bytes(coefficient)
  local bytes = {}

  for index = 1, 15 do
    bytes[index] = 0
  end

  for digit_index = 1, #coefficient do
    local carry = tonumber(coefficient:sub(digit_index, digit_index))

    for byte_index = 1, 15 do
      local product = bytes[byte_index] * 10 + carry
      bytes[byte_index] = product & 0xff
      carry = product >> 8
    end

    if carry ~= 0 then
      error("Decimal128 coefficient overflow", 2)
    end
  end

  return bytes
end

local function encode_finite(parsed)
  local bytes = coefficient_to_bytes(parsed.coefficient)
  local biased_exponent = parsed.exponent + EXPONENT_BIAS

  bytes[15] = (bytes[15] & 0x01) | ((biased_exponent & 0x7f) << 1)
  bytes[16] = ((biased_exponent >> 7) & 0x7f) | (parsed.negative and 0x80 or 0)
  return string.char(table.unpack(bytes, 1, 16))
end

local function decimal_multiply_add(digits, multiplier, addend)
  local carry = addend

  for index = #digits, 1, -1 do
    local product = digits[index] * multiplier + carry
    digits[index] = product % 10
    carry = product // 10
  end

  while carry > 0 do
    table.insert(digits, 1, carry % 10)
    carry = carry // 10
  end
end

local function bytes_to_coefficient(bytes, steering)
  if steering then
    return "0"
  end

  local digits = { 0 }

  for index = 15, 1, -1 do
    local byte = bytes:byte(index)

    if index == 15 then
      byte = byte & 0x01
    end

    decimal_multiply_add(digits, 256, byte)
  end

  local result = table.concat(digits)

  if #result > MAX_DIGITS then
    return "0"
  end

  return result
end

local function format_finite(negative, coefficient, exponent)
  local sign = negative and "-" or ""
  local adjusted_exponent = exponent + #coefficient - 1

  if exponent > 0 or adjusted_exponent < -6 then
    local significand = coefficient:sub(1, 1)

    if #coefficient > 1 then
      significand = significand .. "." .. coefficient:sub(2)
    end

    local exponent_sign = adjusted_exponent >= 0 and "+" or ""
    return sign .. significand .. "E" .. exponent_sign .. adjusted_exponent
  end

  local point = #coefficient + exponent

  if point <= 0 then
    return sign .. "0." .. string.rep("0", -point) .. coefficient
  end

  if point < #coefficient then
    return sign .. coefficient:sub(1, point) .. "." .. coefficient:sub(point + 1)
  end

  return sign .. coefficient .. string.rep("0", point - #coefficient)
end

local function decode_bid(bytes)
  local final_byte = bytes:byte(16)
  local negative = (final_byte & 0x80) ~= 0
  local sign = negative and "-" or ""

  if (final_byte & 0x7e) == 0x7e then
    return "NaN"
  end

  if (final_byte & 0x7c) == 0x7c then
    return "NaN"
  end

  if (final_byte & 0x78) == 0x78 then
    return sign .. "Infinity"
  end

  local steering = (final_byte & 0x60) == 0x60
  local biased_exponent

  if steering then
    biased_exponent = ((bytes:byte(14) >> 7) & 0x01)
      | (bytes:byte(15) << 1)
      | ((final_byte & 0x1f) << 9)
  else
    biased_exponent = (bytes:byte(15) >> 1) | ((final_byte & 0x7f) << 7)
  end

  local coefficient = bytes_to_coefficient(bytes, steering)
  return format_finite(negative, coefficient, biased_exponent - EXPONENT_BIAS)
end

local DECIMAL_METHODS = {}
local DECIMAL_METATABLE = {
  __index = state_index(DECIMAL_METHODS),
  __metatable = "mongodb.bson.decimal128",
  __newindex = immutable_value,
}

DECIMAL_METATABLE.__eq = function(left, right)
  local left_state = EXACT_STATES[left]
  local right_state = EXACT_STATES[right]
  return left_state ~= nil and right_state ~= nil
    and left_state.kind == "decimal128"
    and right_state.kind == "decimal128"
    and left_state.bid == right_state.bid
end

DECIMAL_METATABLE.__tostring = function(decimal)
  return EXACT_STATES[decimal].string
end

function DECIMAL_METHODS:bid_hex()
  return binary_to_hex(EXACT_STATES[self].bid)
end

function M.decimal128_from_bid(bytes)
  if type(bytes) ~= "string" or #bytes ~= 16 then
    error("Decimal128 BID input must be exactly 16 bytes", 2)
  end

  return new_exact({
    bid = bytes,
    kind = "decimal128",
    string = decode_bid(bytes),
  }, DECIMAL_METATABLE)
end

function M.decimal128(input)
  if type(input) ~= "string" or input == "" then
    error("Decimal128 input must be a non-empty string", 2)
  end

  local lowered = input:lower()
  local negative = lowered:sub(1, 1) == "-"
  local unsigned = lowered

  if lowered:sub(1, 1) == "+" or negative then
    unsigned = lowered:sub(2)
  end

  local special

  if unsigned == "inf" or unsigned == "infinity" then
    special = 0x78
  elseif unsigned == "nan" then
    special = 0x7c
  elseif unsigned == "snan" then
    special = 0x7e
  end

  if special then
    local final_byte = special | (negative and 0x80 or 0)
    return M.decimal128_from_bid(string.rep("\0", 15) .. string.char(final_byte))
  end

  local parsed, reason = parse_finite(input)

  if not parsed then
    error(reason or "invalid Decimal128 string", 2)
  end

  return M.decimal128_from_bid(encode_finite(parsed))
end

function M.is(exact_value, kind)
  local state = EXACT_STATES[exact_value]
  return state ~= nil and (kind == nil or state.kind == kind)
end

function M.kind(exact_value)
  local state = EXACT_STATES[exact_value]
  return state and state.kind or nil
end

return M
