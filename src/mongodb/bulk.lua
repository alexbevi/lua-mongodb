local bson = require("mongodb.bson")
local errors = require("mongodb.error")

local M = {}

local MODEL_STATES = setmetatable({}, { __mode = "k" })
local RESULT_STATES = setmetatable({}, { __mode = "k" })
local next_operation_id = 1

local MODEL_METATABLE = {
  __index = function(value, key)
    local state = MODEL_STATES[value]

    if state and key == "kind" then
      return state.kind
    end
  end,
  __metatable = "mongodb.bulk.model",
  __newindex = function()
    error("bulk write models are immutable", 2)
  end,
}

local RESULT_METATABLE = {
  __index = function(value, key)
    local state = RESULT_STATES[value]

    if state then
      return state[key]
    end
  end,
  __metatable = "mongodb.bulk.result",
  __newindex = function()
    error("bulk result values are immutable", 2)
  end,
}

local BULK_OPTIONS = {
  bypass_document_validation = true,
  cancellation = true,
  comment = true,
  deadline = true,
  let = true,
  ordered = true,
  raw_data = true,
}

local INSERT_MANY_OPTIONS = {
  bypass_document_validation = true,
  cancellation = true,
  comment = true,
  deadline = true,
  ordered = true,
  raw_data = true,
}

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

local COMMANDS = {
  delete = { command = "delete", identifier = "deletes" },
  insert = { command = "insert", identifier = "documents" },
  update = { command = "update", identifier = "updates" },
}

local function readonly_table(values, kind)
  local data = {}

  for key, value in pairs(values) do
    data[key] = value
  end

  return setmetatable({}, {
    __index = data,
    __len = function()
      return #data
    end,
    __metatable = "mongodb.bulk." .. kind,
    __newindex = function()
      error("bulk result values are immutable", 2)
    end,
    __pairs = function()
      return next, data, nil
    end,
  })
end

local function result(fields)
  local value = {}

  RESULT_STATES[value] = fields
  return setmetatable(value, RESULT_METATABLE)
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

local function operation_id()
  local value = next_operation_id

  next_operation_id = value == 0x7fffffff and 1 or value + 1
  return value
end

local function code_name(value)
  if type(value) == "string" and value ~= "" then
    return value
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

local function require_document(name, value)
  if not bson.is_document(value) then
    error(name .. " must be a BSON document", 3)
  end
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
    error("replacement document must not begin with an atomic '$' modifier", 3)
  end
end

local function new_model(kind, fields)
  local value = {}

  fields.kind = kind
  MODEL_STATES[value] = fields
  return setmetatable(value, MODEL_METATABLE)
end

local function validate_update_options(options, kind, multi)
  options = validate_options(options, UPDATE_MODEL_OPTIONS, kind)
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

function M.insert_one(document)
  require_document("insert document", document)
  return new_model("insert", { document = document })
end

function M.update_one(filter, update, options)
  require_document("filter", filter)
  require_update(update)
  options = validate_update_options(options, "update_one model", false)
  return new_model("update", {
    filter = filter,
    multi = false,
    options = options,
    update = update,
  })
end

function M.update_many(filter, update, options)
  require_document("filter", filter)
  require_update(update)
  options = validate_update_options(options, "update_many model", true)
  return new_model("update", {
    filter = filter,
    multi = true,
    options = options,
    update = update,
  })
end

function M.replace_one(filter, replacement, options)
  require_document("filter", filter)
  require_replacement(replacement)
  options = validate_options(options, REPLACE_MODEL_OPTIONS, "replace_one model")
  require_boolean(options, "upsert")
  require_document_option(options, "collation")
  require_document_option(options, "sort")
  require_hint(options)
  return new_model("update", {
    filter = filter,
    multi = false,
    options = options,
    replacement = true,
    update = replacement,
  })
end

local function delete_model(filter, options, multi)
  require_document("filter", filter)
  options = validate_options(
    options,
    DELETE_MODEL_OPTIONS,
    multi and "delete_many model" or "delete_one model"
  )
  require_document_option(options, "collation")
  require_hint(options)
  return new_model("delete", {
    filter = filter,
    multi = multi,
    options = options,
  })
end

function M.delete_one(filter, options)
  return delete_model(filter, options, false)
end

function M.delete_many(filter, options)
  return delete_model(filter, options, true)
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

