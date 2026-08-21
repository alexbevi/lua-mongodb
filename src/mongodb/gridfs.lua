local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local DEFAULT_CHUNK_SIZE_BYTES = 255 * 1024
local MAX_INT32 = 0x7fffffff
local BUCKET_STATES = setmetatable({}, { __mode = "k" })
local BUCKET_METHODS = {}
local UPLOAD_STATES = setmetatable({}, { __mode = "k" })
local UPLOAD_METHODS = {}
local UPLOAD_PROPERTIES = {
  chunk_size_bytes = true,
  closed = true,
  filename = true,
  id = true,
  length = true,
  upload_date = true,
}

local FILES_INDEX_KEYS = bson.document({
  { "filename", 1 },
  { "uploadDate", 1 },
})
local CHUNKS_INDEX_KEYS = bson.document({
  { "files_id", 1 },
  { "n", 1 },
})

local BUCKET_METATABLE = {
  __index = function(value, key)
    local method = BUCKET_METHODS[key]

    if method then
      return method
    end

    local state = BUCKET_STATES[value]

    if state then
      return state[key]
    end
  end,
  __metatable = "mongodb.gridfs_bucket",
  __newindex = function()
    error("MongoDB GridFS bucket handles are immutable", 2)
  end,
}

local UPLOAD_METATABLE = {
  __index = function(value, key)
    local method = UPLOAD_METHODS[key]

    if method then
      return method
    end

    local state = UPLOAD_STATES[value]

    if state and UPLOAD_PROPERTIES[key] then
      return state[key]
    end
  end,
  __metatable = "mongodb.gridfs_upload_stream",
  __newindex = function()
    error("MongoDB GridFS upload streams are immutable", 2)
  end,
}

local function configuration_error(message, option)
  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    details = { option = option },
    message = message,
  })
end

local function client_error(message)
  return nil, errors.new({
    category = errors.CATEGORY.CLIENT,
    message = message,
  })
end

local function validate_options(options)
  if options == nil then
    return {}
  elseif type(options) ~= "table" then
    error("GridFS bucket options must be a table", 3)
  end

  local allowed = {
    bucket_name = true,
    chunk_size_bytes = true,
    disable_md5 = true,
    read_concern = true,
    read_preference = true,
    timeout_ms = true,
    write_concern = true,
  }

  for key in pairs(options) do
    if not allowed[key] then
      error("unknown GridFS bucket option: " .. tostring(key), 3)
    end
  end

  if options.disable_md5 ~= nil and type(options.disable_md5) ~= "boolean" then
    return configuration_error("disable_md5 must be a boolean", "disable_md5")
  end

  return options
end

local function numeric_value(value)
  if type(value) == "number" then
    return value
  elseif type(value) == "table" and type(value.to_number) == "function" then
    return value:to_number()
  end
end

local function index_keys_equal(left, right)
  if not bson.is_document(left) or not bson.is_document(right) then
    return false
  end

  local left_keys = left:keys()
  local right_keys = right:keys()

  if #left_keys ~= #right_keys then
    return false
  end

  for index, key in ipairs(left_keys) do
    if right_keys[index] ~= key then
      return false
    end

    local left_value = left:get(key)
    local right_value = right:get(key)
    local left_number = numeric_value(left_value)
    local right_number = numeric_value(right_value)

    if left_number == nil or right_number == nil
        or left_number ~= right_number
    then
      return false
    end
  end

  return true
end

local function ensure_index(collection, keys, unique)
  local cursor, err = collection:list_indexes()

  if not cursor then
    return nil, err
  end

  local exists = false

  while true do
    local index
    index, err = cursor:next()

    if not index then
      if err then
        return nil, err
      end

      break
    end

    if index_keys_equal(index:get("key"), keys) then
      exists = true
    end
  end

  if exists then
    return true
  end

  local name
  name, err = collection:create_index(keys, unique and { unique = true } or nil)

  if not name then
    return nil, err
  end

  return true
end

