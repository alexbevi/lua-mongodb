local errors = require("mongodb.error")
local value = require("mongodb.bson.value")

local M = {}

local TYPE_DOUBLE = 0x01
local TYPE_STRING = 0x02
local TYPE_DOCUMENT = 0x03
local TYPE_ARRAY = 0x04
local TYPE_BINARY = 0x05
local TYPE_BOOLEAN = 0x08
local TYPE_NULL = 0x0a
local TYPE_INT32 = 0x10
local TYPE_INT64 = 0x12

local INT32_MIN = -0x80000000
local INT32_MAX = 0x7fffffff
local MAX_BSON_SIZE = 0x7fffffff

local function bson_error(message, offset, details)
  details = details or {}
  details.offset = offset

  return errors.new({
    category = errors.CATEGORY.BSON,
    message = message,
    details = details,
  })
end

local function encode_error(message, details)
  return nil, errors.new({
    category = errors.CATEGORY.BSON,
    message = message,
    details = details,
  })
end

local function encode_container(container, array)
  local elements = {}
  local count = #container

  for index = 1, count do
    local key
    local item

    if array then
      key = tostring(index - 1)
      item = container:get(index)
    else
      key, item = container:get_at(index)
    end

    local encoded, err = M._encode_element(key, item)

    if not encoded then
      return nil, err
    end

    elements[#elements + 1] = encoded
  end

  local body = table.concat(elements) .. "\0"
  local length = 4 + #body

  if length > MAX_BSON_SIZE then
    return encode_error("BSON document exceeds the signed 32-bit length limit", {
      length = length,
    })
  end

  return string.pack("<i4", length) .. body
end

function M._encode_element(key, item)
  local element_type
  local payload
  local item_type = type(item)

  if value.is_null(item) then
    element_type = TYPE_NULL
    payload = ""
  elseif value.is_document(item) then
    element_type = TYPE_DOCUMENT
    local err
    payload, err = encode_container(item, false)

    if not payload then
      return nil, err
    end
  elseif value.is_array(item) then
    element_type = TYPE_ARRAY
    local err
    payload, err = encode_container(item, true)

    if not payload then
      return nil, err
    end
  elseif value.is_binary(item) then
    if #item.data > MAX_BSON_SIZE then
      return encode_error("BSON binary value exceeds the signed 32-bit length limit", {
        key = key,
        length = #item.data,
      })
    end

    element_type = TYPE_BINARY
    payload = string.pack("<i4B", #item.data, item.subtype) .. item.data
  elseif item_type == "boolean" then
    element_type = TYPE_BOOLEAN
    payload = item and "\1" or "\0"
  elseif item_type == "string" then
    if #item >= MAX_BSON_SIZE then
      return encode_error("BSON string exceeds the signed 32-bit length limit", {
        key = key,
        length = #item,
      })
    end

    element_type = TYPE_STRING
    payload = string.pack("<i4", #item + 1) .. item .. "\0"
  elseif item_type == "number" and math.type(item) == "integer" then
    if item >= INT32_MIN and item <= INT32_MAX then
      element_type = TYPE_INT32
      payload = string.pack("<i4", item)
    else
      element_type = TYPE_INT64
      payload = string.pack("<i8", item)
    end
  elseif item_type == "number" then
    element_type = TYPE_DOUBLE
    payload = string.pack("<d", item)
  else
    return encode_error("unsupported Lua value for BSON encoding", {
      key = key,
      lua_type = item_type,
    })
  end

  if not payload then
    return nil, element_type
  end

  return string.char(element_type) .. key .. "\0" .. payload
end

local function require_bytes(position, count, limit, description)
  if count < 0 or position < 1 or position + count - 1 > limit then
    return nil, bson_error("truncated " .. description, position, {
      needed = count,
      available = math.max(0, limit - position + 1),
    })
  end

  return true
end

local function read_integer(data, position, size, limit, description)
  local ok, err = require_bytes(position, size, limit, description)

  if not ok then
    return nil, nil, err
  end

  local format = size == 4 and "<i4" or "<i8"
  local number, next_position = string.unpack(format, data, position)
  return number, next_position
end

local function decode_container(data, position, limit, array)
  local length, body_position, err = read_integer(
    data,
    position,
    4,
    limit,
    "BSON document length"
  )

  if not length then
    return nil, nil, err
  end

  if length < 5 then
    return nil, nil, bson_error("BSON document length must be at least 5", position, {
      length = length,
    })
  end

  local document_end = position + length - 1

  if document_end > limit then
    return nil, nil, bson_error("BSON document length exceeds available bytes", position, {
      length = length,
      available = limit - position + 1,
    })
  end

  if data:byte(document_end) ~= 0 then
    return nil, nil, bson_error("BSON document is missing its terminating NUL", document_end)
  end

  local entries = {}
  local cursor = body_position
  local expected_array_index = 0

  while cursor < document_end do
    local element_type = data:byte(cursor)
    cursor = cursor + 1

    local key_end = data:find("\0", cursor, true)

    if not key_end or key_end >= document_end then
      return nil, nil, bson_error("BSON element name is not NUL-terminated", cursor)
    end

    local key = data:sub(cursor, key_end - 1)
    cursor = key_end + 1

    if array and key ~= tostring(expected_array_index) then
      return nil, nil, bson_error("BSON array keys must be consecutive decimal indexes", key_end, {
        actual = key,
        expected = tostring(expected_array_index),
      })
    end

    local item
    item, cursor, err = M._decode_value(data, cursor, document_end - 1, element_type)

    if err then
      return nil, nil, err
    end

    if array then
      entries[#entries + 1] = item
      expected_array_index = expected_array_index + 1
    else
      entries[#entries + 1] = { key, item }
    end
  end

  if cursor ~= document_end then
    return nil, nil, bson_error("BSON element extends beyond its document", cursor)
  end

  local decoded = array and value.array(entries) or value.document(entries)
  return decoded, document_end + 1
end

function M._decode_value(data, position, limit, element_type)
  if element_type == TYPE_NULL then
    return value.null, position
  end

  if element_type == TYPE_BOOLEAN then
    local ok, err = require_bytes(position, 1, limit, "BSON boolean")

    if not ok then
      return nil, nil, err
    end

    local byte = data:byte(position)

    if byte ~= 0 and byte ~= 1 then
      return nil, nil, bson_error("BSON boolean must be encoded as 0 or 1", position, {
        value = byte,
      })
    end

    return byte == 1, position + 1
  end

  if element_type == TYPE_INT32 or element_type == TYPE_INT64 then
    local size = element_type == TYPE_INT32 and 4 or 8
    return read_integer(data, position, size, limit, "BSON integer")
  end

  if element_type == TYPE_DOUBLE then
    local ok, err = require_bytes(position, 8, limit, "BSON double")

    if not ok then
      return nil, nil, err
    end

    local number, next_position = string.unpack("<d", data, position)
    return number, next_position
  end

  if element_type == TYPE_STRING then
    local length, string_position, err = read_integer(
      data,
      position,
      4,
      limit,
      "BSON string length"
    )

    if not length then
      return nil, nil, err
    end

    if length < 1 then
      return nil, nil, bson_error("BSON string length must include a terminating NUL", position, {
        length = length,
      })
    end

    local ok
    ok, err = require_bytes(string_position, length, limit, "BSON string")

    if not ok then
      return nil, nil, err
    end

    local string_end = string_position + length - 1

    if data:byte(string_end) ~= 0 then
      return nil, nil, bson_error("BSON string is missing its terminating NUL", string_end)
    end

    return data:sub(string_position, string_end - 1), string_end + 1
  end

  if element_type == TYPE_BINARY then
    local length, binary_position, err = read_integer(
      data,
      position,
      4,
      limit,
      "BSON binary length"
    )

    if not length then
      return nil, nil, err
    end

    if length < 0 then
      return nil, nil, bson_error("BSON binary length cannot be negative", position, {
        length = length,
      })
    end

    local ok
    ok, err = require_bytes(binary_position, length + 1, limit, "BSON binary value")

    if not ok then
      return nil, nil, err
    end

    local subtype = data:byte(binary_position)
    local data_position = binary_position + 1
    local next_position = data_position + length

    if subtype ~= 0 then
      return nil, nil, bson_error("unsupported BSON binary subtype", binary_position, {
        subtype = subtype,
      })
    end

    return value.binary(data:sub(data_position, next_position - 1), subtype), next_position
  end

  if element_type == TYPE_DOCUMENT or element_type == TYPE_ARRAY then
    return decode_container(data, position, limit, element_type == TYPE_ARRAY)
  end

  return nil, nil, bson_error("unsupported BSON element type", position - 1, {
    element_type = element_type,
  })
end

function M.encode(document)
  if not value.is_document(document) then
    return encode_error("BSON root value must be an ordered document", {
      lua_type = type(document),
    })
  end

  return encode_container(document, false)
end

function M.decode(data)
  if type(data) ~= "string" then
    error("BSON input must be a string", 2)
  end

  local document, next_position, err = decode_container(data, 1, #data, false)

  if not document then
    return nil, err
  end

  if next_position ~= #data + 1 then
    return nil, bson_error("trailing bytes follow the BSON document", next_position, {
      trailing = #data - next_position + 1,
    })
  end

  return document
end

return M
