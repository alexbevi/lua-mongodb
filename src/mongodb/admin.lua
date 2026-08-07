local bson = require("mongodb.bson")
local cursor_model = require("mongodb.cursor")
local errors = require("mongodb.error")

local M = {}

local INDEX_STATES = setmetatable({}, { __mode = "k" })

local INDEX_METATABLE = {
  __index = function(value, key)
    local state = INDEX_STATES[value]

    if state then
      return state[key]
    end
  end,
  __metatable = "mongodb.index_model",
  __newindex = function()
    error("index models are immutable", 2)
  end,
}

local CREATE_COLLECTION_OPTIONS = {
  cancellation = true,
  capped = true,
  change_stream_pre_and_post_images = true,
  clustered_index = true,
  collation = true,
  comment = true,
  deadline = true,
  expire_after_seconds = true,
  index_option_defaults = true,
  max = true,
  pipeline = true,
  raw_data = true,
  size = true,
  timeseries = true,
  validation_action = true,
  validation_level = true,
  validator = true,
  view_on = true,
  session = true,
}

local LIST_DATABASE_OPTIONS = {
  authorized_databases = true,
  cancellation = true,
  comment = true,
  deadline = true,
  filter = true,
  name_only = true,
  session = true,
}

local LIST_COLLECTION_OPTIONS = {
  authorized_collections = true,
  batch_size = true,
  cancellation = true,
  comment = true,
  deadline = true,
  filter = true,
  name_only = true,
  raw_data = true,
  session = true,
}

local DROP_OPTIONS = {
  cancellation = true,
  comment = true,
  deadline = true,
  max_time_ms = true,
  raw_data = true,
  session = true,
}

local DROP_DATABASE_OPTIONS = {
  cancellation = true,
  comment = true,
  deadline = true,
  max_time_ms = true,
  session = true,
}

local CREATE_INDEX_OPTIONS = {
  cancellation = true,
  comment = true,
  commit_quorum = true,
  deadline = true,
  max_time_ms = true,
  raw_data = true,
  session = true,
}

local LIST_INDEX_OPTIONS = {
  batch_size = true,
  cancellation = true,
  comment = true,
  deadline = true,
  raw_data = true,
  session = true,
}

local INDEX_OPTION_NAMES = {
  background = "background",
  bits = "bits",
  bucket_size = "bucketSize",
  collation = "collation",
  default_language = "default_language",
  expire_after_seconds = "expireAfterSeconds",
  hidden = "hidden",
  language_override = "language_override",
  max = "max",
  min = "min",
  name = "name",
  partial_filter_expression = "partialFilterExpression",
  sparse = "sparse",
  storage_engine = "storageEngine",
  text_index_version = "textIndexVersion",
  two_dsphere_index_version = "2dsphereIndexVersion",
  unique = "unique",
  version = "v",
  weights = "weights",
  wildcard_projection = "wildcardProjection",
}

local INDEX_OPTION_ORDER = {
  "background",
  "expire_after_seconds",
  "sparse",
  "storage_engine",
  "unique",
  "version",
  "default_language",
  "language_override",
  "text_index_version",
  "weights",
  "two_dsphere_index_version",
  "bits",
  "min",
  "max",
  "bucket_size",
  "partial_filter_expression",
  "collation",
  "wildcard_projection",
  "hidden",
}

local DOCUMENT_INDEX_OPTIONS = {
  collation = true,
  partial_filter_expression = true,
  storage_engine = true,
  weights = true,
  wildcard_projection = true,
}

local BOOLEAN_INDEX_OPTIONS = {
  background = true,
  hidden = true,
  sparse = true,
  unique = true,
}

local INTEGER_INDEX_OPTIONS = {
  bits = true,
  bucket_size = true,
  expire_after_seconds = true,
  text_index_version = true,
  two_dsphere_index_version = true,
  version = true,
}

local INDEX_DIRECTIONS = {
  ["2d"] = true,
  ["2dsphere"] = true,
  ["geoHaystack"] = true,
  hashed = true,
  text = true,
}

