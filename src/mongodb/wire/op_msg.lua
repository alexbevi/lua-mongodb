local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local OP_CODE = 2013
local DEFAULT_MAX_BSON_SIZE = 16 * 1024 * 1024
local DEFAULT_MAX_MESSAGE_SIZE = 48000000
local MAX_REQUEST_ID = 0x7fffffff
local CHECKSUM_PRESENT = 1
local MORE_TO_COME = 1 << 1
local EXHAUST_ALLOWED = 1 << 16
local REQUIRED_FLAG_MASK = 0xffff
local KNOWN_REQUIRED_FLAGS = CHECKSUM_PRESENT | MORE_TO_COME

local ID_STATES = setmetatable({}, { __mode = "k" })
local ID_METHODS = {}
local ID_METATABLE = {
  __index = ID_METHODS,
  __metatable = "mongodb.wire.request_ids",
  __newindex = function()
    error("request ID generators are immutable", 2)
  end,
}

local FLAG_VALUES = {
  CHECKSUM_PRESENT = CHECKSUM_PRESENT,
  EXHAUST_ALLOWED = EXHAUST_ALLOWED,
  MORE_TO_COME = MORE_TO_COME,
}

M.FLAG = setmetatable({}, {
  __index = FLAG_VALUES,
  __metatable = "mongodb.wire.op_msg.flags",
  __newindex = function()
    error("OP_MSG flags are immutable", 2)
  end,
  __pairs = function()
    return next, FLAG_VALUES, nil
  end,
})
M.OP_CODE = OP_CODE

local function protocol_error(message, details)
  return nil, errors.new({
    category = errors.CATEGORY.PROTOCOL,
    details = details,
    message = message,
  })
end

local function dense_length(name, value)
  if type(value) ~= "table" then
    error(name .. " must be an array", 3)
  end

  local length = #value

  for key in pairs(value) do
    if math.type(key) ~= "integer" or key < 1 or key > length then
      error(name .. " must be a dense array", 3)
    end
  end

  return length
end

local function valid_int32(value)
  return math.type(value) == "integer"
    and value >= -0x80000000
    and value <= 0x7fffffff
end

local function limits(options)
  local max_bson_size = options.max_bson_size or DEFAULT_MAX_BSON_SIZE
  local max_message_size = options.max_message_size or DEFAULT_MAX_MESSAGE_SIZE

  if math.type(max_bson_size) ~= "integer" or max_bson_size < 5 then
    error("max_bson_size must be an integer of at least 5", 3)
  end

  if math.type(max_message_size) ~= "integer" or max_message_size < 21 then
    error("max_message_size must be an integer of at least 21", 3)
  end

  return max_bson_size, max_message_size
end

local function validate_flags(flags, direction)
  if math.type(flags) ~= "integer" or flags < 0 or flags > 0xffffffff then
    return protocol_error("OP_MSG flags must be an unsigned 32-bit integer")
  end

  if flags & CHECKSUM_PRESENT ~= 0 then
    return protocol_error("OP_MSG checksums are not supported", { flags = flags })
  end

  local unknown_required = (flags & REQUIRED_FLAG_MASK) & (~KNOWN_REQUIRED_FLAGS)

  if unknown_required ~= 0 then
    return protocol_error("OP_MSG contains unsupported required flags", {
      flags = flags,
      unsupported = unknown_required,
    })
  end

  if direction == "response" and flags & EXHAUST_ALLOWED ~= 0 then
    return protocol_error("OP_MSG responses cannot set exhaustAllowed", { flags = flags })
  end

  return true
end

local function encode_document(document, max_bson_size, component)
  local encoded, err = bson.encode(document)

  if not encoded then
    return nil, err
  end

  if #encoded > max_bson_size then
    return protocol_error(component .. " exceeds maxBsonObjectSize", {
      max_bson_size = max_bson_size,
      size = #encoded,
    })
  end

  return encoded
end

