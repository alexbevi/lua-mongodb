local errors = require("mongodb.error")

local M = {}

local DEFAULT_CHUNK_SIZE_BYTES = 255 * 1024
local MAX_INT32 = 0x7fffffff
local BUCKET_STATES = setmetatable({}, { __mode = "k" })
local BUCKET_METHODS = {}

local BUCKET_METATABLE = {
  __index = function(value, key)
    local method = BUCKET_METHODS[key]

    if method then
      return method
    end

    local state = BUCKET_STATES[value]
    return state and state[key] or nil
  end,
  __metatable = "mongodb.gridfs_bucket",
  __newindex = function()
    error("MongoDB GridFS bucket handles are immutable", 2)
  end,
}

local function configuration_error(message, option)
  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    details = { option = option },
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

  local value = {}

  BUCKET_STATES[value] = {
    bucket_name = bucket_name,
    chunk_size_bytes = chunk_size_bytes,
    chunks_collection = chunks_collection,
    database = database,
    disable_md5 = validated.disable_md5 == true,
    files_collection = files_collection,
    read_concern = files_collection.read_concern,
    read_preference = files_collection.read_preference,
    timeout_ms = files_collection.timeout_ms,
    write_concern = files_collection.write_concern,
  }

  return setmetatable(value, BUCKET_METATABLE)
end

return M
