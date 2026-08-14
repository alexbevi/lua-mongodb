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

local function validate_sized_text(
  text,
  description,
  size_error,
  key,
  context,
  signed_length
)
  if #text > context.max_string_size
      or signed_length and #text >= MAX_BSON_SIZE then
    return encode_error(size_error, {
      key = key,
      length = #text,
      max_string_size = context.max_string_size,
    })
  end

  return validate_encode_utf8(text, description, key, context)
end

local function encode_null_value()
  return TYPE_NULL, ""
end

local function encode_document_value(item, _, context, depth)
  local payload, err = encode_container(item, false, context, depth + 1)

  if not payload then
    return nil, err
  end

  return TYPE_DOCUMENT, payload
end

local function encode_array_value(item, _, context, depth)
  local payload, err = encode_container(item, true, context, depth + 1)

  if not payload then
    return nil, err
  end

  return TYPE_ARRAY, payload
end

local function encode_binary_value(item, key, context)
  local length_overhead = item.subtype == 2 and 4 or 0

  if #item.data > context.max_binary_size
      or #item.data > MAX_BSON_SIZE - length_overhead then
    return encode_error("BSON binary value exceeds the configured size limit", {
      key = key,
      length = #item.data,
      max_binary_size = context.max_binary_size,
    })
  end

  if item.subtype == 2 then
    return TYPE_BINARY,
      string.pack("<i4Bi4", #item.data + 4, item.subtype, #item.data) .. item.data
  end

  return TYPE_BINARY,
    string.pack("<i4B", #item.data, item.subtype) .. item.data
end

local function encode_object_id_value(item)
  return TYPE_OBJECT_ID, item.binary
end

local function encode_datetime_value(item)
  return TYPE_DATETIME, string.pack("<i8", item.milliseconds)
end

local function encode_regex_value(item, key, context)
  local valid, err = validate_sized_text(
    item.pattern,
    "BSON regex pattern",
    "BSON regex pattern exceeds the configured string size limit",
    key,
    context,
    false
  )

  if not valid then
    return nil, err
  end

  return TYPE_REGEX, item.pattern .. "\0" .. item.options .. "\0"
end

local function encode_timestamp_value(item)
  return TYPE_TIMESTAMP, string.pack("<I4I4", item.increment, item.time)
end

local function encode_code_value(item, key, context, depth)
  local valid, err = validate_sized_text(
    item.source,
    "BSON code",
    "BSON code exceeds the configured string size limit",
    key,
    context,
    true
  )

  if not valid then
    return nil, err
  elseif item.scope == nil then
    return TYPE_CODE, encode_string_payload(item.source)
  end

  local scope

  scope, err = encode_container(item.scope, false, context, depth + 1)

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

  return TYPE_CODE_SCOPE, string.pack("<i4", total_length) .. source .. scope
end

local function encode_min_key_value()
  return TYPE_MIN_KEY, ""
end

local function encode_max_key_value()
  return TYPE_MAX_KEY, ""
end

local function encode_undefined_value()
  return TYPE_UNDEFINED, ""
end

local function encode_symbol_value(item, key, context)
  local valid, err = validate_sized_text(
    item.value,
    "BSON symbol",
    "BSON symbol exceeds the configured string size limit",
    key,
    context,
    true
  )

  if not valid then
    return nil, err
  end

  return TYPE_SYMBOL, encode_string_payload(item.value)
end

local function encode_db_pointer_value(item, key, context)
  local valid, err = validate_sized_text(
    item.namespace,
    "BSON DBPointer namespace",
    "BSON DBPointer namespace exceeds the configured string size limit",
    key,
    context,
    true
  )

  if not valid then
    return nil, err
  end

  return TYPE_DB_POINTER,
    encode_string_payload(item.namespace) .. item.object_id.binary
end

local function encode_int32_value(item)
  return TYPE_INT32, item.bytes
end

local function encode_int64_value(item)
  return TYPE_INT64, item.bytes
end

local function encode_double_value(item)
  return TYPE_DOUBLE, item.bytes
end

local function encode_decimal128_value(item)
  return TYPE_DECIMAL128, item.bid
end

local function encode_boolean_value(item)
  return TYPE_BOOLEAN, item and "\1" or "\0"
end

local function encode_string_value(item, key, context)
  local valid, err = validate_sized_text(
    item,
    "BSON string",
    "BSON string exceeds the configured size limit",
    key,
    context,
    true
  )

  if not valid then
    return nil, err
  end

  return TYPE_STRING, encode_string_payload(item)
end

local function encode_number_value(item)
  if math.type(item) ~= "integer" then
    return TYPE_DOUBLE, string.pack("<d", item)
  elseif item >= INT32_MIN and item <= INT32_MAX then
    return TYPE_INT32, string.pack("<i4", item)
  end

  return TYPE_INT64, string.pack("<i8", item)
end

local TAGGED_ENCODERS = {
  code = encode_code_value,
  datetime = encode_datetime_value,
  db_pointer = encode_db_pointer_value,
  max_key = encode_max_key_value,
  min_key = encode_min_key_value,
  object_id = encode_object_id_value,
  regex = encode_regex_value,
  symbol = encode_symbol_value,
  timestamp = encode_timestamp_value,
  undefined = encode_undefined_value,
}

local EXACT_ENCODERS = {
  decimal128 = encode_decimal128_value,
  double = encode_double_value,
  int32 = encode_int32_value,
  int64 = encode_int64_value,
}

local LUA_ENCODERS = {
  boolean = encode_boolean_value,
  number = encode_number_value,
  string = encode_string_value,
}

local function encoder_for(item)
  if value.is_null(item) then
    return encode_null_value
  elseif value.is_document(item) then
    return encode_document_value
  elseif value.is_array(item) then
    return encode_array_value
  elseif value.is_binary(item) then
    return encode_binary_value
  end

  return TAGGED_ENCODERS[tagged.kind(item)]
    or EXACT_ENCODERS[exact.kind(item)]
    or LUA_ENCODERS[type(item)]
end

encode_element = function(key, item, context, depth)
  local valid, validation_error = validate_encode_utf8(
    key,
    "BSON document key",
    key,
    context
  )

  if not valid then
    return nil, validation_error
  end

  local encoder = encoder_for(item)

  if not encoder then
    return encode_error("unsupported Lua value for BSON encoding", {
      key = key,
      lua_type = type(item),
    })
  end

  local element_type, payload = encoder(item, key, context, depth)

  if not element_type then
    return nil, payload
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

local function decode_null_value(_, position)
  return value.null, position
end

local function decode_undefined_value(_, position)
  return tagged.undefined, position
end

local function decode_boolean_value(data, position, limit)
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

local function decode_integer_value(data, position, limit, size, constructor)
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

  return constructor(number), next_position
end

local function decode_int32_value(data, position, limit)
  return decode_integer_value(data, position, limit, 4, exact.int32)
end

local function decode_int64_value(data, position, limit)
  return decode_integer_value(data, position, limit, 8, exact.int64)
end

local function decode_double_value(data, position, limit)
  local ok, err = require_bytes(position, 8, limit, "BSON double")

  if not ok then
    return nil, nil, err
  end

  local next_position = position + 8
  return exact.double_from_bytes(data:sub(position, next_position - 1)), next_position
end

local function decode_object_id_value(data, position, limit)
  local ok, err = require_bytes(position, 12, limit, "BSON ObjectId")

  if not ok then
    return nil, nil, err
  end

  return tagged.object_id(data:sub(position, position + 11)), position + 12
end

local function decode_datetime_value(data, position, limit)
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

local function decode_string_value(data, position, limit, context)
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

local function decode_binary_value(data, position, limit, context)
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

local function decode_regex_value(data, position, limit, context)
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

local function decode_code_value(data, position, limit, context)
  local source, next_position, err = decode_string_value(
    data,
    position,
    limit,
    context
  )

  if err then
    return nil, nil, err
  end

  return tagged.code(source), next_position
end

local function decode_symbol_value(data, position, limit, context)
  local symbol_value, next_position, err = decode_string_value(
    data,
    position,
    limit,
    context
  )

  if err then
    return nil, nil, err
  end

  return tagged.symbol(symbol_value), next_position
end

local function decode_db_pointer_value(data, position, limit, context)
  local namespace, object_id_position, err = decode_string_value(
    data,
    position,
    limit,
    context
  )

  if err then
    return nil, nil, err
  end

  local object_id, next_position
  object_id, next_position, err = decode_object_id_value(
    data,
    object_id_position,
    limit
  )

  if err then
    return nil, nil, err
  end

  return tagged.db_pointer(namespace, object_id), next_position
end

local function decode_code_scope_value(data, position, limit, context, depth)
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
  source, scope_position, err = decode_string_value(
    data,
    source_position,
    code_end - 1,
    context
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

local function decode_timestamp_value(data, position, limit)
  local ok, err = require_bytes(position, 8, limit, "BSON timestamp")

  if not ok then
    return nil, nil, err
  end

  local increment, time, next_position = string.unpack("<I4I4", data, position)
  return tagged.timestamp(time, increment), next_position
end

local function decode_decimal128_value(data, position, limit)
  local ok, err = require_bytes(position, 16, limit, "BSON Decimal128")

  if not ok then
    return nil, nil, err
  end

  local next_position = position + 16
  return exact.decimal128_from_bid(data:sub(position, next_position - 1)), next_position
end

local function decode_min_key_value(_, position)
  return tagged.min_key, position
end

local function decode_max_key_value(_, position)
  return tagged.max_key, position
end

local function decode_document_value(data, position, limit, context, depth)
  return decode_container(data, position, limit, false, context, depth + 1)
end

local function decode_array_value(data, position, limit, context, depth)
  return decode_container(data, position, limit, true, context, depth + 1)
end

local DECODERS = {
  [TYPE_DOUBLE] = decode_double_value,
  [TYPE_STRING] = decode_string_value,
  [TYPE_DOCUMENT] = decode_document_value,
  [TYPE_ARRAY] = decode_array_value,
  [TYPE_BINARY] = decode_binary_value,
  [TYPE_UNDEFINED] = decode_undefined_value,
  [TYPE_OBJECT_ID] = decode_object_id_value,
  [TYPE_BOOLEAN] = decode_boolean_value,
  [TYPE_DATETIME] = decode_datetime_value,
  [TYPE_NULL] = decode_null_value,
  [TYPE_REGEX] = decode_regex_value,
  [TYPE_DB_POINTER] = decode_db_pointer_value,
  [TYPE_CODE] = decode_code_value,
  [TYPE_SYMBOL] = decode_symbol_value,
  [TYPE_CODE_SCOPE] = decode_code_scope_value,
  [TYPE_INT32] = decode_int32_value,
  [TYPE_TIMESTAMP] = decode_timestamp_value,
  [TYPE_INT64] = decode_int64_value,
  [TYPE_DECIMAL128] = decode_decimal128_value,
  [TYPE_MAX_KEY] = decode_max_key_value,
  [TYPE_MIN_KEY] = decode_min_key_value,
}

decode_value = function(data, position, limit, element_type, context, depth)
  local decoder = DECODERS[element_type]

  if not decoder then
    return nil, nil, bson_error("unsupported BSON element type", position - 1, {
      element_type = element_type,
    })
  end

  return decoder(data, position, limit, context, depth)
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