local function prepare(options)
  if type(options) ~= "table" then
    error("OP_MSG options must be a table", 3)
  end

  local request_id = options.request_id
  local response_to = options.response_to or 0
  local flags = options.flags or 0
  local direction = options.direction or "request"

  if not valid_int32(request_id) then
    return protocol_error("OP_MSG request_id must be a signed 32-bit integer")
  end

  if not valid_int32(response_to) then
    return protocol_error("OP_MSG response_to must be a signed 32-bit integer")
  end

  if direction ~= "request" and direction ~= "response" then
    error("OP_MSG direction must be request or response", 3)
  end

  local flags_ok, flags_err = validate_flags(flags, direction)

  if not flags_ok then
    return nil, flags_err
  end

  local max_bson_size, max_message_size = limits(options)
  local max_sequence_document_size = options.max_sequence_document_size
    or math.min(max_bson_size, max_message_size)

  if math.type(max_sequence_document_size) ~= "integer"
      or max_sequence_document_size <= 0
      or max_sequence_document_size > max_message_size
  then
    error(
      "max_sequence_document_size must be a positive integer no larger than max_message_size",
      3
    )
  end

  local body_bytes, body_err = encode_document(options.body, max_bson_size, "OP_MSG body")

  if not body_bytes then
    return nil, body_err
  end

  local parts = { string.pack("<I4B", flags, 0), body_bytes }
  local sequence_bytes = 0
  local max_document_size = 0
  local identifiers = {}
  local sequences = options.sequences or {}

  for sequence_index = 1, dense_length("OP_MSG sequences", sequences) do
    local sequence = sequences[sequence_index]

    if type(sequence) ~= "table" then
      error("OP_MSG sequence entries must be tables", 3)
    end

    local identifier = sequence.identifier

    if type(identifier) ~= "string" or identifier == ""
      or identifier:find("\0", 1, true)
    then
      return protocol_error("OP_MSG sequence identifier must be a non-empty cstring")
    end

    if identifiers[identifier] then
      return protocol_error("OP_MSG sequence identifiers must be unique", {
        identifier = identifier,
      })
    end

    identifiers[identifier] = true
    local documents = sequence.documents or {}
    local document_parts = {}
    local documents_size = 0

    for document_index = 1, dense_length("OP_MSG sequence documents", documents) do
      local encoded, encode_err = encode_document(
        documents[document_index],
        max_sequence_document_size,
        "OP_MSG sequence document"
      )

      if not encoded then
        return nil, encode_err
      end

      document_parts[#document_parts + 1] = encoded
      documents_size = documents_size + #encoded
      max_document_size = math.max(max_document_size, #encoded)
    end

    local section_size = 4 + #identifier + 1 + documents_size

    parts[#parts + 1] = string.pack("<Bi4", 1, section_size)
    parts[#parts + 1] = identifier .. "\0"

    for _, encoded in ipairs(document_parts) do
      parts[#parts + 1] = encoded
    end

    sequence_bytes = sequence_bytes + 1 + section_size
  end

  local payload = table.concat(parts)
  local message_size = 16 + #payload

  if message_size > max_message_size then
    return protocol_error("OP_MSG exceeds maxMessageSizeBytes", {
      max_message_size = max_message_size,
      size = message_size,
    })
  end

  return {
    body_size = #body_bytes,
    flags = flags,
    max_document_size = max_document_size,
    message_size = message_size,
    payload = payload,
    request_id = request_id,
    response_to = response_to,
    sequence_bytes = sequence_bytes,
  }
end

function ID_METHODS:next()
  local state = ID_STATES[self]
  local value = state.next_id

  state.next_id = value == MAX_REQUEST_ID and 1 or value + 1
  return value
end

function M.request_ids(first_id)
  first_id = first_id or 1

  if math.type(first_id) ~= "integer" or first_id < 1 or first_id > MAX_REQUEST_ID then
    error("first request ID must be an integer from 1 through 2147483647", 2)
  end

  local generator = {}

  ID_STATES[generator] = { next_id = first_id }
  return setmetatable(generator, ID_METATABLE)
end

function M.measure(options)
  local prepared, err = prepare(options)

  if not prepared then
    return nil, err
  end

  return {
    body_size = prepared.body_size,
    max_document_size = prepared.max_document_size,
    message_size = prepared.message_size,
    sequence_bytes = prepared.sequence_bytes,
  }
end

function M.encode(options)
  local prepared, err = prepare(options)

  if not prepared then
    return nil, err
  end

  local header = string.pack(
    "<i4i4i4i4",
    prepared.message_size,
    prepared.request_id,
    prepared.response_to,
    OP_CODE
  )

  return header .. prepared.payload
end

local function decode_document(bytes, position, limit, max_bson_size, component)
  if position + 3 > limit then
    return protocol_error(component .. " is missing its BSON length")
  end

  local length = string.unpack("<i4", bytes, position)

  if length < 5 then
    return protocol_error(component .. " has an invalid BSON length", { length = length })
  end

  if length > max_bson_size then
    return protocol_error(component .. " exceeds maxBsonObjectSize", {
      max_bson_size = max_bson_size,
      size = length,
    })
  end

  local next_position = position + length

  if next_position - 1 > limit then
    return protocol_error(component .. " extends beyond its section")
  end

  local document, err = bson.decode(bytes:sub(position, next_position - 1))

  if not document then
    return protocol_error(component .. " contains malformed BSON", {
      bson_error = tostring(err),
    })
  end

  return document, next_position
end


local function decode_sequence(bytes, position, frame_end, max_bson_size)
  if position + 3 > frame_end then
    return protocol_error("OP_MSG kind-1 section is missing its size")
  end

  local size = string.unpack("<i4", bytes, position)

  if size < 5 then
    return protocol_error("OP_MSG kind-1 section has an invalid size", { size = size })
  end

  local next_section = position + size

  if next_section - 1 > frame_end then
    return protocol_error("OP_MSG kind-1 section extends beyond the message")
  end

  local identifier_start = position + 4
  local terminator = bytes:find("\0", identifier_start, true)

  if not terminator or terminator >= next_section then
    return protocol_error("OP_MSG kind-1 section has an unterminated identifier")
  end

  local identifier = bytes:sub(identifier_start, terminator - 1)

  if identifier == "" then
    return protocol_error("OP_MSG kind-1 section has an empty identifier")
  end

  local documents = {}
  local document_position = terminator + 1

  while document_position < next_section do
    local document, next_position = decode_document(
      bytes,
      document_position,
      next_section - 1,
      max_bson_size,
      "OP_MSG sequence document"
    )

    if not document then
      return nil, next_position
    end

    documents[#documents + 1] = document
    document_position = next_position
  end

  return { documents = documents, identifier = identifier }, next_section
end

function M.decode(bytes, options)
  if type(bytes) ~= "string" then
    error("OP_MSG input must be a string", 2)
  end

  options = options or {}

  if type(options) ~= "table" then
    error("OP_MSG decode options must be a table", 2)
  end

  local direction = options.direction or "response"

  if direction ~= "request" and direction ~= "response" then
    error("OP_MSG direction must be request or response", 2)
  end

  local max_bson_size, max_message_size = limits(options)

  if #bytes < 21 then
    return protocol_error("OP_MSG frame is too short", { size = #bytes })
  end

  if #bytes > max_message_size then
    return protocol_error("OP_MSG exceeds maxMessageSizeBytes", {
      max_message_size = max_message_size,
      size = #bytes,
    })
  end

  local message_size, request_id, response_to, op_code, flags, position = string.unpack(
    "<i4i4i4i4I4",
    bytes
  )

  if message_size ~= #bytes then
    return protocol_error("OP_MSG messageLength does not match the frame", {
      actual = #bytes,
      declared = message_size,
    })
  end

  if op_code ~= OP_CODE then
    return protocol_error("wire frame is not OP_MSG", { op_code = op_code })
  end

  local flags_ok, flags_err = validate_flags(flags, direction)

  if not flags_ok then
    return nil, flags_err
  end

  if options.expected_response_to ~= nil then
    if not valid_int32(options.expected_response_to) then
      error("expected_response_to must be a signed 32-bit integer", 2)
    end

    if response_to ~= options.expected_response_to then
      return protocol_error("OP_MSG responseTo does not match the request", {
        actual = response_to,
        expected = options.expected_response_to,
      })
    end
  end

  local body
  local sequences = {}
  local identifiers = {}

  while position <= #bytes do
    local payload_type = bytes:byte(position)

    position = position + 1

    if payload_type == 0 then
      if body then
        return protocol_error("OP_MSG must contain exactly one kind-0 body")
      end

      local next_position
      body, next_position = decode_document(
        bytes,
        position,
        #bytes,
        max_bson_size,
        "OP_MSG body"
      )

      if not body then
        return nil, next_position
      end

      position = next_position
    elseif payload_type == 1 then
      local sequence, next_position = decode_sequence(
        bytes,
        position,
        #bytes,
        max_bson_size
      )

      if not sequence then
        return nil, next_position
      end

      if identifiers[sequence.identifier] then
        return protocol_error("OP_MSG sequence identifiers must be unique", {
          identifier = sequence.identifier,
        })
      end

      identifiers[sequence.identifier] = true
      sequences[#sequences + 1] = sequence
      position = next_position
    else
      return protocol_error("OP_MSG contains an unknown payload type", {
        payload_type = payload_type,
      })
    end
  end

  if not body then
    return protocol_error("OP_MSG must contain exactly one kind-0 body")
  end

  return {
    body = body,
    flags = flags,
    more_to_come = flags & MORE_TO_COME ~= 0,
    request_id = request_id,
    response_to = response_to,
    sequences = sequences,
  }
end

return M
