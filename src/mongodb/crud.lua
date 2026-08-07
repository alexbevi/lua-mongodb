local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local cursor_model = require("mongodb.cursor")

local M = {}

local RESULT_STATES = setmetatable({}, { __mode = "k" })
local RESULT_METATABLE = {
  __index = function(value, key)
    local state = RESULT_STATES[value]

    if state then
      return state[key]
    end
  end,
  __metatable = "mongodb.crud.result",
  __newindex = function()
    error("CRUD results are immutable", 2)
  end,
}

local FIND_OPTION_FIELDS = {
  allow_disk_use = { "allowDiskUse", "boolean" },
  allow_partial_results = { "allowPartialResults", "boolean" },
  collation = { "collation", "document" },
  comment = { "comment", "any" },
  hint = { "hint", "hint" },
  let = { "let", "document" },
  max = { "max", "document" },
  max_time_ms = { "maxTimeMS", "nonnegative_integer" },
  min = { "min", "document" },
  projection = { "projection", "document" },
  raw_data = { "rawData", "boolean", 27 },
  return_key = { "returnKey", "boolean" },
  show_record_id = { "showRecordId", "boolean" },
  skip = { "skip", "nonnegative_integer" },
  sort = { "sort", "document" },
}
local FIND_OPTIONS = {
  batch_size = true,
  cancellation = true,
  deadline = true,
  limit = true,
  no_cursor_timeout = true,
  session = true,
}
local INSERT_OPTIONS = {
  bypass_document_validation = true,
  cancellation = true,
  comment = true,
  deadline = true,
  raw_data = true,
  session = true,
}
local UPDATE_OPTIONS = {
  array_filters = true,
  bypass_document_validation = true,
  cancellation = true,
  collation = true,
  comment = true,
  deadline = true,
  hint = true,
  let = true,
  raw_data = true,
  sort = true,
  upsert = true,
  session = true,
}
local REPLACE_OPTIONS = {
  bypass_document_validation = true,
  cancellation = true,
  collation = true,
  comment = true,
  deadline = true,
  hint = true,
  let = true,
  raw_data = true,
  sort = true,
  upsert = true,
  session = true,
}
local DELETE_OPTIONS = {
  cancellation = true,
  collation = true,
  comment = true,
  deadline = true,
  hint = true,
  let = true,
  raw_data = true,
  session = true,
}
local AGGREGATE_OPTIONS = {
  allow_disk_use = true,
  batch_size = true,
  bypass_document_validation = true,
  cancellation = true,
  collation = true,
  comment = true,
  deadline = true,
  hint = true,
  let = true,
  max_await_time_ms = true,
  max_time_ms = true,
  raw_data = true,
  session = true,
}
local COUNT_OPTIONS = {
  cancellation = true,
  collation = true,
  comment = true,
  deadline = true,
  hint = true,
  limit = true,
  max_time_ms = true,
  raw_data = true,
  skip = true,
  session = true,
}
local ESTIMATED_COUNT_OPTIONS = {
  cancellation = true,
  comment = true,
  deadline = true,
  max_time_ms = true,
  raw_data = true,
  session = true,
}
local DISTINCT_OPTIONS = {
  cancellation = true,
  collation = true,
  comment = true,
  deadline = true,
  hint = true,
  max_time_ms = true,
  raw_data = true,
  session = true,
}
local FIND_AND_DELETE_OPTIONS = {
  cancellation = true,
  collation = true,
  comment = true,
  deadline = true,
  hint = true,
  let = true,
  max_time_ms = true,
  projection = true,
  raw_data = true,
  sort = true,
  session = true,
}
local FIND_AND_REPLACE_OPTIONS = {
  bypass_document_validation = true,
  cancellation = true,
  collation = true,
  comment = true,
  deadline = true,
  hint = true,
  let = true,
  max_time_ms = true,
  projection = true,
  raw_data = true,
  return_document = true,
  sort = true,
  upsert = true,
  session = true,
}
local FIND_AND_UPDATE_OPTIONS = {
  array_filters = true,
  bypass_document_validation = true,
  cancellation = true,
  collation = true,
  comment = true,
  deadline = true,
  hint = true,
  let = true,
  max_time_ms = true,
  projection = true,
  raw_data = true,
  return_document = true,
  sort = true,
  upsert = true,
  session = true,
}

