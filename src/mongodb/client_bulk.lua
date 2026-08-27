local bson = require("mongodb.bson")
local driver_options = require("mongodb.config.options")
local errors = require("mongodb.error")
local operation_id = require("mongodb.operation_id")

local M = {}

local MODEL_STATES = setmetatable({}, { __mode = "k" })
local RESULT_MAP_STATES = setmetatable({}, { __mode = "k" })
local RESULT_STATES = setmetatable({}, { __mode = "k" })

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

local DELETE_MODEL_OPTIONS = {
  collation = true,
  hint = true,
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
  __pairs = function(value)
    return next, RESULT_STATES[value], nil
  end,
}

local RESULT_MAP_METATABLE = {
  __index = function(value, key)
    local state = RESULT_MAP_STATES[value]

    if state then
      return state[key]
    end
  end,
  __metatable = "mongodb.client_bulk.result_map",
  __newindex = function()
    error("client bulk result maps are immutable", 2)
  end,
  __pairs = function(value)
    return next, RESULT_MAP_STATES[value], nil
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

local function result_value(fields)
  local value = {}

  RESULT_STATES[value] = fields
  return setmetatable(value, RESULT_METATABLE)
end

local function result_map(fields)
  local value = {}

  RESULT_MAP_STATES[value] = fields
  return setmetatable(value, RESULT_MAP_METATABLE)
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

local function delete_model(namespace, filter, options, multi)
  validate_namespace(namespace)
  require_document("filter", filter)
  options = validate_model_options(
    options,
    DELETE_MODEL_OPTIONS,
    multi and "delete_many model" or "delete_one model"
  )
  require_document_option(options, "collation")
  require_hint(options)
  return new_model("delete", {
    filter = filter,
    multi = multi,
    namespace = namespace,
    options = options,
  })
end

function M.delete_one(namespace, filter, options)
  return delete_model(namespace, filter, options, false)
end

function M.delete_many(namespace, filter, options)
  return delete_model(namespace, filter, options, true)
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

local function delete_operation(fields, namespace_index)
  local entries = {
    { "delete", bson.int32(namespace_index) },
    { "filter", fields.filter },
    { "multi", fields.multi },
  }

  for _, name in ipairs({ "collation", "hint" }) do
    if fields.options[name] ~= nil then
      entries[#entries + 1] = { name, fields.options[name] }
    end
  end

  return bson.document(entries)
end

local function operation(state, fields, namespace_index)
  if fields.kind == "update" then
    return update_operation(fields, namespace_index)
  end

  if fields.kind == "delete" then
    return delete_operation(fields, namespace_index)
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
  local result_models = {}

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
    result_models[index] = {
      kind = fields.kind,
      namespace = fields.namespace,
      operation = wire,
    }

    if fields.kind == "insert" then
      result_models[index].inserted_id = wire:get("document"):get("_id")
    end
  end

  return operations, namespaces, result_models
end

local function reindex_operation(operation_document, namespace_index)
  local entries = {}
  local first = true

  for key, value in operation_document:iter() do
    if first then
      value = bson.int32(namespace_index)
      first = false
    end

    entries[#entries + 1] = { key, value }
  end

  return bson.document(entries)
end

local function batch_size_error()
  return errors.new({
    category = errors.CATEGORY.CLIENT,
    message = "client bulk operation exceeds maxMessageSizeBytes",
  })
end

local function encoded_size(document, limit)
  local encoded, err = bson.encode(document, {
    max_binary_size = limit,
    max_document_size = limit,
    max_string_size = limit,
  })

  if encoded ~= nil then
    return #encoded
  end

  local details = err.details

  if details ~= nil
      and (details.max_binary_size == limit
        or details.max_document_size == limit
        or details.max_string_size == limit)
  then
    return nil, batch_size_error()
  end

  return nil, err
end

local function new_batch()
  return {
    encoded_size = 0,
    namespace_indexes = {},
    namespaces = {},
    operations = {},
    original_indexes = {},
    result_models = {},
  }
end

local function batch_candidate(state, batch, operation_document, model)
  local namespace_index = batch.namespace_indexes[model.namespace]
  local namespace_document

  if namespace_index == nil then
    namespace_index = #batch.namespaces
    namespace_document = bson.document({ { "ns", model.namespace } })
  end

  local wire = reindex_operation(operation_document, namespace_index)
  local operation_size, err = encoded_size(wire, state.max_message_size)

  if operation_size == nil then
    return nil, err
  end

  local namespace_size = 0

  if namespace_document ~= nil then
    namespace_size, err = encoded_size(
      namespace_document,
      state.max_message_size
    )

    if namespace_size == nil then
      return nil, err
    end
  end

  return {
    encoded_size = operation_size + namespace_size,
    namespace_document = namespace_document,
    namespace_index = namespace_index,
    result_model = {
      inserted_id = model.inserted_id,
      kind = model.kind,
      namespace = model.namespace,
      operation = wire,
    },
    wire = wire,
  }
end

local function append_candidate(batch, candidate, model, original_index)
  local local_index = #batch.operations + 1

  if candidate.namespace_document ~= nil then
    batch.namespace_indexes[model.namespace] = candidate.namespace_index
    batch.namespaces[#batch.namespaces + 1] = candidate.namespace_document
  end

  batch.encoded_size = batch.encoded_size + candidate.encoded_size
  batch.operations[local_index] = candidate.wire
  batch.original_indexes[local_index] = original_index
  batch.result_models[local_index] = candidate.result_model
end

local function create_batches(state, command, operations, result_models)
  local command_size, err = encoded_size(command, state.max_message_size)

  if command_size == nil then
    return nil, err
  end

  local maximum_sequence_size = state.max_message_size - 1000 - command_size
  local batches = {}
  local position = 1

  while position <= #operations do
    local batch = new_batch()

    while position <= #operations
        and #batch.operations < state.max_write_batch_size
    do
      local model = result_models[position]
      local candidate
      candidate, err = batch_candidate(
        state,
        batch,
        operations[position],
        model
      )

      if candidate == nil
          or batch.encoded_size + candidate.encoded_size
            > maximum_sequence_size
      then
        if #batch.operations == 0 then
          return nil, candidate == nil and err or batch_size_error()
        end

        break
      end

      append_candidate(batch, candidate, model, position)
      position = position + 1
    end

    batches[#batches + 1] = batch
  end

  return batches
end

local function concern_document(concern)
  local entries = {}

  if concern.journal ~= nil then
    entries[#entries + 1] = { "j", concern.journal }
  end

  if concern.w ~= nil then
    entries[#entries + 1] = { "w", concern.w }
  end

  if concern.w_timeout_ms ~= nil then
    entries[#entries + 1] = { "wtimeout", concern.w_timeout_ms }
  end

  if #entries > 0 then
    return bson.document(entries)
  end
end

local function validate_options(state, options)
  options = options or {}

  if type(options) ~= "table" then
    error("client bulk_write options must be a table", 3)
  end

  for key in pairs(options) do
    if key ~= "bypass_document_validation"
        and key ~= "cancellation"
        and key ~= "comment"
        and key ~= "deadline"
        and key ~= "let"
        and key ~= "ordered"
        and key ~= "raw_data"
        and key ~= "session"
        and key ~= "verbose_results"
        and key ~= "write_concern"
    then
      error("unknown client bulk_write option: " .. tostring(key), 3)
    end
  end

  if options.bypass_document_validation ~= nil
      and type(options.bypass_document_validation) ~= "boolean"
  then
    error("bypass_document_validation must be a boolean", 3)
  end

  if options.ordered ~= nil and type(options.ordered) ~= "boolean" then
    error("ordered must be a boolean", 3)
  end

  if options.raw_data ~= nil and type(options.raw_data) ~= "boolean" then
    error("raw_data must be a boolean", 3)
  end

  if options.verbose_results ~= nil and type(options.verbose_results) ~= "boolean" then
    error("verbose_results must be a boolean", 3)
  end

  if options.let ~= nil and not bson.is_document(options.let) then
    error("let must be a BSON document", 3)
  end

  local write_concern = state.write_concern

  if options.write_concern ~= nil then
    local normalized, err = driver_options.normalize(nil, {
      write_concern = options.write_concern,
    })

    if normalized == nil then
      return nil, err
    end

    write_concern = normalized.write_concern
  end

  local in_transaction = options.session ~= nil
    and type(options.session.is_in_transaction) == "function"
    and options.session:is_in_transaction()

  if in_transaction and options.write_concern ~= nil then
    return client_error(
      "Cannot set write concern after starting a transaction"
    )
  end

  local acknowledged = in_transaction or write_concern.w ~= 0

  if not acknowledged and options.verbose_results == true then
    return client_error(
      "Cannot request unacknowledged write concern and verbose results"
    )
  end

  local ordered = options.ordered == nil and true or options.ordered

  if not acknowledged and ordered then
    return client_error(
      "Cannot request unacknowledged write concern and ordered writes"
    )
  end

  if not acknowledged and options.session ~= nil then
    return client_error(
      "Explicit sessions are incompatible with unacknowledged write concern"
    )
  end

  return {
    acknowledged = acknowledged,
    bypass_document_validation = options.bypass_document_validation,
    cancellation = options.cancellation,
    comment = options.comment,
    deadline = options.deadline,
    let = options.let,
    in_transaction = in_transaction,
    ordered = ordered,
    raw_data = options.raw_data,
    session = options.session,
    verbose_results = options.verbose_results == true,
    write_concern = write_concern,
  }
end

local function count_field(response, name)
  local value = number_value(response:get(name))

  if math.type(value) ~= "integer" or value < 0 then
    return protocol_error("client bulk response contains an invalid " .. name)
  end

  return value
end

local function cursor_batch(response, batch_name)
  local cursor = response:get("cursor")

  if not bson.is_document(cursor) then
    return protocol_error("client bulk response is missing its cursor")
  end

  local batch = cursor:get(batch_name)
  local cursor_id = cursor:get("id")
  local numeric_id = number_value(cursor_id)

  if not bson.is_array(batch) or math.type(numeric_id) ~= "integer" or numeric_id < 0 then
    return protocol_error("client bulk response contains a malformed cursor")
  end

  return batch, cursor_id, numeric_id
end

local function detail_count(document, name)
  local value = number_value(document:get(name))

  if math.type(value) ~= "integer" or value < 0 then
    return protocol_error("client bulk result contains an invalid " .. name)
  end

  return value
end

local function operation_detail(model, document)
  local count, err = detail_count(document, "n")

  if count == nil then
    return nil, err
  end

  if model.kind == "insert" then
    return result_value({
      acknowledged = true,
      inserted_id = model.inserted_id,
    })
  end

  if model.kind == "delete" then
    return result_value({
      acknowledged = true,
      deleted_count = count,
    })
  end

  local modified
  modified, err = detail_count(document, "nModified")

  if modified == nil then
    return nil, err
  end

  local upserted = document:get("upserted")
  local fields = {
    acknowledged = true,
    matched_count = count,
    modified_count = modified,
  }

  if upserted ~= nil then
    if not bson.is_document(upserted) or upserted:get("_id") == nil then
      return protocol_error("client bulk result contains a malformed upserted value")
    end

    fields.upserted_id = upserted:get("_id")
  end

  return result_value(fields)
end

local function individual_error(document, model, index)
  local code = number_value(document:get("code"))
  local code_name = document:get("codeName")
  local details = document:get("errInfo")
  local message = document:get("errmsg")

  if math.type(code) ~= "integer" then
    return protocol_error("client bulk write error contains an invalid code")
  end

  if message ~= nil and type(message) ~= "string" then
    return protocol_error("client bulk write error contains an invalid message")
  end

  if code_name ~= nil and (type(code_name) ~= "string" or code_name == "") then
    return protocol_error("client bulk write error contains an invalid code name")
  end

  if details ~= nil and not bson.is_document(details) then
    return protocol_error("client bulk write error contains malformed details")
  end

  return {
    code = code,
    code_name = code_name,
    details = details,
    index = index + 1,
    message = (message == nil or message == "")
      and "client bulk write failed"
      or message,
    operation = model.operation,
  }
end

local function record_batch(batch, result_models, details, seen, write_errors, ordered)
  for _, document in batch:iter() do
    if not bson.is_document(document) then
      return protocol_error("client bulk result cursor contains a non-document value")
    end

    local ok = number_value(document:get("ok"))
    local index = number_value(document:get("idx"))

    if math.type(index) ~= "integer"
        or index < 0
        or index >= #result_models
        or seen[index]
    then
      return protocol_error("client bulk result contains an invalid operation index")
    end

    seen[index] = true
    local model = result_models[index + 1]

    if ok == 0 then
      local write_error, err = individual_error(document, model, index)

      if write_error == nil then
        return nil, err
      end

      write_errors[#write_errors + 1] = write_error

      if ordered then
        return true, nil, true
      end
    elseif ok ~= 1 then
      return protocol_error("client bulk result contains an invalid ok value")
    else
      local detail, err = operation_detail(model, document)

      if detail == nil then
        return nil, err
      end

      if details ~= nil then
        details[model.kind][index + 1] = detail
      end
    end
  end

  return true
end

local function consume_results(state, response, result_models, details, options)
  local batch, cursor_id, numeric_id = cursor_batch(response, "firstBatch")

  if batch == nil then
    return nil, cursor_id
  end

  local seen = {}
  local write_errors = {}

  while true do
    local recorded, err, halted = record_batch(
      batch,
      result_models,
      details,
      seen,
      write_errors,
      options.ordered
    )

    if not recorded then
      return nil, err
    end

    if halted or numeric_id == 0 then
      return write_errors
    end

    local entries = {
      { "getMore", cursor_id },
      { "collection", "$cmd.bulkWrite" },
    }

    if options.comment ~= nil then
      entries[#entries + 1] = { "comment", options.comment }
    end

    response, err = state.executor:command("admin", bson.document(entries), {
      cancellation = options.cancellation,
      deadline = options.deadline,
      session = options.session,
      session_context = options.session_context,
    })

    if response == nil then
      return nil, err, cursor_id, write_errors
    end

    batch, cursor_id, numeric_id = cursor_batch(response, "nextBatch")

    if batch == nil then
      return nil, cursor_id
    end
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

local function write_concern_error(response)
  local item = response:get("writeConcernError")

  if item == nil then
    return nil
  end

  if not bson.is_document(item) then
    return protocol_error("client bulk response contains a malformed write concern error")
  end

  local code = number_value(item:get("code"))
  local code_name = item:get("codeName")
  local details = item:get("errInfo")
  local message = item:get("errmsg")

  if math.type(code) ~= "integer" then
    return protocol_error("client bulk write concern error contains an invalid code")
  end

  if message ~= nil and type(message) ~= "string" then
    return protocol_error("client bulk write concern error contains an invalid message")
  end

  if code_name ~= nil and (type(code_name) ~= "string" or code_name == "") then
    return protocol_error("client bulk write concern error contains an invalid code name")
  end

  if details ~= nil and not bson.is_document(details) then
    return protocol_error("client bulk write concern error contains malformed details")
  end

  return {
    code = code,
    code_name = code_name,
    details = details,
    message = (message == nil or message == "")
      and "client bulk write concern failed"
      or message,
  }
end

local function write_failure(
  write_errors,
  write_concern_errors,
  partial_result,
  labels
)
  table.sort(write_errors, function(left, right)
    return left.index < right.index
  end)
  local first = write_errors[1] or write_concern_errors[1]

  return nil, errors.new({
    category = errors.CATEGORY.WRITE,
    code = first.code,
    code_name = first.code_name,
    details = {
      partial_result = partial_result,
      write_concern_errors = write_concern_errors,
      write_errors = write_errors,
    },
    labels = labels,
    message = first.message,
  })
end

local function command_failure(
  cause,
  partial_result,
  write_errors,
  cleanup_error
)
  local cause_details = cause.details
  local labels = {}

  for _, label in ipairs(cause.labels) do
    labels[#labels + 1] = label
  end

  write_errors = write_errors or {}

  return errors.new({
    category = errors.CATEGORY.WRITE,
    cause = cause,
    code = cause.code,
    code_name = cause.code_name,
    details = {
      cleanup_error = cleanup_error,
      partial_result = partial_result,
      response = cause_details and cause_details.response or nil,
      write_concern_errors = {},
      write_errors = write_errors,
    },
    labels = labels,
    message = cause.message,
  })
end

local function result_from(state, response, result_models, options)
  local n_errors, err = count_field(response, "nErrors")

  if n_errors == nil then
    return nil, err
  end

  local fields = {
    acknowledged = true,
    has_verbose_results = options.verbose_results,
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

  local details

  if options.verbose_results then
    details = {
      delete = {},
      insert = {},
      update = {},
    }
    fields.delete_results = result_map(details.delete)
    fields.insert_results = result_map(details.insert)
    fields.update_results = result_map(details.update)
  end

  local write_errors
  local observed_write_errors
  local failed_cursor_id
  write_errors, err, failed_cursor_id, observed_write_errors = consume_results(
    state,
    response,
    result_models,
    details,
    options
  )

  if write_errors == nil then
    if failed_cursor_id ~= nil then
      local _, cleanup_error = state.executor:command(
        "admin",
        bson.document({
          { "killCursors", "$cmd.bulkWrite" },
          { "cursors", bson.array({ failed_cursor_id }) },
        }),
        {
          cancellation = options.cancellation,
          deadline = options.deadline,
          session = options.session,
          session_context = options.session_context,
        }
      )
      local partial_result = n_errors < #result_models
        and result_value(fields)
        or nil

      return nil, command_failure(
        err,
        partial_result,
        observed_write_errors,
        cleanup_error
      )
    end

    return nil, err
  end

  if #write_errors ~= n_errors then
    return protocol_error("client bulk response contains an inconsistent error count")
  end

  local concern_error
  concern_error, err = write_concern_error(response)

  if err then
    return nil, err
  end

  if #write_errors > 0 or concern_error ~= nil then
    local has_success

    if #write_errors == 0 then
      has_success = n_errors < #result_models
    elseif options.ordered then
      has_success = write_errors[1].index > 1
    else
      has_success = n_errors < #result_models
    end

    local partial_result = has_success and result_value(fields) or nil
    local concern_errors = concern_error and { concern_error } or {}

    return write_failure(
      write_errors,
      concern_errors,
      partial_result,
      labels_from(response)
    )
  end

  return result_value(fields)
end

local COUNT_RESULT_FIELDS = {
  "deleted_count",
  "inserted_count",
  "matched_count",
  "modified_count",
  "upserted_count",
}

local VERBOSE_RESULT_FIELDS = {
  { "delete_results", "delete" },
  { "insert_results", "insert" },
  { "update_results", "update" },
}

local function result_accumulator(options)
  local full = {
    fields = {
      acknowledged = true,
      deleted_count = 0,
      has_verbose_results = options.verbose_results,
      inserted_count = 0,
      matched_count = 0,
      modified_count = 0,
      upserted_count = 0,
    },
    has_success = false,
    labels = {},
    write_concern_errors = {},
    write_errors = {},
  }

  if options.verbose_results then
    full.details = {
      delete = {},
      insert = {},
      update = {},
    }
  end

  return full
end

local function merge_successful_batch(full, batch, result)
  full.has_success = true

  for _, field in ipairs(COUNT_RESULT_FIELDS) do
    full.fields[field] = full.fields[field] + result[field]
  end

  if full.details == nil then
    return
  end

  for _, mapping in ipairs(VERBOSE_RESULT_FIELDS) do
    for local_index, detail in pairs(result[mapping[1]]) do
      local original_index = batch.original_indexes[local_index]

      full.details[mapping[2]][original_index] = detail
    end
  end
end

local function merge_batch_failure(full, batch, err)
  local details = err.details

  if details.partial_result ~= nil then
    merge_successful_batch(full, batch, details.partial_result)
  end

  for _, item in ipairs(details.write_errors) do
    full.write_errors[#full.write_errors + 1] = {
      code = item.code,
      code_name = item.code_name,
      details = item.details,
      index = batch.original_indexes[item.index],
      message = item.message,
      operation = item.operation,
    }
  end

  for _, item in ipairs(details.write_concern_errors) do
    full.write_concern_errors[#full.write_concern_errors + 1] = {
      code = item.code,
      code_name = item.code_name,
      details = item.details,
      message = item.message,
    }
  end

  for _, label in ipairs(err.labels) do
    full.labels[#full.labels + 1] = label
  end
end

local function accumulated_result(full)
  if full.details ~= nil then
    full.fields.delete_results = result_map(full.details.delete)
    full.fields.insert_results = result_map(full.details.insert)
    full.fields.update_results = result_map(full.details.update)
  end

  return result_value(full.fields)
end

local function batch_is_retryable(batch, options)
  if not options.acknowledged or options.in_transaction then
    return false
  end

  for _, operation_document in ipairs(batch.operations) do
    if operation_document:get("multi") == true then
      return false
    end
  end

  return true
end

local function execute_batches(state, command, batches, options)
  local full = result_accumulator(options)
  local bulk_operation_id = operation_id.next()

  for _, batch in ipairs(batches) do
    local response, err = state.executor:command("admin", command, {
      cancellation = options.cancellation,
      deadline = options.deadline,
      max_sequence_document_size = state.max_message_size,
      no_response = not options.acknowledged,
      operation_id = bulk_operation_id,
      retryable_write = batch_is_retryable(batch, options),
      session = options.session,
      session_context = options.session_context,
      sequences = {
        { identifier = "ops", documents = batch.operations },
        { identifier = "nsInfo", documents = batch.namespaces },
      },
    })

    if response == nil then
      local partial_result = full.has_success and accumulated_result(full) or nil

      return nil, command_failure(err, partial_result)
    end

    if options.acknowledged then
      local result
      result, err = result_from(
        state,
        response,
        batch.result_models,
        options
      )

      if result == nil then
        local details = err.details
        local has_write_failures = errors.is(err, errors.CATEGORY.WRITE)
          and details ~= nil
          and (#details.write_errors > 0
            or #details.write_concern_errors > 0)

        if not has_write_failures then
          return nil, err
        end

        merge_batch_failure(full, batch, err)

        if options.ordered and #details.write_errors > 0 then
          break
        end
      else
        merge_successful_batch(full, batch, result)
      end
    end
  end

  if not options.acknowledged then
    return result_value({ acknowledged = false })
  end

  if #full.write_errors > 0 or #full.write_concern_errors > 0 then
    local partial_result = full.has_success and accumulated_result(full) or nil

    return write_failure(
      full.write_errors,
      full.write_concern_errors,
      partial_result,
      full.labels
    )
  end

  return accumulated_result(full)
end

function M.execute(state, models, options)
  if state.max_wire_version < 25 then
    return client_error("client bulk_write requires MongoDB 8.0 or newer")
  end

  local option_err
  options, option_err = validate_options(state, options)

  if options == nil then
    return nil, option_err
  end

  local operations, _, result_models = prepare_models(state, models)

  if operations == nil then
    return nil, result_models
  end

  local entries = {
    { "bulkWrite", 1 },
    { "errorsOnly", not options.verbose_results },
    { "ordered", options.ordered },
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

  if options.let ~= nil then
    entries[#entries + 1] = { "let", options.let }
  end

  if options.raw_data ~= nil and state.max_wire_version >= 27 then
    entries[#entries + 1] = { "rawData", options.raw_data }
  end

  local write_concern = not options.in_transaction
    and concern_document(options.write_concern) or nil

  if write_concern ~= nil then
    entries[#entries + 1] = { "writeConcern", write_concern }
  end

  local command = bson.document(entries)
  local batches, batch_err = create_batches(
    state,
    command,
    operations,
    result_models
  )

  if batches == nil then
    return nil, batch_err
  end

  options.session_context = options.acknowledged
    and options.session == nil
    and type(state.executor.release_session_context) == "function" and {} or nil
  local result
  result, batch_err = execute_batches(state, command, batches, options)

  if options.session_context ~= nil then
    state.executor:release_session_context(options.session_context)
  end

  return result, batch_err
end

return M