local function model_wire(state, model, original_index)
  local fields = MODEL_STATES[model]

  if not fields then
    error("bulk requests must contain mongodb.bulk write models", 3)
  end

  if fields.kind == "insert" then
    local document, identifier, err = with_generated_id(state, fields.document)

    if not document then
      return nil, err
    end

    return {
      inserted_id = identifier,
      kind = "insert",
      original_index = original_index,
      wire = document,
    }
  end

  local options = fields.options

  if fields.kind == "update" then
    local entries = {
      { "q", fields.filter },
      { "u", fields.update },
      { "multi", fields.multi },
    }

    for _, field in ipairs({
      { "upsert", "upsert" },
      { "array_filters", "arrayFilters" },
      { "collation", "collation" },
      { "hint", "hint" },
      { "sort", "sort" },
    }) do
      if options[field[1]] ~= nil then
        entries[#entries + 1] = { field[2], options[field[1]] }
      end
    end

    return {
      kind = "update",
      original_index = original_index,
      wire = bson.document(entries),
    }
  end

  local entries = {
    { "q", fields.filter },
    { "limit", fields.multi and 0 or 1 },
  }

  for _, name in ipairs({ "collation", "hint" }) do
    if options[name] ~= nil then
      entries[#entries + 1] = { name, options[name] }
    end
  end

  return {
    kind = "delete",
    original_index = original_index,
    wire = bson.document(entries),
  }
end

local function prepare_operations(state, models)
  if type(models) ~= "table" or #models == 0 then
    error("bulk requests must be a non-empty array", 3)
  end

  for key in pairs(models) do
    if math.type(key) ~= "integer" or key < 1 or key > #models then
      error("bulk requests must be a dense array", 3)
    end
  end

  local operations = {}

  for index = 1, #models do
    local operation, err = model_wire(state, models[index], index)

    if not operation then
      return nil, err
    end

    operations[index] = operation
  end

  return operations
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
    entries[#entries + 1] = { "wtimeoutMS", concern.w_timeout_ms }
  end

  if #entries > 0 then
    return bson.document(entries)
  end
end

local function command_for(state, kind, options, force_acknowledged)
  local metadata = COMMANDS[kind]
  local entries = {
    { metadata.command, state.name },
    { "ordered", options.ordered },
  }

  if options.comment ~= nil then
    entries[#entries + 1] = { "comment", options.comment }
  end

  if options.bypass_document_validation ~= nil then
    entries[#entries + 1] = {
      "bypassDocumentValidation",
      options.bypass_document_validation,
    }
  end

  if options.let ~= nil and kind ~= "insert" then
    entries[#entries + 1] = { "let", options.let }
  end

  if options.raw_data ~= nil and state.max_wire_version >= 27 then
    entries[#entries + 1] = { "rawData", options.raw_data }
  end

  local write_concern

  if not force_acknowledged then
    write_concern = concern_document(state.write_concern)
  end

  if write_concern then
    entries[#entries + 1] = { "writeConcern", write_concern }
  end

  return bson.document(entries)
end

local function runs_for(operations, ordered)
  local runs = {}

  if ordered then
    local run

    for _, operation in ipairs(operations) do
      if not run or run.kind ~= operation.kind then
        run = { kind = operation.kind, operations = {} }
        runs[#runs + 1] = run
      end

      run.operations[#run.operations + 1] = operation
    end
  else
    local by_kind = {
      delete = { kind = "delete", operations = {} },
      insert = { kind = "insert", operations = {} },
      update = { kind = "update", operations = {} },
    }

    for _, operation in ipairs(operations) do
      local run = by_kind[operation.kind]

      run.operations[#run.operations + 1] = operation
    end

    for _, kind in ipairs({ "insert", "update", "delete" }) do
      if #by_kind[kind].operations > 0 then
        runs[#runs + 1] = by_kind[kind]
      end
    end
  end

  return runs
end

local function fallback_measure(state, command, identifier, operations)
  local body, err = bson.encode(command, {
    max_binary_size = state.max_message_size,
    max_document_size = state.max_message_size,
    max_string_size = state.max_message_size,
  })

  if not body then
    return nil, err
  end

  local size = 16 + 4 + 1 + #body + 1 + 4 + #identifier + 1

  for _, operation in ipairs(operations) do
    local encoded
    encoded, err = bson.encode(operation.wire, {
      max_binary_size = state.max_message_size,
      max_document_size = state.max_message_size,
      max_string_size = state.max_message_size,
    })

    if not encoded then
      return nil, err
    end

    size = size + #encoded
  end

  if size > state.max_message_size then
    return protocol_error("bulk OP_MSG exceeds maxMessageSizeBytes", {
      max_message_size = state.max_message_size,
      size = size,
    })
  end

  return { message_size = size }
end

local function measure_batch(state, command, identifier, operations)
  local documents = {}

  for index, operation in ipairs(operations) do
    documents[index] = operation.wire
  end

  if type(state.executor.measure) == "function" then
    return state.executor:measure(state.database_name, command, {
      max_sequence_document_size = state.max_message_size,
      sequences = { { identifier = identifier, documents = documents } },
    })
  end

  return fallback_measure(state, command, identifier, operations)
end

local function create_batches(state, operations, options)
  local batches = {}

  for _, run in ipairs(runs_for(operations, options.ordered)) do
    local metadata = COMMANDS[run.kind]
    local command = command_for(state, run.kind, options, false)
    local position = 1

    while position <= #run.operations do
      local batch_operations = {}

      while position <= #run.operations
          and #batch_operations < state.max_write_batch_size
      do
        local candidate = {}

        for index, operation in ipairs(batch_operations) do
          candidate[index] = operation
        end

        candidate[#candidate + 1] = run.operations[position]
        local measured, err = measure_batch(
          state,
          command,
          metadata.identifier,
          candidate
        )

        if not measured then
          if #batch_operations == 0 then
            return nil, err
          end

          break
        end

        batch_operations = candidate
        position = position + 1
      end

      batches[#batches + 1] = {
        command = command,
        identifier = metadata.identifier,
        kind = run.kind,
        operations = batch_operations,
      }
    end
  end

  return batches
end

local function validate_unacknowledged(state, operations, options)
  if state.write_concern.w ~= 0 then
    return true
  end

  if options.bypass_document_validation == true then
    error("bypass_document_validation is unsupported for unacknowledged writes", 3)
  end

  for _, operation in ipairs(operations) do
    local model = MODEL_STATES[operation.model]
    local model_options = model and model.options or {}

    if operation.kind == "insert" or model and model.replacement then
      local document = operation.kind == "insert" and operation.wire or model.update
      local encoded, err = bson.encode(document, {
        max_binary_size = state.max_bson_size,
        max_document_size = state.max_bson_size,
        max_string_size = state.max_bson_size,
      })

      if not encoded then
        return nil, err
      end
    end

    if model_options.collation ~= nil then
      error("collation is unsupported for unacknowledged writes", 3)
    end

    if model_options.array_filters ~= nil then
      error("array_filters is unsupported for unacknowledged writes", 3)
    end

    if model_options.hint ~= nil then
      if operation.kind == "delete" and state.max_wire_version < 9 then
        error("unacknowledged delete hint requires MongoDB 4.4 or newer", 3)
      elseif operation.kind == "update" and state.max_wire_version < 8 then
        error("unacknowledged update hint requires MongoDB 4.2 or newer", 3)
      end
    end

    if model_options.sort ~= nil and state.max_wire_version < 25 then
      error("unacknowledged update sort requires MongoDB 8.0 or newer", 3)
    end
  end

  return true
end

local function count_field(response, name, default)
  local raw = response:get(name)

  if raw == nil and default ~= nil then
    return default
  end

  local value = number_value(raw)

  if math.type(value) ~= "integer" or value < 0 then
    return protocol_error("bulk response contains an invalid " .. name)
  end

  return value
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

local function merge_write_errors(full, batch, response)
  local write_errors = response:get("writeErrors")

  if write_errors == nil then
    return true
  end

  if not bson.is_array(write_errors) then
    return protocol_error("bulk response contains malformed writeErrors")
  end

  for _, item in write_errors:iter() do
    if not bson.is_document(item) then
      return protocol_error("bulk response contains a malformed write error")
    end

    local local_index = number_value(item:get("index"))
    local code = number_value(item:get("code"))

    if math.type(local_index) ~= "integer" or local_index < 0
        or local_index >= #batch.operations
    then
      return protocol_error("bulk response contains an invalid write error index")
    end

    if math.type(code) ~= "integer" then
      return protocol_error("bulk response contains an invalid write error code")
    end

    local message = item:get("errmsg")

    if type(message) ~= "string" or message == "" then
      message = "bulk write failed"
    end

    full.write_errors[#full.write_errors + 1] = {
      code = code,
      code_name = code_name(item:get("codeName")),
      details = item:get("errInfo"),
      index = batch.operations[local_index + 1].original_index,
      message = message,
    }
  end

  return true
end

local function merge_write_concern_error(full, response)
  local item = response:get("writeConcernError")

  if item == nil then
    return true
  end

  if not bson.is_document(item) then
    return protocol_error("bulk response contains a malformed write concern error")
  end

  local code = number_value(item:get("code"))

  if math.type(code) ~= "integer" then
    return protocol_error("bulk response contains an invalid write concern error code")
  end

  local message = item:get("errmsg")

  if type(message) ~= "string" or message == "" then
    message = "bulk write concern failed"
  end

  full.write_concern_errors[#full.write_concern_errors + 1] = {
    code = code,
    code_name = code_name(item:get("codeName")),
    details = item:get("errInfo"),
    message = message,
  }
  return true
end

local function merge_response(full, batch, response)
  local affected, err = count_field(response, "n", 0)

  if affected == nil then
    return nil, err
  end

  if batch.kind == "insert" then
    full.inserted_count = full.inserted_count + affected
  elseif batch.kind == "delete" then
    full.deleted_count = full.deleted_count + affected
  else
    local modified
    modified, err = count_field(response, "nModified", 0)

    if modified == nil then
      return nil, err
    end

    local upserted = response:get("upserted")
    local upserted_count = 0

    if upserted ~= nil then
      if not bson.is_array(upserted) then
        return protocol_error("bulk response contains malformed upserted results")
      end

      for _, item in upserted:iter() do
        if not bson.is_document(item) then
          return protocol_error("bulk response contains a malformed upserted result")
        end

        local local_index = number_value(item:get("index"))

        if math.type(local_index) ~= "integer" or local_index < 0
            or local_index >= #batch.operations or item:get("_id") == nil
        then
          return protocol_error("bulk response contains an invalid upserted result")
        end

        local original_index = batch.operations[local_index + 1].original_index

        full.upserted_ids[original_index] = item:get("_id")
        upserted_count = upserted_count + 1
      end
    end

    full.upserted_count = full.upserted_count + upserted_count

    if affected < upserted_count then
      return protocol_error("bulk response reports more upserts than affected documents")
    end

    full.matched_count = full.matched_count + affected - upserted_count
    full.modified_count = full.modified_count + modified
  end

  local valid
  valid, err = merge_write_errors(full, batch, response)

  if not valid then
    return nil, err
  end

  return merge_write_concern_error(full, response)
end

local function snapshot(full, acknowledged)
  return {
    acknowledged = acknowledged,
    deleted_count = acknowledged and full.deleted_count or nil,
    inserted_count = acknowledged and full.inserted_count or nil,
    matched_count = acknowledged and full.matched_count or nil,
    modified_count = acknowledged and full.modified_count or nil,
    upserted_count = acknowledged and full.upserted_count or nil,
    upserted_ids = acknowledged and full.upserted_ids or nil,
  }
end

local function result_from(full, acknowledged, inserted_ids)
  local fields = snapshot(full, acknowledged)

  if acknowledged then
    fields.upserted_ids = readonly_table(full.upserted_ids, "upserted_ids")

    if inserted_ids then
      fields.inserted_ids = readonly_table(inserted_ids, "inserted_ids")
    end
  end

  return result(fields)
end

local function bulk_error(full, cause, processed, total)
  table.sort(full.write_errors, function(left, right)
    return left.index < right.index
  end)
  local first = full.write_errors[1] or full.write_concern_errors[1]

  return errors.new({
    category = errors.CATEGORY.WRITE,
    cause = cause,
    code = first and first.code or nil,
    code_name = first and first.code_name or nil,
    details = {
      partial_result = snapshot(full, true),
      processed_count = processed,
      responses = full.responses,
      unprocessed_count = total - processed,
      write_concern_errors = full.write_concern_errors,
      write_errors = full.write_errors,
    },
    labels = full.labels,
    message = first and first.message or "bulk write failed",
  })
end

local function execute_batches(state, operations, batches, options, acknowledged)
  local full = {
    deleted_count = 0,
    inserted_count = 0,
    labels = {},
    matched_count = 0,
    modified_count = 0,
    responses = {},
    upserted_count = 0,
    upserted_ids = {},
    write_concern_errors = {},
    write_errors = {},
  }
  local processed = 0
  local bulk_operation_id = operation_id()

  for batch_index, batch in ipairs(batches) do
    local batch_acknowledged = acknowledged

    if not acknowledged and options.ordered then
      batch_acknowledged = batch_index < #batches or #batch.operations > 1
    end

    local command = batch.command

    if batch_acknowledged ~= acknowledged then
      command = command_for(state, batch.kind, options, true)
    end

    local documents = {}

    for index, operation in ipairs(batch.operations) do
      documents[index] = operation.wire
    end

    local response, err = state.executor:command(
      state.database_name,
      command,
      {
        cancellation = options.cancellation,
        deadline = options.deadline,
        no_response = not batch_acknowledged,
        operation_id = bulk_operation_id,
        max_sequence_document_size = state.max_message_size,
        sequences = {
          { identifier = batch.identifier, documents = documents },
        },
      }
    )

    if not response then
      return nil, bulk_error(full, err, processed, #operations)
    end

    if batch_acknowledged then
      full.responses[#full.responses + 1] = response
      for _, label in ipairs(labels_from(response)) do
        full.labels[#full.labels + 1] = label
      end

      local valid
      valid, err = merge_response(full, batch, response)

      if not valid then
        return nil, err
      end

      if options.ordered and #full.write_errors > 0 then
        local first_error = response:get("writeErrors"):get(1)
        local local_index = number_value(first_error:get("index"))

        processed = processed + local_index + 1
        break
      end
    end

    processed = processed + #batch.operations
  end

  if #full.write_errors > 0 or #full.write_concern_errors > 0 then
    return nil, bulk_error(full, nil, processed, #operations)
  end

  return full
end

local function validate_bulk_options(state, operations, options, allowed, kind)
  options = validate_options(options, allowed, kind)
  require_boolean(options, "ordered")
  require_boolean(options, "bypass_document_validation")
  require_boolean(options, "raw_data")
  require_document_option(options, "let")

  if options.ordered == nil then
    options.ordered = true
  end

  local valid, err = validate_unacknowledged(state, operations, options)

  if not valid then
    return nil, err
  end

  return options
end

local function execute(state, models, options, allowed, kind, inserted_ids)
  local operations, err = prepare_operations(state, models)

  if not operations then
    return nil, err
  end

  for index, operation in ipairs(operations) do
    operation.model = models[index]
  end

  options, err = validate_bulk_options(state, operations, options, allowed, kind)

  if not options then
    return nil, err
  end
  local acknowledged = state.write_concern.w ~= 0
  local batches
  batches, err = create_batches(state, operations, options)

  if not batches then
    return nil, err
  end

  local full
  full, err = execute_batches(state, operations, batches, options, acknowledged)

  if not full then
    return nil, err
  end

  return result_from(full, acknowledged, inserted_ids)
end

function M.execute(state, models, options)
  return execute(state, models, options, BULK_OPTIONS, "bulk_write")
end

function M.insert_many(state, documents, options)
  if type(documents) ~= "table" or #documents == 0 then
    error("documents must be a non-empty array", 2)
  end

  for key in pairs(documents) do
    if math.type(key) ~= "integer" or key < 1 or key > #documents then
      error("documents must be a dense array", 2)
    end
  end

  local models = {}
  local inserted_ids = {}

  for index = 1, #documents do
    models[index] = M.insert_one(documents[index])
  end

  local operations, err = prepare_operations(state, models)

  if not operations then
    return nil, err
  end

  for index, operation in ipairs(operations) do
    inserted_ids[index] = operation.inserted_id
    operation.model = models[index]
  end

  options, err = validate_bulk_options(
    state,
    operations,
    options,
    INSERT_MANY_OPTIONS,
    "insert_many"
  )

  if not options then
    return nil, err
  end
  local acknowledged = state.write_concern.w ~= 0
  local batches
  batches, err = create_batches(state, operations, options)

  if not batches then
    return nil, err
  end

  local full
  full, err = execute_batches(state, operations, batches, options, acknowledged)

  if not full then
    return nil, err
  end

  return result_from(full, acknowledged, inserted_ids)
end

return M
