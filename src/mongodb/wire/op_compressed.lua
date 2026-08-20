local errors = require("mongodb.error")

local M = {}

local OP_CODE = 2012
local HEADER_SIZE = 25
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

return M