local function ensure_required_indexes(state)
  if state.indexes_checked then
    return true
  end

  local existing, err = state.primary_files_collection:find_one(
    bson.document({}),
    { projection = bson.document({ { "_id", 1 } }) }
  )

  if err then
    return nil, err
  elseif existing then
    state.indexes_checked = true
    return true
  end

  local ready
  ready, err = ensure_index(state.files_collection, FILES_INDEX_KEYS, false)

  if not ready then
    return nil, err
  end

  ready, err = ensure_index(state.chunks_collection, CHUNKS_INDEX_KEYS, true)

  if not ready then
    return nil, err
  end

  state.indexes_checked = true
  return true
end

local function validate_filename(filename)
  if type(filename) ~= "string" then
    error("GridFS upload filename must be a string", 3)
  elseif utf8.len(filename) == nil then
    error("GridFS upload filename must be valid UTF-8", 3)
  end
end

local function upload_chunk_size(state, options)
  options = options or {}

  if type(options) ~= "table" then
    error("GridFS upload options must be a table", 3)
  end

  local chunk_size_bytes = options.chunk_size_bytes or state.chunk_size_bytes

  if math.type(chunk_size_bytes) ~= "integer"
      or chunk_size_bytes <= 0
      or chunk_size_bytes > MAX_INT32
  then
    return configuration_error(
      "chunk_size_bytes must be a positive 32-bit integer",
      "chunk_size_bytes"
    )
  end

  return chunk_size_bytes
end

local function new_upload(state, identifier, filename, options)
  validate_filename(filename)

  local chunk_size_bytes, err = upload_chunk_size(state, options)

  if not chunk_size_bytes then
    return nil, err
  end

  local metadata = options and options.metadata

  if metadata ~= nil and not bson.is_document(metadata) then
    error("GridFS upload metadata must be a BSON document", 3)
  end

  local value = {}

  UPLOAD_STATES[value] = {
    buffer = "",
    bucket_state = state,
    chunk_size_bytes = chunk_size_bytes,
    chunk_number = 0,
    closed = false,
    filename = filename,
    id = identifier,
    length = 0,
    metadata = metadata,
  }

  return setmetatable(value, UPLOAD_METATABLE)
end

function BUCKET_METHODS:open_upload_stream(filename, options)
  local state = BUCKET_STATES[self]
  local generator = state.files_collection.object_ids

  if type(generator) ~= "table" or type(generator.new) ~= "function" then
    error("GridFS bucket is missing its ObjectId generator", 2)
  end

  local identifier, err = generator:new()

  if not identifier then
    return nil, err
  end

  return new_upload(state, identifier, filename, options)
end

function BUCKET_METHODS:open_upload_stream_with_id(identifier, filename, options)
  if identifier == nil then
    error("GridFS upload id must not be nil", 2)
  end

  return new_upload(BUCKET_STATES[self], identifier, filename, options)
end

local function flush_chunk(state)
  if #state.buffer == 0 then
    return true
  end

  local ready, err = ensure_required_indexes(state.bucket_state)

  if not ready then
    state.failure = err
    return nil, err
  end

  local result
  result, err = state.bucket_state.chunks_collection:insert_one(bson.document({
    { "files_id", state.id },
    { "n", state.chunk_number },
    { "data", bson.binary(state.buffer) },
  }))

  if not result then
    state.failure = err
    return nil, err
  end

  state.buffer = ""
  state.chunk_number = state.chunk_number + 1
  return true
end

