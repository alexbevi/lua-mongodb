local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local MODEL_STATES = setmetatable({}, { __mode = "k" })
local RESULT_STATES = setmetatable({}, { __mode = "k" })
local next_operation_id = 1

local UPDATE_MODEL_OPTIONS = {
  array_filters = true,
  collation = true,
  hint = true,
  sort = true,
  upsert = true,
}

local REPLACE_MODEL_OPTIONS = {
  collation = true,
  hint = true,
  sort = true,
  upsert = true,
}

local MODEL_METATABLE = {
  __index = function(value, key)
    local state = MODEL_STATES[value]

    if state and key == "kind" then
      return state.kind
    end
  end,
  __metatable = "mongodb.client_bulk.model",
  __newindex = function()
    error("client bulk write models are immutable", 2)
  end,
}

local RESULT_METATABLE = {
  __index = function(value, key)
    local state = RESULT_STATES[value]

    if state then
      return state[key]
    end
  end,
  __metatable = "mongodb.client_bulk.result",
  __newindex = function()
    error("client bulk result values are immutable", 2)
  end,
}

local function client_error(message)
  return nil, errors.new({
    category = errors.CATEGORY.CLIENT,
    message = message,
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

local function operation_id()
  local value = next_operation_id

  next_operation_id = value == 0x7fffffff and 1 or value + 1
  return value
end

local function validate_namespace(namespace)
  if type(namespace) ~= "string" then
    error("client bulk namespace must be a string", 3)
  end

  if utf8.len(namespace) == nil then
    error("client bulk namespace must be valid UTF-8", 3)
  end

  local separator = namespace:find(".", 1, true)

  if separator == nil or separator == 1 or separator == #namespace then
    error("client bulk namespace must include a database and collection", 3)
  end
end

local function require_document(name, value)
  if not bson.is_document(value) then
    error(name .. " must be a BSON document", 3)
  end
end

local function validate_model_options(options, allowed, kind)
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
  local filters = options.array_filters

  if filters == nil then
    return
  end

  if not bson.is_array(filters) then
    error("array_filters must be a BSON array", 3)
  end

  for _, filter in filters:iter() do
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
    error("replacement document must not begin with an atomic modifier", 3)
  end
end

local function new_model(kind, fields)
  local value = {}

  fields.kind = kind
  MODEL_STATES[value] = fields
  return setmetatable(value, MODEL_METATABLE)
end

function M.insert_one(namespace, document)
  validate_namespace(namespace)
  require_document("insert document", document)
  return new_model("insert", {
    document = document,
    namespace = namespace,
  })
end

local function validate_update_options(options, kind, multi)
  options = validate_model_options(options, UPDATE_MODEL_OPTIONS, kind)
  require_boolean(options, "upsert")
  require_document_option(options, "collation")
  require_document_option(options, "sort")
  require_hint(options)
  require_array_filters(options)

  if multi and options.sort ~= nil then
    error("sort is not supported by update_many", 3)
  end

  return options
end

local function update_model(namespace, filter, update, options, multi)
  validate_namespace(namespace)
  require_document("filter", filter)
  require_update(update)
  options = validate_update_options(
    options,
    multi and "update_many model" or "update_one model",
    multi
  )
  return new_model("update", {
    filter = filter,
    multi = multi,
    namespace = namespace,
    options = options,
    update = update,
  })
end

function M.update_one(namespace, filter, update, options)
  return update_model(namespace, filter, update, options, false)
end

function M.update_many(namespace, filter, update, options)
  return update_model(namespace, filter, update, options, true)
end

function M.replace_one(namespace, filter, replacement, options)
  validate_namespace(namespace)
  require_document("filter", filter)
  require_replacement(replacement)
  options = validate_model_options(options, REPLACE_MODEL_OPTIONS, "replace_one model")
  require_boolean(options, "upsert")
  require_document_option(options, "collation")
  require_document_option(options, "sort")
  require_hint(options)
  return new_model("update", {
    filter = filter,
    multi = false,
    namespace = namespace,
    options = options,
    update = replacement,
  })
end

local function with_generated_id(state, document)
  if document:get("_id") ~= nil then
    return document
  end

  if type(state.object_ids) ~= "table" or type(state.object_ids.new) ~= "function" then
    error("client is missing its ObjectId generator", 3)
  end

  local identifier, err = state.object_ids:new()

  if identifier == nil then
    return nil, err
  end

  local entries = { { "_id", identifier } }

  for key, value in document:iter() do
    entries[#entries + 1] = { key, value }
  end

  return bson.document(entries)
end

local function update_operation(fields, namespace_index)
  local entries = {
    { "update", bson.int32(namespace_index) },
    { "filter", fields.filter },
    { "updateMods", fields.update },
    { "multi", fields.multi },
  }

  for _, field in ipairs({
    { "upsert", "upsert" },
    { "array_filters", "arrayFilters" },
    { "collation", "collation" },
    { "hint", "hint" },
    { "sort", "sort" },
  }) do
    if fields.options[field[1]] ~= nil then
      entries[#entries + 1] = { field[2], fields.options[field[1]] }
    end
  end

  return bson.document(entries)
end

local function operation(state, fields, namespace_index)
  if fields.kind == "update" then
    return update_operation(fields, namespace_index)
  end

  local document, err = with_generated_id(state, fields.document)

  if document == nil then
    return nil, err
  end

  return bson.document({
    { "insert", bson.int32(namespace_index) },
    { "document", document },
  })
end

local function prepare_models(state, models)
  if type(models) ~= "table" or #models == 0 then
    error("client bulk models must be a non-empty array", 3)
  end

  for key in pairs(models) do
    if math.type(key) ~= "integer" or key < 1 or key > #models then
      error("client bulk models must be a dense array", 3)
    end
  end

  local namespace_indexes = {}
  local namespaces = {}
  local operations = {}

  for index, model in ipairs(models) do
    local fields = MODEL_STATES[model]

    if fields == nil then
      error("client bulk writes require mongodb.client_bulk write models", 3)
    end

    local namespace_index = namespace_indexes[fields.namespace]

    if namespace_index == nil then
      namespace_index = #namespaces
      namespace_indexes[fields.namespace] = namespace_index
      namespaces[#namespaces + 1] = bson.document({
        { "ns", fields.namespace },
      })
    end

    local wire, err = operation(state, fields, namespace_index)

    if wire == nil then
      return nil, nil, err
    end

    operations[index] = wire
  end

  return operations, namespaces
end

local function validate_options(options)
  options = options or {}

  if type(options) ~= "table" then
    error("client bulk_write options must be a table", 3)
  end

  for key in pairs(options) do
    if key ~= "ordered" then
      error("unknown client bulk_write option: " .. tostring(key), 3)
    end
  end

  if options.ordered ~= nil and type(options.ordered) ~= "boolean" then
    error("ordered must be a boolean", 3)
  end

  return {
    ordered = options.ordered == nil and true or options.ordered,
  }
end

local function count_field(response, name)
  local value = number_value(response:get(name))

  if math.type(value) ~= "integer" or value < 0 then
    return protocol_error("client bulk response contains an invalid " .. name)
  end

  return value
end

local function result_from(response)
  local cursor = response:get("cursor")

  if not bson.is_document(cursor) then
    return protocol_error("client bulk response is missing its cursor")
  end

  local first_batch = cursor:get("firstBatch")
  local cursor_id = number_value(cursor:get("id"))

  if not bson.is_array(first_batch) or math.type(cursor_id) ~= "integer" then
    return protocol_error("client bulk response contains a malformed cursor")
  end

  if cursor_id ~= 0 then
    return protocol_error("client bulk response cursor was not exhausted")
  end

  local n_errors, err = count_field(response, "nErrors")

  if n_errors == nil then
    return nil, err
  end

  if n_errors ~= 0 or #first_batch ~= 0 then
    return protocol_error("client bulk response contains unsupported write results")
  end

  local fields = {
    acknowledged = true,
    has_verbose_results = false,
  }

  for field, response_name in pairs({
    deleted_count = "nDeleted",
    inserted_count = "nInserted",
    matched_count = "nMatched",
    modified_count = "nModified",
    upserted_count = "nUpserted",
  }) do
    local value
    value, err = count_field(response, response_name)

    if value == nil then
      return nil, err
    end

    fields[field] = value
  end

  local result = {}

  RESULT_STATES[result] = fields
  return setmetatable(result, RESULT_METATABLE)
end

function M.execute(state, models, options)
  if state.max_wire_version < 25 then
    return client_error("client bulk_write requires MongoDB 8.0 or newer")
  end

  options = validate_options(options)
  local operations, namespaces, err = prepare_models(state, models)

  if operations == nil then
    return nil, err
  end

  local response
  response, err = state.executor:command("admin", bson.document({
    { "bulkWrite", 1 },
    { "errorsOnly", true },
    { "ordered", options.ordered },
  }), {
    max_sequence_document_size = state.max_message_size,
    operation_id = operation_id(),
    sequences = {
      { identifier = "ops", documents = operations },
      { identifier = "nsInfo", documents = namespaces },
    },
  })

  if response == nil then
    return nil, err
  end

  return result_from(response)
end

return M
