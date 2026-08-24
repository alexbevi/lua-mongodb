local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local operation_timeout = require("mongodb.operation_timeout")

local M = {}

local DEFAULT_CHUNK_SIZE_BYTES = 255 * 1024
local DOWNLOAD_BUFFER_SIZE = 64 * 1024
local MAX_INT32 = 0x7fffffff
local MIN_INT32 = -0x80000000
local BUCKET_STATES = setmetatable({}, { __mode = "k" })
local BUCKET_METHODS = {}
local DOWNLOAD_STATES = setmetatable({}, { __mode = "k" })
local DOWNLOAD_METHODS = {}
local DOWNLOAD_PROPERTIES = {
  chunk_size_bytes = true,
  closed = true,
  filename = true,
  id = true,
  length = true,
  metadata = true,
  upload_date = true,
}
local UPLOAD_STATES = setmetatable({}, { __mode = "k" })
local UPLOAD_METHODS = {}
local UPLOAD_PROPERTIES = {
  aborted = true,
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

local DOWNLOAD_METATABLE = {
  __index = function(value, key)
    local method = DOWNLOAD_METHODS[key]

    if method then
      return method
    end

    local state = DOWNLOAD_STATES[value]

    if state and DOWNLOAD_PROPERTIES[key] then
      return state[key]
    end
  end,
  __metatable = "mongodb.gridfs_download_stream",
  __newindex = function()
    error("MongoDB GridFS download streams are immutable", 2)
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

local function gridfs_error(kind, message, details)
  details = details or {}
  details.gridfs = kind

  return nil, errors.new({
    category = errors.CATEGORY.CLIENT,
    details = details,
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

local function integer_value(value)
  local numeric = numeric_value(value)

  if numeric == nil then
    return nil
  end

  return math.tointeger(numeric)
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

local function validate_filename(filename, action)
  action = action or "upload"

  if type(filename) ~= "string" then
    error("GridFS " .. action .. " filename must be a string", 3)
  elseif utf8.len(filename) == nil then
    error("GridFS " .. action .. " filename must be valid UTF-8", 3)
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

local function download_options(options)
  if options == nil then
    return {}
  elseif type(options) ~= "table" then
    error("GridFS download options must be a table", 3)
  end

  for key in pairs(options) do
    if key ~= "timeout_ms" then
      error("unknown GridFS download option: " .. tostring(key), 3)
    end
  end

  return options
end

local function download_by_name_options(options)
  if options == nil then
    options = {}
  elseif type(options) ~= "table" then
    error("GridFS download-by-name options must be a table", 3)
  end

  for key in pairs(options) do
    if key ~= "revision" and key ~= "timeout_ms" then
      error("unknown GridFS download-by-name option: " .. tostring(key), 3)
    end
  end

  local revision = options.revision

  if revision == nil then
    revision = -1
  elseif math.type(revision) ~= "integer"
      or revision < MIN_INT32 or revision > MAX_INT32
  then
    error("GridFS download revision must be a 32-bit integer", 3)
  end

  return options, revision
end

local function delete_options(options)
  if options == nil then
    return {}
  elseif type(options) ~= "table" then
    error("GridFS delete options must be a table", 3)
  end

  for key in pairs(options) do
    if key ~= "timeout_ms" then
      error("unknown GridFS delete option: " .. tostring(key), 3)
    end
  end

  return options
end

local function find_options(options)
  if options == nil then
    return {}
  elseif type(options) ~= "table" then
    error("GridFS find options must be a table", 3)
  end

  local allowed = {
    allow_disk_use = true,
    batch_size = true,
    limit = true,
    max_time_ms = true,
    no_cursor_timeout = true,
    skip = true,
    sort = true,
    timeout_ms = true,
  }

  for key in pairs(options) do
    if not allowed[key] then
      error("unknown GridFS find option: " .. tostring(key), 3)
    end
  end

  return options
end

local function rename_options(options)
  if options == nil then
    return {}
  elseif type(options) ~= "table" then
    error("GridFS rename options must be a table", 3)
  end

  for key in pairs(options) do
    if key ~= "timeout_ms" then
      error("unknown GridFS rename option: " .. tostring(key), 3)
    end
  end

  return options
end

local function file_metadata(document)
  local length = integer_value(document:get("length"))
  local chunk_size_bytes = integer_value(document:get("chunkSize"))

  if length == nil or length < 0 then
    return gridfs_error(
      "corrupt_file",
      "GridFS file has an invalid length",
      { field = "length" }
    )
  elseif chunk_size_bytes == nil or chunk_size_bytes <= 0
      or chunk_size_bytes > MAX_INT32
  then
    return gridfs_error(
      "corrupt_file",
      "GridFS file has an invalid chunkSize",
      { field = "chunkSize" }
    )
  end

  return {
    chunk_size_bytes = chunk_size_bytes,
    filename = document:get("filename"),
    id = document:get("_id"),
    length = length,
    metadata = document:get("metadata"),
    upload_date = document:get("uploadDate"),
  }
end

local function close_download_cursor(state)
  local cursor = state.cursor

  if cursor == nil then
    return true
  end

  state.cursor = nil
  local closed, err = cursor:close()

  if closed == nil then
    return nil, err
  end

  return true
end

local function corrupt_chunk(state, message, details)
  close_download_cursor(state)
  local _, err = gridfs_error("corrupt_file", message, details)

  state.failure = err
  return nil, err
end

local function open_chunk_cursor(state)
  local chunk_number = state.position // state.chunk_size_bytes
  local chunk_match = state.id
  local filter_entries = { { "files_id", chunk_match } }

  if chunk_number > 0 then
    filter_entries[#filter_entries + 1] = {
      "n",
      bson.document({ { "$gte", chunk_number } }),
    }
  end

  local cursor, err = state.bucket_state.chunks_collection:find(
    bson.document(filter_entries),
    { sort = bson.document({ { "n", 1 } }) }
  )

  if not cursor then
    state.failure = err
    return nil, err
  end

  state.cursor = cursor
  return true
end

local function expected_chunk_length(state, chunk_number)
  local chunk_start = chunk_number * state.chunk_size_bytes

  return math.min(state.chunk_size_bytes, state.length - chunk_start)
end

local function load_chunk(state)
  if state.cursor == nil then
    local opened, err = open_chunk_cursor(state)

    if not opened then
      return nil, err
    end
  end

  local chunk, err = state.cursor:next()
  local expected_number = state.position // state.chunk_size_bytes

  if not chunk then
    if err then
      state.failure = err
      return nil, err
    end

    return corrupt_chunk(state, "GridFS file is missing a required chunk", {
      chunk = expected_number,
    })
  end

  local number = integer_value(chunk:get("n"))

  if number ~= expected_number then
    return corrupt_chunk(state, "GridFS file has an out-of-order chunk", {
      actual_chunk = number,
      chunk = expected_number,
    })
  end

  local data = chunk:get("data")
  local expected_length = expected_chunk_length(state, expected_number)

  if not bson.is_binary(data) or #data.data ~= expected_length then
    return corrupt_chunk(state, "GridFS file has an invalid chunk length", {
      actual_length = bson.is_binary(data) and #data.data or nil,
      chunk = expected_number,
      expected_length = expected_length,
    })
  end

  state.chunk_data = data.data
  state.chunk_offset = state.position % state.chunk_size_bytes + 1
  return true
end

local function read_download(state, size)
  local remaining = math.min(size, math.max(0, state.length - state.position))
  local parts = {}

  while remaining > 0 do
    if state.chunk_data == nil then
      local loaded, err = load_chunk(state)

      if not loaded then
        return nil, err
      end
    end

    local available = #state.chunk_data - state.chunk_offset + 1
    local count = math.min(remaining, available)

    parts[#parts + 1] = state.chunk_data:sub(
      state.chunk_offset,
      state.chunk_offset + count - 1
    )
    state.chunk_offset = state.chunk_offset + count
    state.position = state.position + count
    remaining = remaining - count

    if state.chunk_offset > #state.chunk_data then
      state.chunk_data = nil
      state.chunk_offset = nil
    end
  end

  return table.concat(parts)
end

function DOWNLOAD_METHODS:read(size)
  local state = DOWNLOAD_STATES[self]

  if state.closed then
    return client_error("cannot read from a closed GridFS download stream")
  elseif state.failure then
    return nil, state.failure
  elseif size == nil or size == -1 then
    size = math.max(0, state.length - state.position)
  elseif math.type(size) ~= "integer" or size < 0 then
    error("GridFS download read size must be a non-negative integer", 2)
  end

  return operation_timeout.resume(state.timeout_context, false, function()
    return read_download(state, size)
  end)
end

function DOWNLOAD_METHODS:tell()
  return DOWNLOAD_STATES[self].position
end

local function seek_position(state, whence, offset)
  if whence == "set" then
    return offset
  elseif whence == "cur" then
    return state.position + offset
  elseif whence == "end" then
    return state.length + offset
  end

  error("GridFS download seek mode must be 'set', 'cur', or 'end'", 3)
end

function DOWNLOAD_METHODS:seek(whence, offset)
  local state = DOWNLOAD_STATES[self]

  if state.closed then
    return client_error("cannot seek a closed GridFS download stream")
  elseif state.failure then
    return nil, state.failure
  end

  whence = whence or "cur"
  offset = offset or 0

  if math.type(offset) ~= "integer" then
    error("GridFS download seek offset must be an integer", 2)
  end

  local position = seek_position(state, whence, offset)

  if position < 0 then
    error("GridFS download seek position must not be negative", 2)
  elseif position == state.position then
    return position
  end

  return operation_timeout.resume(state.timeout_context, false, function()
    local closed, err = close_download_cursor(state)

    if not closed then
      return nil, err
    end

    state.chunk_data = nil
    state.chunk_offset = nil
    state.position = position
    return position
  end)
end

function DOWNLOAD_METHODS:close()
  local state = DOWNLOAD_STATES[self]

  if state.closed then
    return true
  end

  return operation_timeout.resume(state.timeout_context, false, function()
    local closed, err = close_download_cursor(state)

    if not closed then
      return nil, err
    end

    state.closed = true
    state.chunk_data = nil
    return true
  end)
end

local function new_download(state, document, timeout_context)
  local metadata, err = file_metadata(document)

  if not metadata then
    return nil, err
  end

  local value = {}

  metadata.bucket_state = state
  metadata.chunk_data = nil
  metadata.chunk_offset = nil
  metadata.closed = false
  metadata.cursor = nil
  metadata.failure = nil
  metadata.position = 0
  metadata.timeout_context = timeout_context
  DOWNLOAD_STATES[value] = metadata
  return setmetatable(value, DOWNLOAD_METATABLE)
end

function BUCKET_METHODS:open_download_stream(identifier, options)
  if identifier == nil then
    error("GridFS download id must not be nil", 2)
  end

  local state = BUCKET_STATES[self]
  options = download_options(options)

  return operation_timeout.run(
    state.files_collection.runtime,
    state.timeout_ms,
    options,
    function()
      local document, err = state.files_collection:find_one(
        bson.document({ { "_id", identifier } })
      )

      if err then
        return nil, err
      elseif document == nil then
        return gridfs_error(
          "file_not_found",
          "GridFS file was not found",
          { id = identifier }
        )
      end

      return new_download(state, document, operation_timeout.capture())
    end
  )
end

local function revision_selection(revision)
  if revision < 0 then
    return -1, -revision - 1
  end

  return 1, revision
end

local function missing_filename_or_revision(state, filename, revision)
  local existing, err = state.files_collection:find_one(
    bson.document({ { "filename", filename } }),
    { projection = bson.document({ { "_id", 1 } }) }
  )

  if err then
    return nil, err
  elseif existing == nil then
    return gridfs_error(
      "file_not_found",
      "GridFS file was not found",
      { filename = filename }
    )
  end

  return gridfs_error(
    "revision_not_found",
    "GridFS file revision was not found",
    { filename = filename, revision = revision }
  )
end

function BUCKET_METHODS:open_download_stream_by_name(filename, options)
  validate_filename(filename, "download")

  local state = BUCKET_STATES[self]
  local revision

  options, revision = download_by_name_options(options)

  return operation_timeout.run(
    state.files_collection.runtime,
    state.timeout_ms,
    options,
    function()
      local direction, skip = revision_selection(revision)
      local document, err = state.files_collection:find_one(
        bson.document({ { "filename", filename } }),
        {
          skip = skip,
          sort = bson.document({ { "uploadDate", direction } }),
        }
      )

      if err then
        return nil, err
      elseif document == nil then
        return missing_filename_or_revision(state, filename, revision)
      end

      return new_download(state, document, operation_timeout.capture())
    end
  )
end

local function destination_failure(err)
  if errors.is(err) then
    return err
  end

  return errors.new({
    category = errors.CATEGORY.CLIENT,
    message = "GridFS download destination write failed: " .. tostring(err),
  })
end

local function write_destination(destination, data)
  local outcome = table.pack(pcall(destination.write, destination, data))

  if not outcome[1] then
    return nil, destination_failure(outcome[2])
  elseif not outcome[2] then
    return nil, destination_failure(outcome[3] or "write returned nil")
  end

  return true
end

local function copy_download(download, destination)
  local first_error

  while download:tell() < download.length do
    local size = math.min(
      DOWNLOAD_BUFFER_SIZE,
      download.length - download:tell()
    )
    local data, err = download:read(size)

    if data == nil then
      first_error = err
      break
    end

    local written
    written, err = write_destination(destination, data)

    if not written then
      first_error = err
      break
    end
  end

  local closed, close_error = download:close()

  if first_error then
    return nil, first_error
  elseif not closed then
    return nil, close_error
  end

  return true
end

function BUCKET_METHODS:download_to_stream(identifier, destination, options)
  local destination_type = type(destination)

  if (destination_type ~= "table" and destination_type ~= "userdata")
      or type(destination.write) ~= "function"
  then
    error("GridFS download destination must be a writable value", 2)
  end

  local state = BUCKET_STATES[self]
  options = download_options(options)

  return operation_timeout.run(
    state.files_collection.runtime,
    state.timeout_ms,
    options,
    function()
      local download, err = self:open_download_stream(identifier)

      if not download then
        return nil, err
      end

      return copy_download(download, destination)
    end
  )
end

function BUCKET_METHODS:download_to_stream_by_name(
    filename,
    destination,
    options
)
  validate_filename(filename, "download")

  local destination_type = type(destination)

  if (destination_type ~= "table" and destination_type ~= "userdata")
      or type(destination.write) ~= "function"
  then
    error("GridFS download destination must be a writable value", 2)
  end

  local state = BUCKET_STATES[self]
  local revision

  options, revision = download_by_name_options(options)

  return operation_timeout.run(
    state.files_collection.runtime,
    state.timeout_ms,
    options,
    function()
      local download, err = self:open_download_stream_by_name(
        filename,
        { revision = revision }
      )

      if not download then
        return nil, err
      end

      return copy_download(download, destination)
    end
  )
end

function BUCKET_METHODS:delete(identifier, options)
  if identifier == nil then
    error("GridFS delete id must not be nil", 2)
  end

  local state = BUCKET_STATES[self]

  options = delete_options(options)

  return operation_timeout.run(
    state.files_collection.runtime,
    state.timeout_ms,
    options,
    function()
      local files_result, err = state.files_collection:delete_one(
        bson.document({ { "_id", identifier } })
      )

      if not files_result then
        return nil, err
      end

      local chunks_result
      chunks_result, err = state.chunks_collection:delete_many(
        bson.document({ { "files_id", identifier } })
      )

      if not chunks_result then
        return nil, err
      elseif files_result.deleted_count == 0 then
        return gridfs_error(
          "file_not_found",
          "GridFS file was not found",
          { id = identifier }
        )
      end

      return true
    end
  )
end

local function file_ids_by_name(state, filename)
  local cursor, err = state.files_collection:find(
    bson.document({ { "filename", filename } }),
    { projection = bson.document({ { "_id", 1 } }) }
  )

  if not cursor then
    return nil, err
  end

  local identifiers = {}

  while true do
    local document
    document, err = cursor:next()

    if not document then
      break
    end

    identifiers[#identifiers + 1] = document:get("_id")
  end

  if not cursor:is_closed() then
    local closed, close_err = cursor:close()

    if closed == nil and err == nil then
      err = close_err
    end
  end

  if err then
    return nil, err
  end

  return identifiers
end

function BUCKET_METHODS:delete_by_name(filename, options)
  validate_filename(filename, "delete")

  local state = BUCKET_STATES[self]

  options = delete_options(options)

  return operation_timeout.run(
    state.files_collection.runtime,
    state.timeout_ms,
    options,
    function()
      local identifiers, err = file_ids_by_name(state, filename)

      if not identifiers then
        return nil, err
      end

      local matches = bson.array(identifiers)
      local files_result
      files_result, err = state.files_collection:delete_many(
        bson.document({
          { "_id", bson.document({ { "$in", matches } }) },
        })
      )

      if not files_result then
        return nil, err
      end

      local chunks_result
      chunks_result, err = state.chunks_collection:delete_many(
        bson.document({
          { "files_id", bson.document({ { "$in", matches } }) },
        })
      )

      if not chunks_result then
        return nil, err
      elseif files_result.deleted_count == 0 then
        return gridfs_error(
          "file_not_found",
          "GridFS file was not found",
          { filename = filename }
        )
      end

      return true
    end
  )
end

function BUCKET_METHODS:find(filter, options)
  return BUCKET_STATES[self].files_collection:find(
    filter,
    find_options(options)
  )
end

function BUCKET_METHODS:rename(identifier, new_filename, options)
  if identifier == nil then
    error("GridFS rename id must not be nil", 2)
  end

  validate_filename(new_filename, "rename")

  local result, err = BUCKET_STATES[self].files_collection:update_one(
    bson.document({ { "_id", identifier } }),
    bson.document({
      { "$set", bson.document({ { "filename", new_filename } }) },
    }),
    rename_options(options)
  )

  if not result then
    return nil, err
  elseif result.matched_count == 0 then
    return gridfs_error(
      "file_not_found",
      "GridFS file was not found",
      { id = identifier }
    )
  end

  return true
end

function BUCKET_METHODS:rename_by_name(filename, new_filename, options)
  validate_filename(filename, "rename")
  validate_filename(new_filename, "rename")

  local result, err = BUCKET_STATES[self].files_collection:update_many(
    bson.document({ { "filename", filename } }),
    bson.document({
      { "$set", bson.document({ { "filename", new_filename } }) },
    }),
    rename_options(options)
  )

  if not result then
    return nil, err
  elseif result.matched_count == 0 then
    return gridfs_error(
      "file_not_found",
      "GridFS file was not found",
      { filename = filename }
    )
  end

  return true
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
    aborted = false,
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

local function source_failure(err)
  if errors.is(err) then
    return err
  end

  return errors.new({
    category = errors.CATEGORY.CLIENT,
    message = "GridFS upload source read failed: " .. tostring(err),
  })
end

local function abort_after_source_failure(upload, err)
  upload:abort()
  return nil, source_failure(err)
end

local function consume_source(upload, source)
  if type(source) == "string" then
    return upload:write(source)
  end

  local source_type = type(source)

  if (source_type ~= "table" and source_type ~= "userdata")
      or type(source.read) ~= "function"
  then
    error("GridFS upload source must be a string or readable value", 3)
  end

  while true do
    local outcome = table.pack(pcall(
      source.read,
      source,
      upload.chunk_size_bytes
    ))

    if not outcome[1] then
      return abort_after_source_failure(upload, outcome[2])
    end

    local data = outcome[2]
    local err = outcome[3]

    if err ~= nil then
      return abort_after_source_failure(upload, err)
    elseif data == nil or data == "" then
      return true
    elseif type(data) ~= "string" then
      return abort_after_source_failure(
        upload,
        "readable source returned a non-string value"
      )
    end

    local written
    written, err = upload:write(data)

    if not written then
      return nil, err
    end
  end
end

local function upload_from_source(bucket, identifier, filename, source, options)
  local state = BUCKET_STATES[bucket]

  return operation_timeout.run(
    state.files_collection.runtime,
    state.timeout_ms,
    options,
    function(prepared)
      local upload, err

      if identifier == nil then
        upload, err = bucket:open_upload_stream(filename, prepared)
      else
        upload, err = bucket:open_upload_stream_with_id(
          identifier,
          filename,
          prepared
        )
      end

      if not upload then
        return nil, err
      end

      local consumed
      consumed, err = consume_source(upload, source)

      if not consumed then
        return nil, err
      end

      local closed
      closed, err = upload:close()

      if not closed then
        return nil, err
      end

      return identifier == nil and upload.id or true
    end
  )
end

function BUCKET_METHODS:upload_from_stream(filename, source, options)
  return upload_from_source(self, nil, filename, source, options)
end

function BUCKET_METHODS:upload_from_stream_with_id(
  identifier,
  filename,
  source,
  options
)
  if identifier == nil then
    error("GridFS upload id must not be nil", 2)
  end

  return upload_from_source(self, identifier, filename, source, options)
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

  if state.aborted then
    return client_error("cannot write to an aborted GridFS upload stream")
  elseif state.closed then
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

function UPLOAD_METHODS:abort()
  local state = UPLOAD_STATES[self]

  if state.aborted then
    if state.abort_failure then
      return nil, state.abort_failure
    end

    return client_error("GridFS upload stream is already aborted")
  elseif state.closed then
    return client_error("cannot abort a closed GridFS upload stream")
  end

  state.aborted = true
  state.buffer = ""
  state.closed = true
  local result, err = state.bucket_state.chunks_collection:delete_many(
    bson.document({ { "files_id", state.id } })
  )

  if not result then
    state.abort_failure = err
    return nil, err
  end

  result, err = state.bucket_state.files_collection:delete_one(
    bson.document({ { "_id", state.id } })
  )

  if not result then
    state.abort_failure = err
    return nil, err
  end

  return true
end

function UPLOAD_METHODS:close()
  local state = UPLOAD_STATES[self]

  if state.aborted then
    return client_error("cannot close an aborted GridFS upload stream")
  elseif state.closed then
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
