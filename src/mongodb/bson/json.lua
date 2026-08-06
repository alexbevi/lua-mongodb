local base64 = require("mongodb.bson.base64")
local errors = require("mongodb.error")
local exact = require("mongodb.bson.exact")
local tagged = require("mongodb.bson.tagged")
local value = require("mongodb.bson.value")

local M = {}

local DEFAULT_OPTIONS = {
  max_depth = 200,
  max_input_size = 16 * 1024 * 1024,
  max_string_size = 16 * 1024 * 1024,
  mode = "relaxed",
}

local function json_error(message, offset, details)
  details = details or {}
  details.offset = offset

  return errors.new({
    category = errors.CATEGORY.BSON,
    message = message,
    details = details,
  })
end

local function options_with_defaults(options)
  options = options or {}

  if type(options) ~= "table" then
    error("JSON options must be a table", 3)
  end

  local result = {}

  for name, default in pairs(DEFAULT_OPTIONS) do
    result[name] = options[name] == nil and default or options[name]
  end

  for name in pairs(options) do
    if DEFAULT_OPTIONS[name] == nil then
      error("unknown JSON option: " .. tostring(name), 3)
    end
  end

  if result.mode ~= "canonical" and result.mode ~= "relaxed" then
    error("JSON mode must be canonical or relaxed", 3)
  end

  for _, name in ipairs({ "max_depth", "max_input_size", "max_string_size" }) do
    if math.type(result[name]) ~= "integer" or result[name] <= 0 then
      error(name .. " must be a positive integer", 3)
    end
  end

  return result
end

local function new_parser(text, options)
  return {
    length = #text,
    options = options,
    position = 1,
    text = text,
  }
end

local function fail(parser, message, offset, details)
  if not parser.failure then
    parser.failure = json_error(message, offset or parser.position, details)
  end
end

local function skip_whitespace(parser)
  while true do
    local byte = parser.text:byte(parser.position)

    if byte ~= 0x20 and byte ~= 0x09 and byte ~= 0x0a and byte ~= 0x0d then
      return
    end

    parser.position = parser.position + 1
  end
end

local function append_codepoint(result, codepoint)
  if codepoint <= 0x7f then
    result[#result + 1] = string.char(codepoint)
  elseif codepoint <= 0x7ff then
    result[#result + 1] = string.char(
      0xc0 | (codepoint >> 6),
      0x80 | (codepoint & 0x3f)
    )
  elseif codepoint <= 0xffff then
    result[#result + 1] = string.char(
      0xe0 | (codepoint >> 12),
      0x80 | ((codepoint >> 6) & 0x3f),
      0x80 | (codepoint & 0x3f)
    )
  else
    result[#result + 1] = string.char(
      0xf0 | (codepoint >> 18),
      0x80 | ((codepoint >> 12) & 0x3f),
      0x80 | ((codepoint >> 6) & 0x3f),
      0x80 | (codepoint & 0x3f)
    )
  end
end

local function read_hex_escape(parser)
  local hex = parser.text:sub(parser.position, parser.position + 3)

  if #hex ~= 4 or not hex:match("^[0-9a-fA-F]+$") then
    fail(parser, "JSON Unicode escape must contain four hexadecimal digits")
    return nil
  end

  parser.position = parser.position + 4
  return tonumber(hex, 16)
end

local ESCAPES = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
}

