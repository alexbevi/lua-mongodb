local errors = require("mongodb.error")
local exact = require("mongodb.bson.exact")
local tagged = require("mongodb.bson.tagged")
local value = require("mongodb.bson.value")

local M = {}

local TYPE_DOUBLE = 0x01
local TYPE_STRING = 0x02
local TYPE_DOCUMENT = 0x03
local TYPE_ARRAY = 0x04
local TYPE_BINARY = 0x05
local TYPE_UNDEFINED = 0x06
local TYPE_OBJECT_ID = 0x07
local TYPE_BOOLEAN = 0x08
local TYPE_DATETIME = 0x09
local TYPE_NULL = 0x0a
local TYPE_REGEX = 0x0b
local TYPE_DB_POINTER = 0x0c
local TYPE_CODE = 0x0d
local TYPE_SYMBOL = 0x0e
local TYPE_CODE_SCOPE = 0x0f
local TYPE_INT32 = 0x10
local TYPE_TIMESTAMP = 0x11
local TYPE_INT64 = 0x12
local TYPE_DECIMAL128 = 0x13
local TYPE_MAX_KEY = 0x7f
local TYPE_MIN_KEY = 0xff

local INT32_MIN = -0x80000000
local INT32_MAX = 0x7fffffff
local MAX_BSON_SIZE = 0x7fffffff

local DEFAULT_OPTIONS = {
  max_binary_size = 16 * 1024 * 1024,
  max_depth = 100,
  max_document_size = 16 * 1024 * 1024,
  max_string_size = 16 * 1024 * 1024,
  validate_utf8 = true,
}

local function codec_options(options)
  options = options or {}

  if type(options) ~= "table" then
    error("BSON codec options must be a table", 3)
  end

  local result = {}

  for name, default in pairs(DEFAULT_OPTIONS) do
    local option = options[name]

    if option == nil then
      option = default
    end

    if name == "validate_utf8" then
      if type(option) ~= "boolean" then
        error(name .. " must be a boolean", 3)
      end
    elseif math.type(option) ~= "integer" or option <= 0 or option > MAX_BSON_SIZE then
      error(name .. " must be a positive signed 32-bit integer", 3)
    end

    result[name] = option
  end

  for name in pairs(options) do
    if DEFAULT_OPTIONS[name] == nil then
      error("unknown BSON codec option: " .. tostring(name), 3)
    end
  end

  return result
end

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

local function invalid_utf8_offset(text)
  local length, offset = utf8.len(text)

  if length == nil then
    return offset
  end
end

local function validate_encode_utf8(text, description, key, options)
  if not options.validate_utf8 then
    return true
  end

  local offset = invalid_utf8_offset(text)

  if offset then
    return encode_error(description .. " contains invalid UTF-8", {
      key = key,
      utf8_offset = offset,
    })
  end

  return true
end