local function readonly_list(values, kind)
  local data = {}

  for index, value in ipairs(values) do
    data[index] = value
  end

  return setmetatable({}, {
    __index = data,
    __len = function()
      return #data
    end,
    __metatable = "mongodb." .. kind,
    __newindex = function()
      error("administration results are immutable", 2)
    end,
    __pairs = function()
      return next, data, nil
    end,
  })
end

local function protocol_error(message)
  return nil, errors.new({
    category = errors.CATEGORY.PROTOCOL,
    message = message,
  })
end

local function number_value(value)
  if type(value) == "number" then
    return value
  end

  if bson.is_exact(value) then
    return value:to_number()
  end
end

local function validate_options(options, allowed, kind)
  options = options or {}

  if type(options) ~= "table" then
    error(kind .. " options must be a table", 3)
  end

  local copy = {}

  for key, value in pairs(options) do
    if not allowed[key] then
      error("unknown " .. kind .. " option: " .. tostring(key), 3)
    end

    copy[key] = value
  end

  return copy
end

local function require_boolean(options, name)
  if options[name] ~= nil and type(options[name]) ~= "boolean" then
    error(name .. " must be a boolean", 3)
  end
end

local function require_nonnegative_integer(options, name)
  local value = options[name]

  if value ~= nil and (math.type(value) ~= "integer" or value < 0) then
    error(name .. " must be a non-negative integer", 3)
  end
end

local function require_document(options, name)
  if options[name] ~= nil and not bson.is_document(options[name]) then
    error(name .. " must be a BSON document", 3)
  end
end

local function require_pipeline(options)
  local pipeline = options.pipeline

  if pipeline == nil then
    return
  end

  if not bson.is_array(pipeline) then
    error("pipeline must be a BSON array", 3)
  end

  for _, stage in pipeline:iter() do
    if not bson.is_document(stage) then
      error("pipeline must contain BSON documents", 3)
    end
  end
end

