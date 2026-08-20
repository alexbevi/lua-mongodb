local errors = require("mongodb.error")

local M = {}

local OP_CODE = 2012
local HEADER_SIZE = 25
local DEFAULT_MAX_MESSAGE_SIZE = 48000000
local MAX_INT32 = 0x7fffffff

M.OP_CODE = OP_CODE

local function valid_int32(value)
  return math.type(value) == "integer"
    and value >= -0x80000000
    and value <= MAX_INT32
end

local function protocol_error(message, cause, details)
  return nil, errors.new({
    category = errors.CATEGORY.PROTOCOL,
    cause = errors.is(cause) and cause or nil,
    details = details,
    message = message,
  })
end

local function validate_options(options)
  if type(options) ~= "table" then
    error("OP_COMPRESSED options must be a table", 3)
  end

  if type(options.body) ~= "string" then
    error("OP_COMPRESSED body must be a string", 3)
  end

  local compressor = options.compressor

  if type(compressor) ~= "table"
      or math.type(compressor.compressor_id) ~= "integer"
      or compressor.compressor_id < 1
      or compressor.compressor_id > 255
      or type(compressor.compress) ~= "function" then
    error("OP_COMPRESSED compressor is invalid", 3)
  end

  if not valid_int32(options.original_opcode) then
    return protocol_error("OP_COMPRESSED original_opcode must be a signed 32-bit integer")
  end

  if not valid_int32(options.request_id) then
    return protocol_error("OP_COMPRESSED request_id must be a signed 32-bit integer")
  end

  if #options.body > MAX_INT32 then
    return protocol_error("OP_COMPRESSED body exceeds the signed 32-bit size limit", nil, {
      size = #options.body,
    })
  end

  return compressor
end

local function max_message_size(options)
  local value = options.max_message_size or DEFAULT_MAX_MESSAGE_SIZE

  if math.type(value) ~= "integer" or value < HEADER_SIZE then
    error("max_message_size must be an integer of at least 25", 3)
  end

  return value
end

local function provider_by_id(compression, compressor_id)
  if compression == nil then
    return nil
  end

  if type(compression) ~= "table" then
    error("OP_COMPRESSED compression capabilities must be a table", 3)
  end

  for _, provider in pairs(compression) do
    if type(provider) == "table" and provider.compressor_id == compressor_id then
      return provider
    end
  end

  return nil
end

function M.encode(options)
  local compressor, err = validate_options(options)

  if compressor == nil then
    return nil, err
  end

  local compressed, compression_err = compressor:compress(
    options.body,
    options.compression_level
  )

  if type(compressed) ~= "string" then
    return protocol_error("OP_COMPRESSED compression failed", compression_err)
  end

  local message_size = HEADER_SIZE + #compressed

  if message_size > MAX_INT32 then
    return protocol_error("OP_COMPRESSED frame exceeds the signed 32-bit size limit", nil, {
      size = message_size,
    })
  end

  local header = string.pack(
    "<i4i4i4i4i4i4B",
    message_size,
    options.request_id,
    0,
    OP_CODE,
    options.original_opcode,
    #options.body,
    compressor.compressor_id
  )

  return header .. compressed
end

function M.decode(bytes, options)
  if type(bytes) ~= "string" then
    error("OP_COMPRESSED input must be a string", 2)
  end

  options = options or {}

  if type(options) ~= "table" then
    error("OP_COMPRESSED decode options must be a table", 2)
  end

  local maximum = max_message_size(options)

  if #bytes <= HEADER_SIZE then
    return protocol_error("OP_COMPRESSED frame is too short", nil, { size = #bytes })
  end

  if #bytes > maximum then
    return protocol_error("OP_COMPRESSED exceeds maxMessageSizeBytes", nil, {
      max_message_size = maximum,
      size = #bytes,
    })
  end

  local message_size, request_id, response_to, op_code, original_opcode,
    uncompressed_size, compressor_id = string.unpack("<i4i4i4i4i4i4B", bytes)

  if message_size ~= #bytes then
    return protocol_error("OP_COMPRESSED messageLength does not match the frame", nil, {
      actual = #bytes,
      declared = message_size,
    })
  end

  if op_code ~= OP_CODE then
    return protocol_error("wire frame is not OP_COMPRESSED", nil, { op_code = op_code })
  end

  if uncompressed_size < 0 or uncompressed_size > maximum - 16 then
    return protocol_error("OP_COMPRESSED uncompressedSize is outside the permitted range", nil, {
      max_message_size = maximum,
      uncompressed_size = uncompressed_size,
    })
  end

  local provider = provider_by_id(options.compression, compressor_id)

  if provider == nil or type(provider.decompress) ~= "function" then
    return protocol_error("OP_COMPRESSED compressor is unavailable", nil, {
      compressor_id = compressor_id,
    })
  end

  local body, decompression_err = provider:decompress(bytes:sub(HEADER_SIZE + 1))

  if type(body) ~= "string" then
    return protocol_error("OP_COMPRESSED decompression failed", decompression_err)
  end

  if #body ~= uncompressed_size then
    return protocol_error("OP_COMPRESSED uncompressedSize does not match the body", nil, {
      actual = #body,
      declared = uncompressed_size,
    })
  end

  local header = string.pack(
    "<i4i4i4i4",
    16 + #body,
    request_id,
    response_to,
    original_opcode
  )

  return header .. body
end

return M