for name in pairs(FIND_OPTION_FIELDS) do
  FIND_OPTIONS[name] = true
end

local function protocol_error(message, details)
  return nil, errors.new({
    category = errors.CATEGORY.PROTOCOL,
    details = details,
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

local function labels_from(response)
  local labels = {}
  local value = response:get("errorLabels")

  if bson.is_array(value) then
    for _, label in value:iter() do
      if type(label) == "string" and label ~= "" then
        labels[#labels + 1] = label
      end
    end
  end

  return labels
end

local function write_error(response, value, kind)
  if not bson.is_document(value) then
    return protocol_error("write response contains a malformed " .. kind)
  end

  local code = number_value(value:get("code"))

  if math.type(code) ~= "integer" then
    return protocol_error("write response contains an invalid error code")
  end

  local message = value:get("errmsg")

  if type(message) ~= "string" or message == "" then
    message = kind == "write concern error" and "write concern failed" or "write failed"
  end

  local code_name = value:get("codeName")

  if type(code_name) ~= "string" or code_name == "" then
    code_name = nil
  end

  return nil, errors.new({
    category = errors.CATEGORY.WRITE,
    code = code,
    code_name = code_name,
    details = {
      index = number_value(value:get("index")),
      response = response,
      write_error = value:get("errInfo"),
    },
    labels = labels_from(response),
    message = message,
  })
end

local function check_write_response(response)
  local write_errors = response:get("writeErrors")

  if write_errors ~= nil then
    if not bson.is_array(write_errors) then
      return protocol_error("write response contains malformed writeErrors")
    end

    if #write_errors > 0 then
      return write_error(response, write_errors:get(1), "write error")
    end
  end

  local concern_error = response:get("writeConcernError")

  if concern_error ~= nil then
    return write_error(response, concern_error, "write concern error")
  end

  return true
end

local function result(fields)
  local value = {}

  RESULT_STATES[value] = fields
  return setmetatable(value, RESULT_METATABLE)
end

local function concern_document(concern, write)
  local entries = {}

  if write then
    if concern.journal ~= nil then
      entries[#entries + 1] = { "j", concern.journal }
    end

    if concern.w ~= nil then
      entries[#entries + 1] = { "w", concern.w }
    end

    if concern.w_timeout_ms ~= nil then
      entries[#entries + 1] = { "wtimeoutMS", concern.w_timeout_ms }
    end
  elseif concern.level ~= nil then
    entries[#entries + 1] = { "level", concern.level }
  end

  if #entries > 0 then
    return bson.document(entries)
  end
end

local function validate_options(options, allowed, kind)
  options = options or {}

  if type(options) ~= "table" then
    error(kind .. " options must be a table", 3)
  end

  for key in pairs(options) do
    if not allowed[key] then
      error("unknown " .. kind .. " option: " .. tostring(key), 3)
    end
  end

  return options
end

local function require_option_type(name, value, expected)
  if expected == "boolean" and type(value) ~= "boolean" then
    error(name .. " must be a boolean", 4)
  elseif expected == "document" and not bson.is_document(value) then
    error(name .. " must be a BSON document", 4)
  elseif expected == "hint" and type(value) ~= "string" and not bson.is_document(value) then
    error(name .. " must be an index name or BSON document", 4)
  elseif expected == "nonnegative_integer"
      and (math.type(value) ~= "integer" or value < 0)
  then
    error(name .. " must be a non-negative integer", 4)
  end
end

local function with_generated_id(state, document)
  local identifier = document:get("_id")

  if identifier ~= nil then
    return document, identifier
  end

  if type(state.object_ids) ~= "table" or type(state.object_ids.new) ~= "function" then
    error("collection is missing its ObjectId generator", 3)
  end

  local err
  identifier, err = state.object_ids:new()

  if identifier == nil then
    return nil, nil, err
  end

  local entries = { { "_id", identifier } }

  for key, value in document:iter() do
    entries[#entries + 1] = { key, value }
  end

  return bson.document(entries), identifier
end

local function append_find_options(entries, state, options)
  for name, field in pairs(FIND_OPTION_FIELDS) do
    local value = options[name]

    if value ~= nil then
      require_option_type(name, value, field[2])

      if field[3] == nil or state.max_wire_version >= field[3] then
        entries[#entries + 1] = { field[1], value }
      end
    end
  end
end

local function require_document(name, value)
  if not bson.is_document(value) then
    error(name .. " must be a BSON document", 3)
  end
end

local function require_boolean_option(options, name)
  if options[name] ~= nil and type(options[name]) ~= "boolean" then
    error(name .. " must be a boolean", 3)
  end
end

local function require_document_option(options, name)
  if options[name] ~= nil and not bson.is_document(options[name]) then
    error(name .. " must be a BSON document", 3)
  end
end

local function require_hint(options)
  local hint = options.hint

  if hint ~= nil and type(hint) ~= "string" and not bson.is_document(hint) then
    error("hint must be an index name or BSON document", 3)
  end
end

local function require_array_filters(options)
  local array_filters = options.array_filters

  if array_filters == nil then
    return
  end

  if not bson.is_array(array_filters) then
    error("array_filters must be a BSON array", 3)
  end

  for _, filter in array_filters:iter() do
    if not bson.is_document(filter) then
      error("array_filters must contain BSON documents", 3)
    end
  end
end

local function require_update(update)
  if bson.is_document(update) then
    local first = update:get_at(1)

    if not first then
      error("update document cannot be empty", 3)
    end

    if first:sub(1, 1) ~= "$" then
      error("update document must begin with an atomic '$' modifier", 3)
    end

    return
  end

  if not bson.is_array(update) or #update == 0 then
    error("update must be a non-empty BSON document or pipeline array", 3)
  end

  for _, stage in update:iter() do
    if not bson.is_document(stage) then
      error("update pipeline must contain BSON documents", 3)
    end
  end
end

local function require_replacement(replacement)
  require_document("replacement", replacement)
  local first = replacement:get_at(1)

  if first and first:sub(1, 1) == "$" then
    error("replacement document must not begin with an atomic '$' modifier", 3)
  end
end

local function append_common_write_fields(entries, state, options, bypass)
  if options.let ~= nil then
    entries[#entries + 1] = { "let", options.let }
  end

  if options.comment ~= nil then
    entries[#entries + 1] = { "comment", options.comment }
  end

  if bypass and options.bypass_document_validation ~= nil then
    entries[#entries + 1] = {
      "bypassDocumentValidation",
      options.bypass_document_validation,
    }
  end

  if options.raw_data ~= nil and state.max_wire_version >= 27 then
    entries[#entries + 1] = { "rawData", options.raw_data }
  end

  local write_concern = concern_document(state.write_concern, true)

  if write_concern then
    entries[#entries + 1] = { "writeConcern", write_concern }
  end
end

local function execute_write(state, entries, options, retryable)
  local acknowledged = state.write_concern.w ~= 0
  local response, err = state.executor:command(
    state.database_name,
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      no_response = not acknowledged,
      retryable_write = acknowledged and retryable == true,
      session = options.session,
    }
  )

  if not response then
    return nil, nil, err
  end

  if acknowledged then
    local valid
    valid, err = check_write_response(response)

    if not valid then
      return nil, nil, err
    end
  end

  return response, acknowledged
end

local function count_field(response, name)
  local value = number_value(response:get(name))

  if math.type(value) ~= "integer" or value < 0 then
    return protocol_error("write response contains an invalid " .. name)
  end

  return value
end

local function update_result(response, acknowledged)
  if not acknowledged then
    return result({ acknowledged = false })
  end

  local matched, err = count_field(response, "n")

  if matched == nil then
    return nil, err
  end

  local modified
  modified, err = count_field(response, "nModified")

  if modified == nil then
    return nil, err
  end

  local upserted = response:get("upserted")
  local upserted_count = 0
  local upserted_id

  if upserted ~= nil then
    if not bson.is_array(upserted) or #upserted > 1 then
      return protocol_error("write response contains malformed upserted results")
    end

    if #upserted == 1 then
      local item = upserted:get(1)

      if not bson.is_document(item) or item:get("_id") == nil then
        return protocol_error("write response contains a malformed upserted identifier")
      end

      upserted_count = 1
      upserted_id = item:get("_id")
      matched = 0
    end
  end

  return result({
    acknowledged = true,
    matched_count = matched,
    modified_count = modified,
    upserted_count = upserted_count,
    upserted_id = upserted_id,
  })
end

local function update_operation(state, filter, update, options, multi, replacement)
  require_document("filter", filter)

  if replacement then
    require_replacement(update)
    options = validate_options(options, REPLACE_OPTIONS, "replace_one")
  else
    require_update(update)
    options = validate_options(options, UPDATE_OPTIONS, multi and "update_many" or "update_one")
  end

  require_boolean_option(options, "upsert")
  require_boolean_option(options, "bypass_document_validation")
  require_boolean_option(options, "raw_data")
  require_document_option(options, "collation")
  require_document_option(options, "let")
  require_document_option(options, "sort")
  require_hint(options)
  require_array_filters(options)

  if multi and options.sort ~= nil then
    error("sort is not supported by update_many", 3)
  end

  local acknowledged = state.write_concern.w ~= 0

  if not acknowledged and options.collation ~= nil then
    error("collation is unsupported for unacknowledged writes", 3)
  end

  if not acknowledged and options.array_filters ~= nil then
    error("array_filters is unsupported for unacknowledged writes", 3)
  end

  if not acknowledged and options.hint ~= nil and state.max_wire_version < 8 then
    error("unacknowledged update hint requires MongoDB 4.2 or newer", 3)
  end

  if not acknowledged and options.sort ~= nil and state.max_wire_version < 25 then
    error("unacknowledged update sort requires MongoDB 8.0 or newer", 3)
  end

  local model_entries = {
    { "q", filter },
    { "u", update },
    { "multi", multi },
  }

  if options.upsert ~= nil then
    model_entries[#model_entries + 1] = { "upsert", options.upsert }
  end

  for _, field in ipairs({
    { "array_filters", "arrayFilters" },
    { "collation", "collation" },
    { "hint", "hint" },
    { "sort", "sort" },
  }) do
    if options[field[1]] ~= nil then
      model_entries[#model_entries + 1] = { field[2], options[field[1]] }
    end
  end

  local entries = {
    { "update", state.name },
    { "ordered", true },
    { "updates", bson.array({ bson.document(model_entries) }) },
  }

  append_common_write_fields(entries, state, options, true)
  local response, was_acknowledged, err = execute_write(
    state,
    entries,
    options,
    not multi
  )

  if not response then
    return nil, err
  end

  return update_result(response, was_acknowledged)
end

local function delete_operation(state, filter, options, multi)
  require_document("filter", filter)
  options = validate_options(options, DELETE_OPTIONS, multi and "delete_many" or "delete_one")
  require_boolean_option(options, "raw_data")
  require_document_option(options, "collation")
  require_document_option(options, "let")
  require_hint(options)
  local acknowledged = state.write_concern.w ~= 0

  if not acknowledged and options.collation ~= nil then
    error("collation is unsupported for unacknowledged writes", 3)
  end

  if not acknowledged and options.hint ~= nil and state.max_wire_version < 9 then
    error("unacknowledged delete hint requires MongoDB 4.4 or newer", 3)
  end

  local delete_entries = {
    { "q", filter },
    { "limit", multi and 0 or 1 },
  }

  for _, name in ipairs({ "collation", "hint" }) do
    if options[name] ~= nil then
      delete_entries[#delete_entries + 1] = { name, options[name] }
    end
  end

  local entries = {
    { "delete", state.name },
    { "ordered", true },
    { "deletes", bson.array({ bson.document(delete_entries) }) },
  }

  append_common_write_fields(entries, state, options, false)
  local response, was_acknowledged, err = execute_write(
    state,
    entries,
    options,
    not multi
  )

  if not response then
    return nil, err
  end

  if not was_acknowledged then
    return result({ acknowledged = false })
  end

  local deleted
  deleted, err = count_field(response, "n")

  if deleted == nil then
    return nil, err
  end

  return result({ acknowledged = true, deleted_count = deleted })
end

local function require_nonnegative_integer(options, name)
  local value = options[name]

  if value ~= nil and (math.type(value) ~= "integer" or value < 0) then
    error(name .. " must be a non-negative integer", 3)
  end
end

local function require_pipeline(pipeline)
  if not bson.is_array(pipeline) then
    error("pipeline must be a BSON array", 3)
  end

  for _, stage in pipeline:iter() do
    if not bson.is_document(stage) then
      error("pipeline must contain BSON documents", 3)
    end
  end
end

local function pipeline_writes(pipeline)
  if #pipeline == 0 then
    return false
  end

  local last = pipeline:get(#pipeline)
  local name = last:get_at(1)

  return name == "$out" or name == "$merge"
end

local function append_read_concern(entries, state)
  local read_concern = concern_document(state.read_concern, false)

  if read_concern then
    entries[#entries + 1] = { "readConcern", read_concern }
  end
end

local function append_raw_data(entries, state, options)
  if options.raw_data ~= nil and state.max_wire_version >= 27 then
    entries[#entries + 1] = { "rawData", options.raw_data }
  end
end

local function aggregate_entries(state, pipeline, options, writes)
  local cursor_entries = {}

  if options.batch_size ~= nil and not writes then
    cursor_entries[#cursor_entries + 1] = { "batchSize", options.batch_size }
  end

  local entries = {
    { "aggregate", state.name },
    { "pipeline", pipeline },
    { "cursor", bson.document(cursor_entries) },
  }

  for _, field in ipairs({
    { "allow_disk_use", "allowDiskUse" },
    { "collation", "collation" },
    { "comment", "comment" },
    { "hint", "hint" },
    { "let", "let" },
    { "max_time_ms", "maxTimeMS" },
  }) do
    if options[field[1]] ~= nil then
      entries[#entries + 1] = { field[2], options[field[1]] }
    end
  end

  if writes and options.bypass_document_validation ~= nil then
    entries[#entries + 1] = {
      "bypassDocumentValidation",
      options.bypass_document_validation,
    }
  end

  append_raw_data(entries, state, options)

  if not writes or state.max_wire_version >= 8 then
    append_read_concern(entries, state)
  end

  if writes then
    local write_concern = concern_document(state.write_concern, true)

    if write_concern then
      entries[#entries + 1] = { "writeConcern", write_concern }
    end
  end

  return entries
end

local function aggregate_response(state, pipeline, options, writes)
  local entries = aggregate_entries(state, pipeline, options, writes)

  if writes then
    local response, acknowledged, err = execute_write(state, entries, options)

    if not response then
      return nil, err
    end

    if not acknowledged and not bson.is_document(response:get("cursor")) then
      response = bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", state.full_name },
          { "firstBatch", bson.array({}) },
        }) },
      })
    end

    return response
  end

  return state.executor:command(
    state.database_name,
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      retryable_read = not writes,
      session = options.session,
      session_context = options.session_context,
    }
  )
end

local function cursor_from_response(state, response, options)
  return cursor_model.new(response, {
    batch_size = options.batch_size or 0,
    cancellation = options.cancellation,
    client_state = state.client_state,
    collection_name = state.name,
    comment = options.comment,
    database_name = state.database_name,
    deadline = options.deadline,
    executor = state.executor,
    max_await_time_ms = options.max_await_time_ms,
    on_close = state.on_cursor_close,
    session = options.session,
    session_context = options.session_context,
  })
end

local function count_from_aggregate(response)
  local cursor = response:get("cursor")

  if not bson.is_document(cursor) then
    return protocol_error("count response is missing its cursor document")
  end

  local batch = cursor:get("firstBatch")

  if not bson.is_array(batch) then
    return protocol_error("count response is missing its firstBatch array")
  end

  if #batch == 0 then
    return 0
  end

  if #batch ~= 1 or not bson.is_document(batch:get(1)) then
    return protocol_error("count response contains a malformed result")
  end

  local count = number_value(batch:get(1):get("n"))

  if math.type(count) ~= "integer" or count < 0 then
    return protocol_error("count response contains an invalid n")
  end

  return count
end

local function find_and_modify(state, filter, change, options, kind)
  require_document("filter", filter)

  local allowed

  if kind == "delete" then
    allowed = FIND_AND_DELETE_OPTIONS
  elseif kind == "replace" then
    require_replacement(change)
    allowed = FIND_AND_REPLACE_OPTIONS
  else
    require_update(change)
    allowed = FIND_AND_UPDATE_OPTIONS
  end

  options = validate_options(options, allowed, "find_one_and_" .. kind)
  require_boolean_option(options, "bypass_document_validation")
  require_boolean_option(options, "raw_data")
  require_boolean_option(options, "upsert")
  require_document_option(options, "collation")
  require_document_option(options, "let")
  require_document_option(options, "projection")
  require_document_option(options, "sort")
  require_nonnegative_integer(options, "max_time_ms")
  require_hint(options)
  require_array_filters(options)

  local return_document = options.return_document or "before"

  if return_document ~= "before" and return_document ~= "after" then
    error("return_document must be 'before' or 'after'", 3)
  end

  local acknowledged = state.write_concern.w ~= 0

  if options.array_filters ~= nil and not acknowledged then
    error("array_filters is unsupported for unacknowledged writes", 3)
  end

  if options.hint ~= nil and state.max_wire_version < 8 then
    error("find-and-modify hint requires MongoDB 4.2 or newer", 3)
  end

  if options.hint ~= nil and not acknowledged and state.max_wire_version < 9 then
    error("unacknowledged find-and-modify hint requires MongoDB 4.4 or newer", 3)
  end

  local entries = {
    { "findAndModify", state.name },
    { "query", filter },
    { "new", return_document == "after" },
  }

  if kind == "delete" then
    entries[#entries + 1] = { "remove", true }
  else
    entries[#entries + 1] = { "update", change }
  end

  for _, field in ipairs({
    { "array_filters", "arrayFilters" },
    { "collation", "collation" },
    { "hint", "hint" },
    { "max_time_ms", "maxTimeMS" },
    { "projection", "fields" },
    { "sort", "sort" },
    { "upsert", "upsert" },
  }) do
    if options[field[1]] ~= nil then
      entries[#entries + 1] = { field[2], options[field[1]] }
    end
  end

  append_common_write_fields(entries, state, options, kind ~= "delete")
  local response, was_acknowledged, err = execute_write(
    state,
    entries,
    options,
    true
  )

  if not response then
    return nil, err
  end

  if not was_acknowledged then
    return nil
  end

  local value = response:get("value")

  if value == nil or bson.is_null(value) then
    return nil
  end

  if not bson.is_document(value) then
    return protocol_error("findAndModify response contains a non-document value")
  end

  return value
end

function M.aggregate(state, pipeline, options)
  require_pipeline(pipeline)
  options = validate_options(options, AGGREGATE_OPTIONS, "aggregate")
  require_boolean_option(options, "allow_disk_use")
  require_boolean_option(options, "bypass_document_validation")
  require_boolean_option(options, "raw_data")
  require_document_option(options, "collation")
  require_document_option(options, "let")
  require_hint(options)
  require_nonnegative_integer(options, "batch_size")
  require_nonnegative_integer(options, "max_await_time_ms")
  require_nonnegative_integer(options, "max_time_ms")
  options.session_context = options.session == nil
    and type(state.executor.release_session_context) == "function" and {} or nil
  local writes = pipeline_writes(pipeline)
  local response, err = aggregate_response(state, pipeline, options, writes)

  if not response then
    if options.session_context then
      state.executor:release_session_context(options.session_context)
    end

    return nil, err
  end

  return cursor_from_response(state, response, options)
end

function M.count_documents(state, filter, options)
  require_document("filter", filter)
  options = validate_options(options, COUNT_OPTIONS, "count_documents")
  require_document_option(options, "collation")
  require_boolean_option(options, "raw_data")
  require_hint(options)
  require_nonnegative_integer(options, "skip")
  require_nonnegative_integer(options, "max_time_ms")

  if options.limit ~= nil and (math.type(options.limit) ~= "integer" or options.limit <= 0) then
    error("limit must be a positive integer", 2)
  end

  local stages = {
    bson.document({ { "$match", filter } }),
  }

  if options.skip ~= nil then
    stages[#stages + 1] = bson.document({ { "$skip", options.skip } })
  end

  if options.limit ~= nil then
    stages[#stages + 1] = bson.document({ { "$limit", options.limit } })
  end

  stages[#stages + 1] = bson.document({
    { "$group", bson.document({
      { "_id", 1 },
      { "n", bson.document({ { "$sum", 1 } }) },
    }) },
  })
  local aggregate_options = {
    cancellation = options.cancellation,
    collation = options.collation,
    comment = options.comment,
    deadline = options.deadline,
    hint = options.hint,
    max_time_ms = options.max_time_ms,
    raw_data = options.raw_data,
    session = options.session,
  }
  local response, err = aggregate_response(
    state,
    bson.array(stages),
    aggregate_options,
    false
  )

  if not response then
    return nil, err
  end

  return count_from_aggregate(response)
end

function M.estimated_document_count(state, options)
  options = validate_options(
    options,
    ESTIMATED_COUNT_OPTIONS,
    "estimated_document_count"
  )
  require_boolean_option(options, "raw_data")
  require_nonnegative_integer(options, "max_time_ms")
  local entries = { { "count", state.name } }

  if options.max_time_ms ~= nil then
    entries[#entries + 1] = { "maxTimeMS", options.max_time_ms }
  end

  if options.comment ~= nil then
    entries[#entries + 1] = { "comment", options.comment }
  end

  append_raw_data(entries, state, options)
  append_read_concern(entries, state)
  local response, err = state.executor:command(
    state.database_name,
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      retryable_read = true,
      session = options.session,
    }
  )

  if not response then
    return nil, err
  end

  return count_field(response, "n")
end

function M.distinct(state, key, filter, options)
  if type(key) ~= "string" or key == "" then
    error("distinct key must be a non-empty string", 2)
  end

  if filter == nil then
    filter = bson.document({})
  else
    require_document("filter", filter)
  end

  options = validate_options(options, DISTINCT_OPTIONS, "distinct")
  require_boolean_option(options, "raw_data")
  require_document_option(options, "collation")
  require_hint(options)
  require_nonnegative_integer(options, "max_time_ms")
  local entries = {
    { "distinct", state.name },
    { "key", key },
    { "query", filter },
  }

  for _, field in ipairs({
    { "collation", "collation" },
    { "comment", "comment" },
    { "hint", "hint" },
    { "max_time_ms", "maxTimeMS" },
  }) do
    if options[field[1]] ~= nil then
      entries[#entries + 1] = { field[2], options[field[1]] }
    end
  end

  append_raw_data(entries, state, options)
  append_read_concern(entries, state)
  local response, err = state.executor:command(
    state.database_name,
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      retryable_read = true,
      session = options.session,
    }
  )

  if not response then
    return nil, err
  end

  local values = response:get("values")

  if not bson.is_array(values) then
    return protocol_error("distinct response is missing its values array")
  end

  return values
end

function M.find_one_and_delete(state, filter, options)
  return find_and_modify(state, filter, nil, options, "delete")
end

function M.find_one_and_replace(state, filter, replacement, options)
  return find_and_modify(state, filter, replacement, options, "replace")
end

function M.find_one_and_update(state, filter, update, options)
  return find_and_modify(state, filter, update, options, "update")
end

function M.update_one(state, filter, update, options)
  return update_operation(state, filter, update, options, false, false)
end

function M.update_many(state, filter, update, options)
  return update_operation(state, filter, update, options, true, false)
end

function M.replace_one(state, filter, replacement, options)
  return update_operation(state, filter, replacement, options, false, true)
end

function M.delete_one(state, filter, options)
  return delete_operation(state, filter, options, false)
end

function M.delete_many(state, filter, options)
  return delete_operation(state, filter, options, true)
end

function M.insert_one(state, document, options)
  if not bson.is_document(document) then
    error("insert document must be a BSON document", 2)
  end

  options = validate_options(options, INSERT_OPTIONS, "insert_one")

  if options.bypass_document_validation ~= nil
      and type(options.bypass_document_validation) ~= "boolean"
  then
    error("bypass_document_validation must be a boolean", 2)
  end

  if options.raw_data ~= nil and type(options.raw_data) ~= "boolean" then
    error("raw_data must be a boolean", 2)
  end

  local encoded, identifier, id_err = with_generated_id(state, document)

  if not encoded then
    return nil, id_err
  end

  local entries = {
    { "insert", state.name },
    { "ordered", true },
    { "documents", bson.array({ encoded }) },
  }

  if options.bypass_document_validation ~= nil then
    entries[#entries + 1] = {
      "bypassDocumentValidation",
      options.bypass_document_validation,
    }
  end

  if options.comment ~= nil then
    entries[#entries + 1] = { "comment", options.comment }
  end

  if options.raw_data ~= nil and state.max_wire_version >= 27 then
    entries[#entries + 1] = { "rawData", options.raw_data }
  end

  local write_concern = concern_document(state.write_concern, true)

  if write_concern then
    entries[#entries + 1] = { "writeConcern", write_concern }
  end

  local acknowledged = state.write_concern.w ~= 0
  local response, err = state.executor:command(
    state.database_name,
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      no_response = not acknowledged,
      retryable_write = acknowledged,
      session = options.session,
    }
  )

  if not response then
    return nil, err
  end

  if acknowledged then
    local valid
    valid, err = check_write_response(response)

    if not valid then
      return nil, err
    end
  end

  return result({
    acknowledged = acknowledged,
    inserted_id = acknowledged and identifier or nil,
  })
end

function M.find(state, filter, options)
  if filter == nil then
    filter = bson.document({})
  elseif not bson.is_document(filter) then
    error("find filter must be a BSON document", 2)
  end

  options = validate_options(options, FIND_OPTIONS, "find")
  local session_context = options.session == nil
    and type(state.executor.release_session_context) == "function" and {} or nil
  local batch_size = options.batch_size or 0
  local limit = options.limit or 0

  if math.type(batch_size) ~= "integer" or batch_size < 0 then
    error("batch_size must be a non-negative integer", 2)
  end

  if math.type(limit) ~= "integer" then
    error("limit must be an integer", 2)
  end

  if options.no_cursor_timeout ~= nil and type(options.no_cursor_timeout) ~= "boolean" then
    error("no_cursor_timeout must be a boolean", 2)
  end

  local single_batch = limit < 0
  local absolute_limit = math.abs(limit)
  local entries = {
    { "find", state.name },
    { "filter", filter },
  }

  append_find_options(entries, state, options)

  if absolute_limit > 0 then
    entries[#entries + 1] = { "limit", absolute_limit }
  end

  if batch_size > 0 then
    local command_batch_size = batch_size

    if absolute_limit > 0 and batch_size == absolute_limit then
      command_batch_size = batch_size + 1
    end

    entries[#entries + 1] = { "batchSize", command_batch_size }
  end

  if single_batch then
    entries[#entries + 1] = { "singleBatch", true }
  end

  if options.no_cursor_timeout ~= nil then
    entries[#entries + 1] = { "noCursorTimeout", options.no_cursor_timeout }
  end

  local read_concern = concern_document(state.read_concern, false)

  if read_concern then
    entries[#entries + 1] = { "readConcern", read_concern }
  end

  local response, err = state.executor:command(
    state.database_name,
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      retryable_read = true,
      session = options.session,
      session_context = session_context,
    }
  )

  if not response then
    if session_context then
      state.executor:release_session_context(session_context)
    end

    return nil, err
  end

  return cursor_model.new(response, {
    batch_size = batch_size,
    cancellation = options.cancellation,
    client_state = state.client_state,
    collection_name = state.name,
    comment = options.comment,
    database_name = state.database_name,
    deadline = options.deadline,
    executor = state.executor,
    limit = absolute_limit,
    on_close = state.on_cursor_close,
    session = options.session,
    session_context = session_context,
  })
end

function M.find_one(state, filter, options)
  if filter == nil then
    filter = bson.document({})
  elseif not bson.is_document(filter) then
    filter = bson.document({ { "_id", filter } })
  end

  options = validate_options(options, FIND_OPTIONS, "find_one")
  local entries = {
    { "find", state.name },
    { "filter", filter },
  }

  append_find_options(entries, state, options)
  entries[#entries + 1] = { "limit", 1 }
  entries[#entries + 1] = { "singleBatch", true }
  local read_concern = concern_document(state.read_concern, false)

  if read_concern then
    entries[#entries + 1] = { "readConcern", read_concern }
  end

  local response, err = state.executor:command(
    state.database_name,
    bson.document(entries),
    {
      cancellation = options.cancellation,
      deadline = options.deadline,
      retryable_read = true,
      session = options.session,
    }
  )

  if not response then
    return nil, err
  end

  local cursor = response:get("cursor")

  if not bson.is_document(cursor) then
    return protocol_error("find response is missing its cursor document")
  end

  local first_batch = cursor:get("firstBatch")

  if not bson.is_array(first_batch) then
    return protocol_error("find response is missing its firstBatch array")
  end

  if #first_batch == 0 then
    return nil
  end

  local found = first_batch:get(1)

  if not bson.is_document(found) then
    return protocol_error("find response firstBatch contains a non-document")
  end

  return found
end

return M