local function write_concern_document(concern)
  local entries = {}

  if concern.journal ~= nil then
    entries[#entries + 1] = { "j", concern.journal }
  end

  if concern.w ~= nil then
    entries[#entries + 1] = { "w", concern.w }
  end

  if concern.w_timeout_ms ~= nil then
    entries[#entries + 1] = { "wtimeoutMS", concern.w_timeout_ms }
  end

  if #entries > 0 then
    return bson.document(entries)
  end
end

local function write_error(response, item)
  if not bson.is_document(item) then
    return protocol_error("administration response contains a malformed write concern error")
  end

  local code = number_value(item:get("code"))

  if math.type(code) ~= "integer" then
    return protocol_error("administration response contains an invalid write error code")
  end

  local message = item:get("errmsg")

  if type(message) ~= "string" or message == "" then
    message = "administration write failed"
  end

  local labels = {}
  local raw_labels = response:get("errorLabels")
  local code_name = item:get("codeName")

  if type(code_name) ~= "string" or code_name == "" then
    code_name = nil
  end

  if bson.is_array(raw_labels) then
    for _, label in raw_labels:iter() do
      if type(label) == "string" and label ~= "" then
        labels[#labels + 1] = label
      end
    end
  end

  return nil, errors.new({
    category = errors.CATEGORY.WRITE,
    code = code,
    code_name = code_name,
    details = {
      err_info = item:get("errInfo"),
      response = response,
    },
    labels = labels,
    message = message,
  })
end

local function execute_write(state, database_name, entries, options)
  local acknowledged = state.write_concern.w ~= 0
  local concern = write_concern_document(state.write_concern)

  if concern then
    entries[#entries + 1] = { "writeConcern", concern }
  end

  local response, err = state.executor:command(
    database_name,
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      no_response = not acknowledged,
      session = options.session,
    }
  )

  if not response then
    return nil, err
  end

  if acknowledged and response:get("writeConcernError") ~= nil then
    return write_error(response, response:get("writeConcernError"))
  end

  return response
end

local function append_raw_data(entries, state, options)
  if options.raw_data ~= nil and state.max_wire_version >= 27 then
    entries[#entries + 1] = { "rawData", options.raw_data }
  end
end

local function cursor_from_response(state, response, options)
  local cursor = response:get("cursor")

  if not bson.is_document(cursor) then
    return protocol_error("administration response is missing its cursor document")
  end

  local namespace = cursor:get("ns")
  local prefix = options.database_name .. "."

  if type(namespace) ~= "string" or namespace:sub(1, #prefix) ~= prefix
      or #namespace == #prefix
  then
    return protocol_error("administration cursor contains an invalid namespace")
  end

  return cursor_model.new(response, {
    batch_size = options.batch_size or 0,
    cancellation = options.cancellation,
    client_state = state.client_state or state,
    collection_name = namespace:sub(#prefix + 1),
    comment = options.inherit_comment and options.comment or nil,
    database_name = options.database_name,
    deadline = options.deadline,
    executor = state.executor,
    on_close = state.on_cursor_close,
    session = options.session,
    session_context = options.session_context,
  })
end

local function collect_names(cursor)
  local names = {}

  while true do
    local document, err = cursor:next()

    if not document then
      if err then
        return nil, err
      end

      break
    end

    local name = document:get("name")

    if type(name) ~= "string" or name == "" then
      cursor:close()
      return protocol_error("administration response contains an invalid name")
    end

    names[#names + 1] = name
  end

  return readonly_list(names, "names")
end

local function validate_index_keys(keys)
  if not bson.is_document(keys) or #keys == 0 then
    error("index keys must be a non-empty BSON document", 3)
  end

  for key, direction in keys:iter() do
    if key == "" or utf8.len(key) == nil or key:find("%z") then
      error("index key names must be non-empty UTF-8 strings without null bytes", 3)
    end

    local numeric = number_value(direction)

    if numeric ~= 1 and numeric ~= -1
        and (type(direction) ~= "string" or not INDEX_DIRECTIONS[direction])
    then
      error("index direction must be 1, -1, or a supported index type", 3)
    end
  end
end

local function generated_index_name(keys)
  if #keys == 1 and keys:get_at(1) == "_id" then
    return "_id_"
  end

  local parts = {}

  for key, direction in keys:iter() do
    parts[#parts + 1] = key
    parts[#parts + 1] = tostring(number_value(direction) or direction)
  end

  return table.concat(parts, "_")
end

local function validate_index_options(options)
  options = validate_options(options, INDEX_OPTION_NAMES, "index model")

  for name in pairs(BOOLEAN_INDEX_OPTIONS) do
    require_boolean(options, name)
  end

  for name in pairs(INTEGER_INDEX_OPTIONS) do
    require_nonnegative_integer(options, name)
  end

  for name in pairs(DOCUMENT_INDEX_OPTIONS) do
    require_document(options, name)
  end

  if options.name ~= nil
      and (type(options.name) ~= "string" or options.name == ""
        or utf8.len(options.name) == nil or options.name:find("%z"))
  then
    error("index name must be a non-empty UTF-8 string without null bytes", 3)
  end

  for _, name in ipairs({ "default_language", "language_override" }) do
    if options[name] ~= nil and type(options[name]) ~= "string" then
      error(name .. " must be a string", 3)
    end
  end

  for _, name in ipairs({ "min", "max" }) do
    if options[name] ~= nil and type(options[name]) ~= "number" then
      error(name .. " must be a number", 3)
    end
  end

  return options
end

function M.index_model(keys, options)
  validate_index_keys(keys)
  options = validate_index_options(options)
  local name = options.name or generated_index_name(keys)
  local entries = {
    { "key", keys },
    { "name", name },
  }

  for _, option in ipairs(INDEX_OPTION_ORDER) do
    if options[option] ~= nil then
      entries[#entries + 1] = { INDEX_OPTION_NAMES[option], options[option] }
    end
  end

  local value = {}

  INDEX_STATES[value] = {
    document = bson.document(entries),
    keys = keys,
    name = name,
  }
  return setmetatable(value, INDEX_METATABLE)
end

local function require_index_model(value)
  local state = INDEX_STATES[value]

  if not state then
    error("indexes must contain mongodb.index_model values", 3)
  end

  return state
end

function M.create_collection(state, name, options)
  options = validate_options(options, CREATE_COLLECTION_OPTIONS, "create_collection")
  require_boolean(options, "capped")
  require_nonnegative_integer(options, "size")
  require_nonnegative_integer(options, "max")
  require_nonnegative_integer(options, "expire_after_seconds")
  require_document(options, "validator")
  require_document(options, "index_option_defaults")
  require_document(options, "collation")
  require_document(options, "timeseries")
  require_document(options, "clustered_index")
  require_document(options, "change_stream_pre_and_post_images")
  require_boolean(options, "raw_data")
  require_pipeline(options)

  if options.view_on ~= nil and (type(options.view_on) ~= "string" or options.view_on == "") then
    error("view_on must be a non-empty string", 3)
  end

  if options.validation_level ~= nil
      and options.validation_level ~= "off"
      and options.validation_level ~= "strict"
      and options.validation_level ~= "moderate"
  then
    error("validation_level must be 'off', 'strict', or 'moderate'", 3)
  end

  if options.validation_action ~= nil
      and options.validation_action ~= "error"
      and options.validation_action ~= "warn"
  then
    error("validation_action must be 'error' or 'warn'", 3)
  end

  local entries = { { "create", name } }

  for _, field in ipairs({
    { "capped", "capped" },
    { "size", "size" },
    { "max", "max" },
    { "validator", "validator" },
    { "validation_level", "validationLevel" },
    { "validation_action", "validationAction" },
    { "index_option_defaults", "indexOptionDefaults" },
    { "collation", "collation" },
    { "view_on", "viewOn" },
    { "pipeline", "pipeline" },
    { "timeseries", "timeseries" },
    { "expire_after_seconds", "expireAfterSeconds" },
    { "clustered_index", "clusteredIndex" },
    { "change_stream_pre_and_post_images", "changeStreamPreAndPostImages" },
    { "comment", "comment" },
  }) do
    if options[field[1]] ~= nil then
      entries[#entries + 1] = { field[2], options[field[1]] }
    end
  end

  append_raw_data(entries, state, options)
  return execute_write(state, state.name, entries, options)
end

function M.drop_collection(state, name, options)
  options = validate_options(options, DROP_OPTIONS, "drop_collection")
  require_nonnegative_integer(options, "max_time_ms")
  require_boolean(options, "raw_data")
  local entries = { { "drop", name } }

  if options.comment ~= nil then
    entries[#entries + 1] = { "comment", options.comment }
  end

  if options.max_time_ms ~= nil then
    entries[#entries + 1] = { "maxTimeMS", options.max_time_ms }
  end

  append_raw_data(entries, state, options)
  local response, err = execute_write(state, state.name, entries, options)

  if not response and err and err.code == 26 then
    return true
  end

  if not response then
    return nil, err
  end

  return true
end

function M.list_collections(state, options)
  options = validate_options(options, LIST_COLLECTION_OPTIONS, "list_collections")
  require_document(options, "filter")
  require_boolean(options, "name_only")
  require_boolean(options, "authorized_collections")
  require_nonnegative_integer(options, "batch_size")
  require_boolean(options, "raw_data")
  options.session_context = options.session == nil
    and type(state.executor.release_session_context) == "function" and {} or nil
  local cursor_entries = {}

  if options.batch_size ~= nil then
    cursor_entries[#cursor_entries + 1] = { "batchSize", options.batch_size }
  end

  local entries = {
    { "listCollections", 1 },
    { "cursor", bson.document(cursor_entries) },
  }

  for _, field in ipairs({
    { "filter", "filter" },
    { "name_only", "nameOnly" },
    { "authorized_collections", "authorizedCollections" },
    { "comment", "comment" },
  }) do
    if options[field[1]] ~= nil then
      entries[#entries + 1] = { field[2], options[field[1]] }
    end
  end

  append_raw_data(entries, state, options)

  local response, err = state.executor:command(
    state.name,
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      session = options.session,
      session_context = options.session_context,
    }
  )

  if not response then
    if options.session_context then
      state.executor:release_session_context(options.session_context)
    end

    return nil, err
  end

  return cursor_from_response(state, response, {
    batch_size = options.batch_size,
    cancellation = options.cancellation,
    database_name = state.name,
    deadline = options.deadline,
    session = options.session,
    session_context = options.session_context,
  })
end

function M.list_collection_names(state, options)
  options = validate_options(options, LIST_COLLECTION_OPTIONS, "list_collection_names")
  require_document(options, "filter")

  if options.filter == nil
      or #options.filter == 0
      or (#options.filter == 1 and options.filter:get_at(1) == "name")
  then
    options.name_only = true
  else
    options.name_only = nil
  end

  local cursor, err = M.list_collections(state, options)

  if not cursor then
    return nil, err
  end

  return collect_names(cursor)
end

function M.list_databases(state, options)
  options = validate_options(options, LIST_DATABASE_OPTIONS, "list_databases")
  require_document(options, "filter")
  require_boolean(options, "name_only")
  require_boolean(options, "authorized_databases")
  local entries = { { "listDatabases", 1 } }

  for _, field in ipairs({
    { "filter", "filter" },
    { "name_only", "nameOnly" },
    { "authorized_databases", "authorizedDatabases" },
    { "comment", "comment" },
  }) do
    if options[field[1]] ~= nil then
      entries[#entries + 1] = { field[2], options[field[1]] }
    end
  end

  local response, err = state.executor:command(
    "admin",
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      session = options.session,
    }
  )

  if not response then
    return nil, err
  end

  local databases = response:get("databases")

  if not bson.is_array(databases) then
    return protocol_error("listDatabases response is missing its databases array")
  end

  local synthetic = bson.document({
    { "ok", 1 },
    { "cursor", bson.document({
      { "id", bson.int64(0) },
      { "ns", "admin.$cmd" },
      { "firstBatch", databases },
    }) },
  })

  return cursor_from_response(state, synthetic, {
    database_name = "admin",
  })
end

function M.list_database_names(state, options)
  options = validate_options(options, LIST_DATABASE_OPTIONS, "list_database_names")
  options.name_only = true
  local cursor, err = M.list_databases(state, options)

  if not cursor then
    return nil, err
  end

  return collect_names(cursor)
end

function M.drop_database(state, name, options)
  options = validate_options(options, DROP_DATABASE_OPTIONS, "drop_database")
  require_nonnegative_integer(options, "max_time_ms")
  local entries = { { "dropDatabase", 1 } }

  if options.comment ~= nil then
    entries[#entries + 1] = { "comment", options.comment }
  end

  if options.max_time_ms ~= nil then
    entries[#entries + 1] = { "maxTimeMS", options.max_time_ms }
  end

  local response, err = execute_write(state, name, entries, options)

  if not response then
    return nil, err
  end

  return true
end

local function models_array(models)
  if type(models) ~= "table" or #models == 0 then
    error("indexes must be a non-empty array", 3)
  end

  for key in pairs(models) do
    if math.type(key) ~= "integer" or key < 1 or key > #models then
      error("indexes must be a dense array", 3)
    end
  end

  local documents = {}
  local names = {}

  for index, model in ipairs(models) do
    local state = require_index_model(model)

    documents[index] = state.document
    names[index] = state.name
  end

  return bson.array(documents), names
end

function M.create_indexes(state, models, options)
  options = validate_options(options, CREATE_INDEX_OPTIONS, "create_indexes")
  require_nonnegative_integer(options, "max_time_ms")
  require_boolean(options, "raw_data")

  if options.commit_quorum ~= nil
      and ((type(options.commit_quorum) ~= "string"
          and (math.type(options.commit_quorum) ~= "integer"
            or options.commit_quorum < 0))
        or options.commit_quorum == "")
  then
    error("commit_quorum must be a non-negative integer or string", 3)
  end

  if options.commit_quorum ~= nil and state.max_wire_version < 9 then
    error("commit_quorum requires MongoDB 4.4 or newer", 3)
  end

  local documents, names = models_array(models)
  local entries = {
    { "createIndexes", state.name },
    { "indexes", documents },
  }

  for _, field in ipairs({
    { "commit_quorum", "commitQuorum" },
    { "max_time_ms", "maxTimeMS" },
    { "comment", "comment" },
  }) do
    if options[field[1]] ~= nil then
      entries[#entries + 1] = { field[2], options[field[1]] }
    end
  end

  append_raw_data(entries, state, options)
  local response, err = execute_write(state, state.database_name, entries, options)

  if not response then
    return nil, err
  end

  return readonly_list(names, "index_names")
end

function M.create_index(state, keys, options)
  options = options or {}

  if type(options) ~= "table" then
    error("create_index options must be a table", 3)
  end

  local command_options = {}
  local index_options = {}

  for key, value in pairs(options) do
    if CREATE_INDEX_OPTIONS[key] then
      command_options[key] = value
    else
      index_options[key] = value
    end
  end

  if INDEX_STATES[keys] and next(index_options) ~= nil then
    error("index model options cannot be supplied with an existing index model", 3)
  end

  local model = INDEX_STATES[keys] and keys or M.index_model(keys, index_options)
  local names, err = M.create_indexes(state, { model }, command_options)

  if not names then
    return nil, err
  end

  return names[1]
end

local function drop_index(state, name, options, all)
  options = validate_options(options, DROP_OPTIONS, all and "drop_indexes" or "drop_index")
  require_nonnegative_integer(options, "max_time_ms")
  require_boolean(options, "raw_data")

  if type(name) ~= "string" or name == "" then
    error("index name must be a non-empty string", 3)
  end

  if not all and name == "*" then
    error("drop_index cannot drop all indexes; use drop_indexes", 3)
  end

  local entries = {
    { "dropIndexes", state.name },
    { "index", name },
  }

  for _, field in ipairs({
    { "max_time_ms", "maxTimeMS" },
    { "comment", "comment" },
  }) do
    if options[field[1]] ~= nil then
      entries[#entries + 1] = { field[2], options[field[1]] }
    end
  end

  append_raw_data(entries, state, options)
  local response, err = execute_write(state, state.database_name, entries, options)

  if not response and err and err.code == 26 then
    return true
  end

  if not response then
    return nil, err
  end

  return true
end

function M.drop_index(state, name, options)
  if INDEX_STATES[name] then
    name = INDEX_STATES[name].name
  end

  return drop_index(state, name, options, false)
end

function M.drop_indexes(state, options)
  return drop_index(state, "*", options, true)
end

function M.list_indexes(state, options)
  options = validate_options(options, LIST_INDEX_OPTIONS, "list_indexes")
  require_nonnegative_integer(options, "batch_size")
  require_boolean(options, "raw_data")
  options.session_context = options.session == nil
    and type(state.executor.release_session_context) == "function" and {} or nil
  local cursor_entries = {}

  if options.batch_size ~= nil then
    cursor_entries[#cursor_entries + 1] = { "batchSize", options.batch_size }
  end

  local entries = {
    { "listIndexes", state.name },
    { "cursor", bson.document(cursor_entries) },
  }

  if options.comment ~= nil then
    entries[#entries + 1] = { "comment", options.comment }
  end

  append_raw_data(entries, state, options)
  local response, err = state.executor:command(
    state.database_name,
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      session = options.session,
      session_context = options.session_context,
    }
  )

  if not response then
    if not err or err.code ~= 26 then
      if options.session_context then
        state.executor:release_session_context(options.session_context)
      end

      return nil, err
    end

    response = bson.document({
      { "ok", 1 },
      { "cursor", bson.document({
        { "id", bson.int64(0) },
        { "ns", state.full_name },
        { "firstBatch", bson.array({}) },
      }) },
    })
  end

  return cursor_from_response(state, response, {
    batch_size = options.batch_size,
    cancellation = options.cancellation,
    comment = options.comment,
    database_name = state.database_name,
    deadline = options.deadline,
    inherit_comment = true,
    session = options.session,
    session_context = options.session_context,
  })
end

return M
