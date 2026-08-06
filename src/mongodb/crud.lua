local bson = require("mongodb.bson")
local errors = require("mongodb.error")

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
  cancellation = true,
  deadline = true,
}
local INSERT_OPTIONS = {
  bypass_document_validation = true,
  cancellation = true,
  comment = true,
  deadline = true,
  raw_data = true,
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