local function parse_string(parser)
  local start = parser.position
  local result = {}

  parser.position = parser.position + 1

  while parser.position <= parser.length do
    local byte = parser.text:byte(parser.position)

    if byte == 0x22 then
      parser.position = parser.position + 1
      local string_value = table.concat(result)

      if #string_value > parser.options.max_string_size then
        fail(parser, "JSON string exceeds the configured size limit", start)
        return nil
      end

      local utf8_length, utf8_offset = utf8.len(string_value)

      if utf8_length == nil then
        fail(parser, "JSON string contains invalid UTF-8", start + utf8_offset)
        return nil
      end

      return string_value
    end

    if byte < 0x20 then
      fail(parser, "JSON strings cannot contain unescaped control characters")
      return nil
    end

    if byte ~= 0x5c then
      result[#result + 1] = string.char(byte)
      parser.position = parser.position + 1
    else
      parser.position = parser.position + 1
      local escape = parser.text:sub(parser.position, parser.position)
      local decoded = ESCAPES[escape]

      if decoded then
        result[#result + 1] = decoded
        parser.position = parser.position + 1
      elseif escape == "u" then
        parser.position = parser.position + 1
        local codepoint = read_hex_escape(parser)

        if not codepoint then
          return nil
        end

        if codepoint >= 0xd800 and codepoint <= 0xdbff then
          if parser.text:sub(parser.position, parser.position + 1) ~= "\\u" then
            fail(parser, "JSON high surrogate must be followed by a low surrogate")
            return nil
          end

          parser.position = parser.position + 2
          local low = read_hex_escape(parser)

          if not low or low < 0xdc00 or low > 0xdfff then
            fail(parser, "JSON high surrogate must be followed by a low surrogate")
            return nil
          end

          codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + low - 0xdc00
        elseif codepoint >= 0xdc00 and codepoint <= 0xdfff then
          fail(parser, "JSON low surrogate has no preceding high surrogate")
          return nil
        end

        append_codepoint(result, codepoint)
      else
        fail(parser, "invalid JSON string escape")
        return nil
      end
    end
  end

  fail(parser, "unterminated JSON string", start)
  return nil
end

local parse_value

local function parse_array(parser, depth)
  if depth > parser.options.max_depth then
    fail(parser, "JSON nesting exceeds the configured maximum depth")
    return nil
  end

  local values = {}

  parser.position = parser.position + 1
  skip_whitespace(parser)

  if parser.text:byte(parser.position) == 0x5d then
    parser.position = parser.position + 1
    return value.array(values)
  end

  while true do
    local item = parse_value(parser, depth)

    if item == nil then
      return nil
    end

    values[#values + 1] = item
    skip_whitespace(parser)

    local byte = parser.text:byte(parser.position)

    if byte == 0x5d then
      parser.position = parser.position + 1
      return value.array(values)
    end

    if byte ~= 0x2c then
      fail(parser, "JSON array expects a comma or closing bracket")
      return nil
    end

    parser.position = parser.position + 1
    skip_whitespace(parser)
  end
end

local function parse_object(parser, depth)
  if depth > parser.options.max_depth then
    fail(parser, "JSON nesting exceeds the configured maximum depth")
    return nil
  end

  local entries = {}

  parser.position = parser.position + 1
  skip_whitespace(parser)

  if parser.text:byte(parser.position) == 0x7d then
    parser.position = parser.position + 1
    return value.document(entries)
  end

  while true do
    if parser.text:byte(parser.position) ~= 0x22 then
      fail(parser, "JSON object keys must be strings")
      return nil
    end

    local key = parse_string(parser)

    if key == nil then
      return nil
    end

    if key:find("\0", 1, true) then
      fail(parser, "JSON object keys cannot contain NUL bytes")
      return nil
    end

    skip_whitespace(parser)

    if parser.text:byte(parser.position) ~= 0x3a then
      fail(parser, "JSON object key must be followed by a colon")
      return nil
    end

    parser.position = parser.position + 1
    local item = parse_value(parser, depth)

    if item == nil then
      return nil
    end

    entries[#entries + 1] = { key, item }
    skip_whitespace(parser)

    local byte = parser.text:byte(parser.position)

    if byte == 0x7d then
      parser.position = parser.position + 1
      return value.document(entries)
    end

    if byte ~= 0x2c then
      fail(parser, "JSON object expects a comma or closing brace")
      return nil
    end

    parser.position = parser.position + 1
    skip_whitespace(parser)
  end
end

local function parse_number(parser)
  local start = parser.position
  local position = start
  local text = parser.text

  if text:sub(position, position) == "-" then
    position = position + 1
  end

  if text:sub(position, position) == "0" then
    position = position + 1

    if text:sub(position, position):match("%d") then
      fail(parser, "JSON number cannot contain a leading zero", start)
      return nil
    end
  elseif text:sub(position, position):match("[1-9]") then
    repeat
      position = position + 1
    until not text:sub(position, position):match("%d")
  else
    fail(parser, "invalid JSON number", start)
    return nil
  end

  local integral = true

  if text:sub(position, position) == "." then
    integral = false
    position = position + 1

    if not text:sub(position, position):match("%d") then
      fail(parser, "JSON number fraction requires digits", start)
      return nil
    end

    repeat
      position = position + 1
    until not text:sub(position, position):match("%d")
  end

  if text:sub(position, position):match("[eE]") then
    integral = false
    position = position + 1

    if text:sub(position, position):match("[+-]") then
      position = position + 1
    end

    if not text:sub(position, position):match("%d") then
      fail(parser, "JSON number exponent requires digits", start)
      return nil
    end

    repeat
      position = position + 1
    until not text:sub(position, position):match("%d")
  end

  local lexeme = text:sub(start, position - 1)
  local number = tonumber(lexeme)

  if number == nil or number == math.huge or number == -math.huge then
    fail(parser, "JSON number is outside the supported numeric range", start)
    return nil
  end

  parser.position = position

  if integral and math.type(number) == "integer" then
    if number >= -0x80000000 and number <= 0x7fffffff then
      return exact.int32(number)
    end

    return exact.int64(number)
  end

  return exact.double(number)
end

parse_value = function(parser, depth)
  skip_whitespace(parser)
  local byte = parser.text:byte(parser.position)

  if byte == 0x22 then
    return parse_string(parser)
  end

  if byte == 0x7b then
    return parse_object(parser, depth + 1)
  end

  if byte == 0x5b then
    return parse_array(parser, depth + 1)
  end

  for literal, literal_value in pairs({
    ["false"] = false,
    ["null"] = value.null,
    ["true"] = true,
  }) do
    if parser.text:sub(parser.position, parser.position + #literal - 1) == literal then
      parser.position = parser.position + #literal
      return literal_value
    end
  end

  if byte == 0x2d or byte and byte >= 0x30 and byte <= 0x39 then
    return parse_number(parser)
  end

  fail(parser, "unexpected token in JSON value")
  return nil
end

local function parse_raw(text, options)
  if type(text) ~= "string" then
    error("JSON input must be a string", 3)
  end

  if #text > options.max_input_size then
    return nil, json_error("JSON input exceeds the configured size limit", 1)
  end

  local parser = new_parser(text, options)
  local parsed = parse_value(parser, 0)

  if parsed == nil then
    return nil, parser.failure
  end

  skip_whitespace(parser)

  if parser.position ~= parser.length + 1 then
    return nil, json_error("trailing data follows the JSON value", parser.position)
  end

  return parsed
end

local function entry_map(document)
  local fields = {}

  for key, item in document:iter() do
    if fields[key] ~= nil then
      return nil, "duplicate Extended JSON wrapper field"
    end

    fields[key] = item
  end

  return fields
end

local function field_count(fields)
  local count = 0

  for _ in pairs(fields) do
    count = count + 1
  end

  return count
end

local function parse_integer_string(text, kind)
  if type(text) ~= "string" or not text:match("^[+-]?%d+$") then
    return nil
  end

  local number = tonumber(text)

  if math.type(number) ~= "integer" then
    return nil
  end

  local ok, result = pcall(kind == "int32" and exact.int32 or exact.int64, number)
  return ok and result or nil
end

local function wrapper_error(message)
  return nil, json_error(message, 1)
end

local convert_extended

local function require_wrapper_fields(fields, expected)
  if field_count(fields) ~= #expected then
    return false
  end

  for _, name in ipairs(expected) do
    if fields[name] == nil then
      return false
    end
  end

  return true
end

local function integer_value(item)
  if exact.is(item, "int32") or exact.is(item, "int64") then
    return item.value
  end
end

local function parse_uuid(text)
  if type(text) ~= "string" then
    return nil
  end

  local canonical = text:match(
    "^(%x%x%x%x%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x%x%x%x%x%x%x%x%x)$"
  )
  local compact

  if canonical then
    compact = text:gsub("%-", "")
  elseif text:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
    compact = text
  else
    return nil
  end

  return (compact:gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function days_from_civil(year, month, day)
  local adjusted_year = month <= 2 and year - 1 or year
  local era = adjusted_year // 400
  local year_of_era = adjusted_year - era * 400
  local adjusted_month = month + (month > 2 and -3 or 9)
  local day_of_year = (153 * adjusted_month + 2) // 5 + day - 1
  local day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
  return era * 146097 + day_of_era - 719468
end

local function leap_year(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function parse_iso_datetime(text)
  if type(text) ~= "string" then
    return nil
  end

  local year, month, day, hour, minute, second, tail = text:match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$"
  )

  if not year then
    return nil
  end

  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
  local days_in_month = { 31, leap_year(year) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

  if month < 1 or month > 12 or day < 1 or day > days_in_month[month]
      or hour > 23 or minute > 59 or second > 59 then
    return nil
  end

  local fraction = ""
  local timezone = tail
  local fraction_text, remaining = tail:match("^%.(%d+)(.*)$")

  if fraction_text then
    fraction = fraction_text
    timezone = remaining
  end

  local offset_seconds = 0

  if timezone ~= "Z" then
    local sign, offset_hour, offset_minute = timezone:match("^([+-])(%d%d):?(%d%d)$")

    if not sign then
      sign, offset_hour = timezone:match("^([+-])(%d%d)$")
      offset_minute = "00"
    end

    offset_hour, offset_minute = tonumber(offset_hour), tonumber(offset_minute)

    if not sign or offset_hour > 23 or offset_minute > 59 then
      return nil
    end

    offset_seconds = (offset_hour * 60 + offset_minute) * 60

    if sign == "-" then
      offset_seconds = -offset_seconds
    end
  end

  local milliseconds = tonumber((fraction .. "000"):sub(1, 3))
  local seconds = days_from_civil(year, month, day) * 86400
    + hour * 3600 + minute * 60 + second - offset_seconds
  return seconds * 1000 + milliseconds
end

local KNOWN_WRAPPERS = {
  ["$binary"] = true,
  ["$code"] = true,
  ["$date"] = true,
  ["$dbPointer"] = true,
  ["$maxKey"] = true,
  ["$minKey"] = true,
  ["$numberDecimal"] = true,
  ["$numberDouble"] = true,
  ["$numberInt"] = true,
  ["$numberLong"] = true,
  ["$oid"] = true,
  ["$regularExpression"] = true,
  ["$symbol"] = true,
  ["$timestamp"] = true,
  ["$undefined"] = true,
  ["$uuid"] = true,
}

local function convert_document(document, depth, options)
  local entries = {}

  for key, item in document:iter() do
    local converted, err = convert_extended(item, depth + 1, options)

    if converted == nil then
      return nil, err
    end

    entries[#entries + 1] = { key, converted }
  end

  local converted_document = value.document(entries)
  local fields, duplicate_error = entry_map(converted_document)

  if not fields then
    return wrapper_error(duplicate_error)
  end

  local wrapper

  for key in pairs(fields) do
    if KNOWN_WRAPPERS[key] then
      wrapper = key
      break
    end
  end

  if not wrapper then
    return converted_document
  end

  if wrapper == "$numberInt" or wrapper == "$numberLong" then
    if not require_wrapper_fields(fields, { wrapper }) then
      return wrapper_error("invalid " .. wrapper .. " wrapper fields")
    end

    local numeric_kind = wrapper == "$numberInt" and "int32" or "int64"
    local parsed = parse_integer_string(fields[wrapper], numeric_kind)

    if parsed then
      return parsed
    end

    return wrapper_error("invalid " .. wrapper .. " value")
  end

  if wrapper == "$numberDouble" then
    if not require_wrapper_fields(fields, { wrapper }) or type(fields[wrapper]) ~= "string" then
      return wrapper_error("invalid $numberDouble wrapper")
    end

    local text = fields[wrapper]
    local number = text == "Infinity" and math.huge
      or text == "-Infinity" and -math.huge
      or text == "NaN" and 0 / 0
      or tonumber(text)

    if number == nil then
      return wrapper_error("invalid $numberDouble value")
    end

    return exact.double(number)
  end

  if wrapper == "$numberDecimal" then
    if not require_wrapper_fields(fields, { wrapper }) or type(fields[wrapper]) ~= "string" then
      return wrapper_error("invalid $numberDecimal wrapper")
    end

    local ok, decimal = pcall(exact.decimal128, fields[wrapper])

    if ok then
      return decimal
    end

    return wrapper_error("invalid $numberDecimal value")
  end

  if wrapper == "$oid" then
    if not require_wrapper_fields(fields, { wrapper }) or type(fields[wrapper]) ~= "string" then
      return wrapper_error("invalid $oid wrapper")
    end

    local ok, object_id = pcall(tagged.object_id, fields[wrapper])

    if ok then
      return object_id
    end

    return wrapper_error("invalid $oid value")
  end

  if wrapper == "$binary" then
    if not require_wrapper_fields(fields, { wrapper })
        or not value.is_document(fields[wrapper]) then
      return wrapper_error("invalid $binary wrapper")
    end

    local binary_fields = entry_map(fields[wrapper])

    if not binary_fields or not require_wrapper_fields(binary_fields, { "base64", "subType" })
        or type(binary_fields.base64) ~= "string" or type(binary_fields.subType) ~= "string"
        or not binary_fields.subType:match("^%x%x$") then
      return wrapper_error("invalid $binary value")
    end

    local data = base64.decode(binary_fields.base64)

    if not data then
      return wrapper_error("invalid $binary base64 value")
    end

    return value.binary(data, tonumber(binary_fields.subType, 16))
  end

  if wrapper == "$uuid" then
    if not require_wrapper_fields(fields, { wrapper }) then
      return wrapper_error("invalid $uuid wrapper fields")
    end

    local data = parse_uuid(fields[wrapper])

    if data then
      return value.binary(data, 4)
    end

    return wrapper_error("invalid $uuid value")
  end

  if wrapper == "$date" then
    if not require_wrapper_fields(fields, { wrapper }) then
      return wrapper_error("invalid $date wrapper fields")
    end

    local milliseconds

    if exact.is(fields[wrapper], "int64") then
      milliseconds = fields[wrapper].value
    elseif type(fields[wrapper]) == "string" then
      milliseconds = parse_iso_datetime(fields[wrapper])
    end

    if milliseconds then
      return tagged.datetime(milliseconds)
    end

    return wrapper_error("invalid $date value")
  end

  if wrapper == "$regularExpression" then
    if not require_wrapper_fields(fields, { wrapper })
        or not value.is_document(fields[wrapper]) then
      return wrapper_error("invalid $regularExpression wrapper")
    end

    local regex_fields = entry_map(fields[wrapper])

    if not regex_fields or not require_wrapper_fields(regex_fields, { "pattern", "options" })
        or type(regex_fields.pattern) ~= "string" or type(regex_fields.options) ~= "string" then
      return wrapper_error("invalid $regularExpression value")
    end

    local ok, regex = pcall(tagged.regex, regex_fields.pattern, regex_fields.options)

    if ok then
      return regex
    end

    return wrapper_error("invalid $regularExpression value")
  end

  if wrapper == "$timestamp" then
    if not require_wrapper_fields(fields, { wrapper })
        or not value.is_document(fields[wrapper]) then
      return wrapper_error("invalid $timestamp wrapper")
    end

    local timestamp_fields = entry_map(fields[wrapper])

    if not timestamp_fields or not require_wrapper_fields(timestamp_fields, { "t", "i" }) then
      return wrapper_error("invalid $timestamp value")
    end

    local time = integer_value(timestamp_fields.t)
    local increment = integer_value(timestamp_fields.i)
    local ok, timestamp = pcall(tagged.timestamp, time, increment)

    if ok then
      return timestamp
    end

    return wrapper_error("invalid $timestamp value")
  end

  if wrapper == "$code" then
    local expected = fields["$scope"] == nil and { "$code" } or { "$code", "$scope" }

    if not require_wrapper_fields(fields, expected) or type(fields["$code"]) ~= "string"
        or fields["$scope"] ~= nil and not value.is_document(fields["$scope"]) then
      return wrapper_error("invalid $code wrapper")
    end

    return tagged.code(fields["$code"], fields["$scope"])
  end

  if wrapper == "$minKey" or wrapper == "$maxKey" then
    if not require_wrapper_fields(fields, { wrapper }) or integer_value(fields[wrapper]) ~= 1 then
      return wrapper_error("invalid " .. wrapper .. " wrapper")
    end

    return wrapper == "$minKey" and tagged.min_key or tagged.max_key
  end

  if wrapper == "$undefined" then
    if not require_wrapper_fields(fields, { wrapper }) or fields[wrapper] ~= true then
      return wrapper_error("invalid $undefined wrapper")
    end

    return tagged.undefined
  end

  if wrapper == "$symbol" then
    if not require_wrapper_fields(fields, { wrapper }) or type(fields[wrapper]) ~= "string" then
      return wrapper_error("invalid $symbol wrapper")
    end

    return tagged.symbol(fields[wrapper])
  end

  if wrapper == "$dbPointer" then
    if not require_wrapper_fields(fields, { wrapper })
        or not value.is_document(fields[wrapper]) then
      return wrapper_error("invalid $dbPointer wrapper")
    end

    local pointer_fields = entry_map(fields[wrapper])

    if not pointer_fields or not require_wrapper_fields(pointer_fields, { "$ref", "$id" })
        or type(pointer_fields["$ref"]) ~= "string"
        or not tagged.is(pointer_fields["$id"], "object_id") then
      return wrapper_error("invalid $dbPointer value")
    end

    return tagged.db_pointer(pointer_fields["$ref"], pointer_fields["$id"])
  end

  return converted_document
end

convert_extended = function(item, depth, options)
  if depth > options.max_depth then
    return wrapper_error("Extended JSON nesting exceeds the configured maximum depth")
  end

  if value.is_document(item) then
    return convert_document(item, depth, options)
  end

  if value.is_array(item) then
    local values = {}

    for index, array_item in item:iter() do
      local converted, err = convert_extended(array_item, depth + 1, options)

      if converted == nil then
        return nil, err
      end

      values[index] = converted
    end

    return value.array(values)
  end

  return item
end

local function escape_string(text)
  local result = { '"' }

  for position = 1, #text do
    local byte = text:byte(position)

    if byte == 0x22 then
      result[#result + 1] = '\\"'
    elseif byte == 0x5c then
      result[#result + 1] = "\\\\"
    elseif byte == 0x08 then
      result[#result + 1] = "\\b"
    elseif byte == 0x0c then
      result[#result + 1] = "\\f"
    elseif byte == 0x0a then
      result[#result + 1] = "\\n"
    elseif byte == 0x0d then
      result[#result + 1] = "\\r"
    elseif byte == 0x09 then
      result[#result + 1] = "\\t"
    elseif byte < 0x20 then
      result[#result + 1] = string.format("\\u%04x", byte)
    else
      result[#result + 1] = string.char(byte)
    end
  end

  result[#result + 1] = '"'
  return table.concat(result)
end

local function object_json(entries)
  local result = {}

  for index, entry in ipairs(entries) do
    result[index] = escape_string(entry[1]) .. ":" .. entry[2]
  end

  return "{" .. table.concat(result, ",") .. "}"
end

local function double_string(number)
  if number ~= number then
    return "NaN"
  end

  if number == math.huge then
    return "Infinity"
  end

  if number == -math.huge then
    return "-Infinity"
  end

  local text = tostring(number):gsub("e", "E")
  text = text:gsub("E([+-])0+(%d+)", "E%1%2")

  if not text:find("[%.E]") then
    text = text .. ".0"
  end

  return text
end

local function civil_from_days(days)
  local shifted = days + 719468
  local era = shifted // 146097
  local day_of_era = shifted - era * 146097
  local year_of_era = (
    day_of_era - day_of_era // 1460 + day_of_era // 36524 - day_of_era // 146096
  ) // 365
  local year = year_of_era + era * 400
  local day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
  local month_part = (5 * day_of_year + 2) // 153
  local day = day_of_year - (153 * month_part + 2) // 5 + 1
  local month = month_part + (month_part < 10 and 3 or -9)
  year = year + (month <= 2 and 1 or 0)
  return year, month, day
end

local function iso_datetime(milliseconds)
  if milliseconds < 0 or milliseconds > 253402300799999 then
    return nil
  end

  local seconds = milliseconds // 1000
  local fraction = milliseconds % 1000
  local days = seconds // 86400
  local remainder = seconds % 86400
  local year, month, day = civil_from_days(days)
  local hour = remainder // 3600
  local minute = remainder % 3600 // 60
  local second = remainder % 60
  return string.format(
    "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
    year,
    month,
    day,
    hour,
    minute,
    second,
    fraction
  )
end

local encode_extended

local function wrapper(name, encoded_value)
  return object_json({ { name, encoded_value } })
end

local function validate_output_text(text, options, description)
  if #text > options.max_string_size then
    return wrapper_error(description .. " exceeds the configured string size limit")
  end

  if utf8.len(text) == nil then
    return wrapper_error(description .. " contains invalid UTF-8")
  end

  return true
end

encode_extended = function(item, options, depth)
  if depth > options.max_depth then
    return wrapper_error("Extended JSON nesting exceeds the configured maximum depth")
  end

  if value.is_null(item) then
    return "null"
  end

  if value.is_document(item) then
    local entries = {}

    for key, document_value in item:iter() do
      local valid, validation_error = validate_output_text(
        key,
        options,
        "JSON object key"
      )

      if not valid then
        return nil, validation_error
      end

      local encoded, err = encode_extended(document_value, options, depth + 1)

      if not encoded then
        return nil, err
      end

      entries[#entries + 1] = { key, encoded }
    end

    return object_json(entries)
  end

  if value.is_array(item) then
    local values = {}

    for index, array_value in item:iter() do
      local encoded, err = encode_extended(array_value, options, depth + 1)

      if not encoded then
        return nil, err
      end

      values[index] = encoded
    end

    return "[" .. table.concat(values, ",") .. "]"
  end

  if value.is_binary(item) then
    local encoded_data = base64.encode(item.data)

    if #encoded_data > options.max_string_size then
      return wrapper_error("Extended JSON binary value exceeds the configured string size limit")
    end

    return wrapper("$binary", object_json({
      { "base64", escape_string(encoded_data) },
      { "subType", escape_string(string.format("%02x", item.subtype)) },
    }))
  end

  local exact_kind = exact.kind(item)

  if exact_kind == "int32" then
    return options.mode == "canonical"
      and wrapper("$numberInt", escape_string(tostring(item.value)))
      or tostring(item.value)
  end

  if exact_kind == "int64" then
    return options.mode == "canonical"
      and wrapper("$numberLong", escape_string(tostring(item.value)))
      or tostring(item.value)
  end

  if exact_kind == "double" then
    local text = double_string(item.value)

    if options.mode == "canonical" or text == "NaN"
        or text == "Infinity" or text == "-Infinity" then
      return wrapper("$numberDouble", escape_string(text))
    end

    return text
  end

  if exact_kind == "decimal128" then
    return wrapper("$numberDecimal", escape_string(tostring(item)))
  end

  local tagged_kind = tagged.kind(item)

  if tagged_kind == "object_id" then
    return wrapper("$oid", escape_string(item.hex))
  end

  if tagged_kind == "datetime" then
    local iso = options.mode == "relaxed" and iso_datetime(item.milliseconds)

    if iso then
      return wrapper("$date", escape_string(iso))
    end

    return wrapper("$date", wrapper("$numberLong", escape_string(tostring(item.milliseconds))))
  end

  if tagged_kind == "regex" then
    local valid, validation_error = validate_output_text(
      item.pattern,
      options,
      "Extended JSON regex pattern"
    )

    if not valid then
      return nil, validation_error
    end

    return wrapper("$regularExpression", object_json({
      { "pattern", escape_string(item.pattern) },
      { "options", escape_string(item.options) },
    }))
  end

  if tagged_kind == "timestamp" then
    return wrapper("$timestamp", object_json({
      { "t", tostring(item.time) },
      { "i", tostring(item.increment) },
    }))
  end

  if tagged_kind == "code" then
    local valid, validation_error = validate_output_text(
      item.source,
      options,
      "Extended JSON code"
    )

    if not valid then
      return nil, validation_error
    end

    local entries = { { "$code", escape_string(item.source) } }

    if item.scope then
      local scope, err = encode_extended(item.scope, options, depth + 1)

      if not scope then
        return nil, err
      end

      entries[#entries + 1] = { "$scope", scope }
    end

    return object_json(entries)
  end

  if tagged_kind == "min_key" or tagged_kind == "max_key" then
    return wrapper(tagged_kind == "min_key" and "$minKey" or "$maxKey", "1")
  end

  if tagged_kind == "undefined" then
    return wrapper("$undefined", "true")
  end

  if tagged_kind == "symbol" then
    local valid, validation_error = validate_output_text(
      item.value,
      options,
      "Extended JSON symbol"
    )

    if not valid then
      return nil, validation_error
    end

    return wrapper("$symbol", escape_string(item.value))
  end

  if tagged_kind == "db_pointer" then
    local valid, validation_error = validate_output_text(
      item.namespace,
      options,
      "Extended JSON DBPointer namespace"
    )

    if not valid then
      return nil, validation_error
    end

    return wrapper("$dbPointer", object_json({
      { "$ref", escape_string(item.namespace) },
      { "$id", wrapper("$oid", escape_string(item.object_id.hex)) },
    }))
  end

  if type(item) == "string" then
    local valid, validation_error = validate_output_text(
      item,
      options,
      "JSON string"
    )

    if not valid then
      return nil, validation_error
    end

    return escape_string(item)
  end

  if type(item) == "boolean" then
    return tostring(item)
  end

  return wrapper_error("value cannot be represented as Extended JSON")
end

function M.decode(text, options)
  local resolved = options_with_defaults(options)
  local parsed, err = parse_raw(text, resolved)

  if not parsed then
    return nil, err
  end

  return convert_extended(parsed, 0, resolved)
end

function M.encode(item, options)
  local resolved = options_with_defaults(options)
  local encoded, err = encode_extended(item, resolved, 0)

  if not encoded then
    return nil, err
  end

  if #encoded > resolved.max_input_size then
    return wrapper_error("JSON output exceeds the configured size limit")
  end

  return encoded
end

function M.parse(text, options)
  return parse_raw(text, options_with_defaults(options))
end

return M