function UPLOAD_METHODS:write(data)
  local state = UPLOAD_STATES[self]

  if state.closed then
    return client_error("cannot write to a closed GridFS upload stream")
  elseif state.failure then
    return nil, state.failure
  elseif type(data) ~= "string" then
    error("GridFS upload data must be a string", 2)
  end

  local position = 1

  while position <= #data do
    local available = state.chunk_size_bytes - #state.buffer
    local count = math.min(available, #data - position + 1)

    state.buffer = state.buffer .. data:sub(position, position + count - 1)
    position = position + count

    if #state.buffer == state.chunk_size_bytes then
      local written, err = flush_chunk(state)

      if not written then
        return nil, err
      end
    end
  end

  state.length = state.length + #data
  return true
end

local function file_document(state, upload_date)
  local entries = {
    { "_id", state.id },
    { "length", bson.int64(state.length) },
    { "chunkSize", state.chunk_size_bytes },
    { "uploadDate", upload_date },
    { "filename", state.filename },
  }

  if state.metadata ~= nil then
    entries[#entries + 1] = { "metadata", state.metadata }
  end

  return bson.document(entries)
end

function UPLOAD_METHODS:close()
  local state = UPLOAD_STATES[self]

  if state.closed then
    return true
  elseif state.failure then
    return nil, state.failure
  end

  local ready, err = flush_chunk(state)

  if not ready then
    return nil, err
  end

  ready, err = ensure_required_indexes(state.bucket_state)

  if not ready then
    return nil, err
  end

  local runtime = state.bucket_state.files_collection.runtime
  local upload_date = bson.datetime(math.floor(runtime.clock:wall_time() * 1000))
  local result
  result, err = state.bucket_state.files_collection:insert_one(
    file_document(state, upload_date)
  )

  if not result then
    return nil, err
  end

  state.closed = true
  state.upload_date = upload_date
  return true
end

function M.new(database, options)
  if getmetatable(database) ~= "mongodb.database" then
    error("GridFS buckets require a MongoDB database handle", 2)
  end

  local validated, err = validate_options(options)

  if not validated then
    return nil, err
  end

  local bucket_name = validated.bucket_name or "fs"
  local chunk_size_bytes = validated.chunk_size_bytes or DEFAULT_CHUNK_SIZE_BYTES

  if type(bucket_name) ~= "string" or bucket_name == "" then
    return configuration_error(
      "bucket_name must be a non-empty string",
      "bucket_name"
    )
  elseif utf8.len(bucket_name) == nil then
    return configuration_error("bucket_name must be valid UTF-8", "bucket_name")
  end

  if math.type(chunk_size_bytes) ~= "integer"
      or chunk_size_bytes <= 0
      or chunk_size_bytes > MAX_INT32
  then
    return configuration_error(
      "chunk_size_bytes must be a positive 32-bit integer",
      "chunk_size_bytes"
    )
  end

  local collection_options = {
    read_concern = validated.read_concern,
    read_preference = validated.read_preference,
    timeout_ms = validated.timeout_ms,
    write_concern = validated.write_concern,
  }
  local files_collection
  files_collection, err = database:collection(
    bucket_name .. ".files",
    collection_options
  )

  if not files_collection then
    return nil, err
  end

  if files_collection.write_concern.w == 0 then
    return configuration_error(
      "GridFS write concern must be acknowledged",
      "write_concern"
    )
  end

  local chunks_collection
  chunks_collection, err = database:collection(
    bucket_name .. ".chunks",
    collection_options
  )

  if not chunks_collection then
    return nil, err
  end

  local primary_collection_options = {
    read_concern = validated.read_concern,
    read_preference = { mode = "primary" },
    timeout_ms = validated.timeout_ms,
    write_concern = validated.write_concern,
  }
  local primary_files_collection
  primary_files_collection, err = database:collection(
    bucket_name .. ".files",
    primary_collection_options
  )

  if not primary_files_collection then
    return nil, err
  end

  local value = {}

  BUCKET_STATES[value] = {
    bucket_name = bucket_name,
    chunk_size_bytes = chunk_size_bytes,
    chunks_collection = chunks_collection,
    database = database,
    disable_md5 = validated.disable_md5 == true,
    files_collection = files_collection,
    indexes_checked = false,
    primary_files_collection = primary_files_collection,
    read_concern = files_collection.read_concern,
    read_preference = files_collection.read_preference,
    timeout_ms = files_collection.timeout_ms,
    write_concern = files_collection.write_concern,
  }

  return setmetatable(value, BUCKET_METATABLE)
end

return M