local function encode_string_payload(string_value)
  return string.pack("<i4", #string_value + 1) .. string_value .. "\0"
end

local encode_element

local function encode_container(container, array, context, depth)
  if depth > context.max_depth then
    return encode_error("BSON nesting exceeds the configured maximum depth", {
      depth = depth,
      max_depth = context.max_depth,
    })
  end

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

    local encoded, err = encode_element(key, item, context, depth)

    if not encoded then
      return nil, err
    end

    elements[#elements + 1] = encoded
  end

  local body = table.concat(elements) .. "\0"
  local length = 4 + #body

  if length > context.max_document_size then
    return encode_error("BSON document exceeds the configured size limit", {
      length = length,
      max_document_size = context.max_document_size,
    })
  end

  return string.pack("<i4", length) .. body
end

encode_element = function(key, item, context, depth)
  local element_type
  local payload
  local item_type = type(item)
  local exact_kind = exact.kind(item)
  local tagged_kind = tagged.kind(item)

  local valid, validation_error = validate_encode_utf8(
    key,
    "BSON document key",
    key,
    context
  )

  if not valid then
    return nil, validation_error
  end

  if value.is_null(item) then
    element_type = TYPE_NULL
    payload = ""
  elseif value.is_document(item) then
    element_type = TYPE_DOCUMENT
    local err
    payload, err = encode_container(item, false, context, depth + 1)

    if not payload then
      return nil, err
    end
  elseif value.is_array(item) then
    element_type = TYPE_ARRAY
    local err
    payload, err = encode_container(item, true, context, depth + 1)

    if not payload then
      return nil, err
    end
  elseif value.is_binary(item) then
    local length_overhead = item.subtype == 2 and 4 or 0

    if #item.data > context.max_binary_size
        or #item.data > MAX_BSON_SIZE - length_overhead then
      return encode_error("BSON binary value exceeds the configured size limit", {
        key = key,
        length = #item.data,
        max_binary_size = context.max_binary_size,
      })
    end

    element_type = TYPE_BINARY

    if item.subtype == 2 then
      payload = string.pack("<i4Bi4", #item.data + 4, item.subtype, #item.data) .. item.data
    else
      payload = string.pack("<i4B", #item.data, item.subtype) .. item.data
    end
  elseif tagged_kind == "object_id" then
    element_type = TYPE_OBJECT_ID
    payload = item.binary
  elseif tagged_kind == "datetime" then
    element_type = TYPE_DATETIME
    payload = string.pack("<i8", item.milliseconds)
  elseif tagged_kind == "regex" then
    if #item.pattern > context.max_string_size then
      return encode_error("BSON regex pattern exceeds the configured string size limit", {
        key = key,
        length = #item.pattern,
        max_string_size = context.max_string_size,
      })
    end

    valid, validation_error = validate_encode_utf8(
      item.pattern,
      "BSON regex pattern",
      key,
      context
    )

    if not valid then
      return nil, validation_error
    end

    element_type = TYPE_REGEX
    payload = item.pattern .. "\0" .. item.options .. "\0"
  elseif tagged_kind == "timestamp" then
    element_type = TYPE_TIMESTAMP
    payload = string.pack("<I4I4", item.increment, item.time)
  elseif tagged_kind == "code" then
    if #item.source > context.max_string_size or #item.source >= MAX_BSON_SIZE then
      return encode_error("BSON code exceeds the configured string size limit", {
        key = key,
        length = #item.source,
        max_string_size = context.max_string_size,
      })
    end

    valid, validation_error = validate_encode_utf8(item.source, "BSON code", key, context)

    if not valid then
      return nil, validation_error
    end

    if item.scope == nil then
      element_type = TYPE_CODE
      payload = encode_string_payload(item.source)
    else
      local scope, err = encode_container(item.scope, false, context, depth + 1)

      if not scope then
        return nil, err
      end

      local source = encode_string_payload(item.source)
      local total_length = 4 + #source + #scope

      if total_length > MAX_BSON_SIZE then
        return encode_error("BSON code-with-scope exceeds the signed 32-bit length limit", {
          key = key,
          length = total_length,
        })
      end

      element_type = TYPE_CODE_SCOPE
      payload = string.pack("<i4", total_length) .. source .. scope
    end
  elseif tagged_kind == "min_key" then
    element_type = TYPE_MIN_KEY
    payload = ""
  elseif tagged_kind == "max_key" then
    element_type = TYPE_MAX_KEY
    payload = ""
  elseif tagged_kind == "undefined" then
    element_type = TYPE_UNDEFINED
    payload = ""
  elseif tagged_kind == "symbol" then
    if #item.value > context.max_string_size or #item.value >= MAX_BSON_SIZE then
      return encode_error("BSON symbol exceeds the configured string size limit", {
        key = key,
        length = #item.value,
        max_string_size = context.max_string_size,
      })
    end

    valid, validation_error = validate_encode_utf8(item.value, "BSON symbol", key, context)

    if not valid then
      return nil, validation_error
    end

    element_type = TYPE_SYMBOL
    payload = encode_string_payload(item.value)
  elseif tagged_kind == "db_pointer" then
    if #item.namespace > context.max_string_size or #item.namespace >= MAX_BSON_SIZE then
      return encode_error("BSON DBPointer namespace exceeds the configured string size limit", {
        key = key,
        length = #item.namespace,
        max_string_size = context.max_string_size,
      })
    end

    valid, validation_error = validate_encode_utf8(
      item.namespace,
      "BSON DBPointer namespace",
      key,
      context
    )

    if not valid then
      return nil, validation_error
    end

    element_type = TYPE_DB_POINTER
    payload = encode_string_payload(item.namespace) .. item.object_id.binary
  elseif exact_kind == "int32" then
    element_type = TYPE_INT32
    payload = item.bytes
  elseif exact_kind == "int64" then
    element_type = TYPE_INT64
    payload = item.bytes
  elseif exact_kind == "double" then
    element_type = TYPE_DOUBLE
    payload = item.bytes
  elseif exact_kind == "decimal128" then
    element_type = TYPE_DECIMAL128
    payload = item.bid
  elseif item_type == "boolean" then
    element_type = TYPE_BOOLEAN
    payload = item and "\1" or "\0"
  elseif item_type == "string" then
    if #item > context.max_string_size or #item >= MAX_BSON_SIZE then
      return encode_error("BSON string exceeds the configured size limit", {
        key = key,
        length = #item,
        max_string_size = context.max_string_size,
      })
    end

    valid, validation_error = validate_encode_utf8(item, "BSON string", key, context)

    if not valid then
      return nil, validation_error
    end

    element_type = TYPE_STRING
    payload = encode_string_payload(item)
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

local function read_cstring(data, position, limit, description)
  local string_end = data:find("\0", position, true)

  if not string_end or string_end > limit then
    return nil, nil, bson_error(description .. " is not NUL-terminated", position)
  end

  return data:sub(position, string_end - 1), string_end + 1
end

local decode_value

local function decode_container(data, position, limit, array, context, depth)
  if depth > context.max_depth then
    return nil, nil, bson_error(
      "BSON nesting exceeds the configured maximum depth",
      position,
      { depth = depth, max_depth = context.max_depth }
    )
  end

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

  if length > context.max_document_size then
    return nil, nil, bson_error("BSON document exceeds the configured size limit", position, {
      length = length,
      max_document_size = context.max_document_size,
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

  while cursor < document_end do
    local element_type = data:byte(cursor)
    cursor = cursor + 1

    local key_position = cursor
    local key_end = data:find("\0", cursor, true)

    if not key_end or key_end >= document_end then
      return nil, nil, bson_error("BSON element name is not NUL-terminated", cursor)
    end

    local key = data:sub(cursor, key_end - 1)
    cursor = key_end + 1

    if context.validate_utf8 then
      local utf8_offset = invalid_utf8_offset(key)

      if utf8_offset then
        return nil, nil, bson_error(
          "BSON document key contains invalid UTF-8",
          key_position + utf8_offset - 1,
          { utf8_offset = utf8_offset }
        )
      end
    end

    local item
    item, cursor, err = decode_value(
      data,
      cursor,
      document_end - 1,
      element_type,
      context,
      depth
    )

    if err then
      return nil, nil, err
    end

    if array then
      entries[#entries + 1] = item
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

decode_value = function(data, position, limit, element_type, context, depth)
  if element_type == TYPE_NULL then
    return value.null, position
  end

  if element_type == TYPE_UNDEFINED then
    return tagged.undefined, position
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
    local number, next_position, err = read_integer(
      data,
      position,
      size,
      limit,
      "BSON integer"
    )

    if err then
      return nil, nil, err
    end

    local wrapped = element_type == TYPE_INT32 and exact.int32(number) or exact.int64(number)
    return wrapped, next_position
  end

  if element_type == TYPE_DOUBLE then
    local ok, err = require_bytes(position, 8, limit, "BSON double")

    if not ok then
      return nil, nil, err
    end

    local next_position = position + 8
    return exact.double_from_bytes(data:sub(position, next_position - 1)), next_position
  end

  if element_type == TYPE_OBJECT_ID then
    local ok, err = require_bytes(position, 12, limit, "BSON ObjectId")

    if not ok then
      return nil, nil, err
    end

    return tagged.object_id(data:sub(position, position + 11)), position + 12
  end

  if element_type == TYPE_DATETIME then
    local milliseconds, next_position, err = read_integer(
      data,
      position,
      8,
      limit,
      "BSON datetime"
    )

    if err then
      return nil, nil, err
    end

    return tagged.datetime(milliseconds), next_position
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

    if length - 1 > context.max_string_size then
      return nil, nil, bson_error("BSON string exceeds the configured size limit", position, {
        length = length - 1,
        max_string_size = context.max_string_size,
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

    local string_value = data:sub(string_position, string_end - 1)

    if context.validate_utf8 then
      local utf8_offset = invalid_utf8_offset(string_value)

      if utf8_offset then
        return nil, nil, bson_error(
          "BSON string contains invalid UTF-8",
          string_position + utf8_offset - 1
        )
      end
    end

    return string_value, string_end + 1
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

    if length > context.max_binary_size + 4 then
      return nil, nil, bson_error("BSON binary value exceeds the configured size limit", position, {
        length = length,
        max_binary_size = context.max_binary_size,
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

    if subtype == 2 then
      if length < 4 then
        return nil, nil, bson_error("old BSON binary subtype length is too small", position, {
          length = length,
        })
      end

      local inner_length = string.unpack("<i4", data, data_position)

      if inner_length < 0 or inner_length ~= length - 4 then
        return nil, nil, bson_error("old BSON binary subtype length mismatch", data_position, {
          inner_length = inner_length,
          outer_length = length,
        })
      end

      data_position = data_position + 4
    end

    local data_length = next_position - data_position

    if data_length > context.max_binary_size then
      return nil, nil, bson_error("BSON binary value exceeds the configured size limit", position, {
        length = data_length,
        max_binary_size = context.max_binary_size,
      })
    end

    return value.binary(data:sub(data_position, next_position - 1), subtype), next_position
  end

  if element_type == TYPE_REGEX then
    local pattern, options_position, err = read_cstring(
      data,
      position,
      limit,
      "BSON regex pattern"
    )

    if not pattern then
      return nil, nil, err
    end

    if #pattern > context.max_string_size then
      return nil, nil, bson_error(
        "BSON regex pattern exceeds the configured string size limit",
        position,
        { length = #pattern, max_string_size = context.max_string_size }
      )
    end

    local options, next_position
    options, next_position, err = read_cstring(
      data,
      options_position,
      limit,
      "BSON regex options"
    )

    if not options then
      return nil, nil, err
    end

    if context.validate_utf8 then
      local utf8_offset = invalid_utf8_offset(pattern)

      if utf8_offset then
        return nil, nil, bson_error(
          "BSON regex pattern contains invalid UTF-8",
          position + utf8_offset - 1
        )
      end
    end

    local ok, regex = pcall(tagged.regex, pattern, options)

    if not ok then
      return nil, nil, bson_error("invalid BSON regex options", options_position, {
        reason = regex,
      })
    end

    return regex, next_position
  end

  if element_type == TYPE_CODE then
    local source, next_position, err = decode_value(
      data,
      position,
      limit,
      TYPE_STRING,
      context,
      depth
    )

    if err then
      return nil, nil, err
    end

    return tagged.code(source), next_position
  end

  if element_type == TYPE_SYMBOL then
    local symbol_value, next_position, err = decode_value(
      data,
      position,
      limit,
      TYPE_STRING,
      context,
      depth
    )

    if err then
      return nil, nil, err
    end

    return tagged.symbol(symbol_value), next_position
  end

  if element_type == TYPE_DB_POINTER then
    local namespace, object_id_position, err = decode_value(
      data,
      position,
      limit,
      TYPE_STRING,
      context,
      depth
    )

    if err then
      return nil, nil, err
    end

    local object_id, next_position
    object_id, next_position, err = decode_value(
      data,
      object_id_position,
      limit,
      TYPE_OBJECT_ID,
      context,
      depth
    )

    if err then
      return nil, nil, err
    end

    return tagged.db_pointer(namespace, object_id), next_position
  end

  if element_type == TYPE_CODE_SCOPE then
    local total_length, source_position, err = read_integer(
      data,
      position,
      4,
      limit,
      "BSON code-with-scope length"
    )

    if not total_length then
      return nil, nil, err
    end

    if total_length < 14 then
      return nil, nil, bson_error("BSON code-with-scope length must be at least 14", position, {
        length = total_length,
      })
    end

    local code_end = position + total_length

    if code_end - 1 > limit then
      return nil, nil, bson_error("BSON code-with-scope exceeds available bytes", position, {
        length = total_length,
        available = limit - position + 1,
      })
    end

    local source, scope_position
    source, scope_position, err = decode_value(
      data,
      source_position,
      code_end - 1,
      TYPE_STRING,
      context,
      depth
    )

    if err then
      return nil, nil, err
    end

    local scope, next_position
    scope, next_position, err = decode_container(
      data,
      scope_position,
      code_end - 1,
      false,
      context,
      depth + 1
    )

    if err then
      return nil, nil, err
    end

    if next_position ~= code_end then
      return nil, nil, bson_error("BSON code scope does not fill its declared frame", next_position)
    end

    return tagged.code(source, scope), next_position
  end

  if element_type == TYPE_TIMESTAMP then
    local ok, err = require_bytes(position, 8, limit, "BSON timestamp")

    if not ok then
      return nil, nil, err
    end

    local increment, time, next_position = string.unpack("<I4I4", data, position)
    return tagged.timestamp(time, increment), next_position
  end

  if element_type == TYPE_DECIMAL128 then
    local ok, err = require_bytes(position, 16, limit, "BSON Decimal128")

    if not ok then
      return nil, nil, err
    end

    local next_position = position + 16
    return exact.decimal128_from_bid(data:sub(position, next_position - 1)), next_position
  end

  if element_type == TYPE_MIN_KEY then
    return tagged.min_key, position
  end

  if element_type == TYPE_MAX_KEY then
    return tagged.max_key, position
  end

  if element_type == TYPE_DOCUMENT or element_type == TYPE_ARRAY then
    return decode_container(
      data,
      position,
      limit,
      element_type == TYPE_ARRAY,
      context,
      depth + 1
    )
  end

  return nil, nil, bson_error("unsupported BSON element type", position - 1, {
    element_type = element_type,
  })
end

function M.encode(document, options)
  if not value.is_document(document) then
    return encode_error("BSON root value must be an ordered document", {
      lua_type = type(document),
    })
  end

  return encode_container(document, false, codec_options(options), 1)
end

function M.decode(data, options)
  if type(data) ~= "string" then
    error("BSON input must be a string", 2)
  end

  local context = codec_options(options)
  local document, next_position, err = decode_container(data, 1, #data, false, context, 1)

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
