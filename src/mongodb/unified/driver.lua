local bson = require("mongodb.bson")
local bulk = require("mongodb.bulk")
local client_module = require("mongodb.client")
local errors = require("mongodb.error")
local event_module = require("mongodb.unified.events")
local failpoints = require("mongodb.unified.failpoints")
local lifecycle_module = require("mongodb.unified.lifecycle")

local M = {}

local function configuration_error(message, path)
  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    message = message,
    details = { path = path or "$" },
  })
end

local function validate_fields(specification, allowed, path)
  for key in specification:iter() do
    if not allowed[key] then
      return configuration_error(
        "unsupported unified entity field: " .. key,
        path .. "." .. key
      )
    end
  end

  return true
end

local function client_factory(state)
  return function(_, specification)
    local valid, err = validate_fields(specification, {
      id = true,
      ignoreCommandMonitoringEvents = true,
      observeEvents = true,
      observeSensitiveCommands = true,
      uriOptions = true,
      useMultipleMongoses = true,
    }, "$.client")

    if not valid then
      return nil, err
    end

    local collector
    collector, err = event_module.new(specification)

    if not collector then
      return nil, err
    end

    local options = {
      command_listeners = { collector.listener },
      runtime = state.runtime,
    }
    local uri_options = specification:get("uriOptions")

    if uri_options then
      local options_valid
      options_valid, err = validate_fields(uri_options, {
        readConcernLevel = true,
        retryReads = true,
        retryWrites = true,
        w = true,
      }, "$.client.uriOptions")

      if not options_valid then
        return nil, err
      end

      local read_concern = uri_options:get("readConcernLevel")
      local retry_reads = uri_options:get("retryReads")
      local retry_writes = uri_options:get("retryWrites")
      local w = uri_options:get("w")

      if read_concern ~= nil then
        options.read_concern = { level = read_concern }
      end

      if retry_reads ~= nil then
        options.retry_reads = retry_reads
      end

      if retry_writes ~= nil then
        options.retry_writes = retry_writes
      end

      if bson.is_exact(w) then
        w = w:to_number()
      end

      if w ~= nil then
        options.write_concern = { w = w }
      end
    end

    local client
    client, err = client_module.connect(state.uri, options)

    if not client then
      return nil, err
    end

    state.collectors[client] = collector
    return client
  end
end

local function database_factory(runner, specification)
  local valid, err = validate_fields(specification, {
    client = true,
    databaseName = true,
    id = true,
  }, "$.database")

  if not valid then
    return nil, err
  end

  local client
  client, err = runner:get_entity(
    specification:get("client"),
    "client",
    "$.database.client"
  )

  if not client then
    return nil, err
  end

  return client:database(specification:get("databaseName"))
end

local function collection_factory(runner, specification)
  local valid, err = validate_fields(specification, {
    collectionName = true,
    collectionOptions = true,
    database = true,
    id = true,
  }, "$.collection")

  if not valid then
    return nil, err
  end

  local database
  database, err = runner:get_entity(
    specification:get("database"),
    "database",
    "$.collection.database"
  )

  if not database then
    return nil, err
  end

  local options = {}
  local collection_options = specification:get("collectionOptions")

  if collection_options then
    local options_valid
    options_valid, err = validate_fields(
      collection_options,
      { readConcern = true, readPreference = true, writeConcern = true },
      "$.collection.collectionOptions"
    )

    if not options_valid then
      return nil, err
    end

    local write_concern = collection_options:get("writeConcern")
    local read_concern = collection_options:get("readConcern")
    local read_preference = collection_options:get("readPreference")

    if read_concern then
      options.read_concern = { level = read_concern:get("level") }
    end

    if read_preference then
      local max_staleness = read_preference:get("maxStalenessSeconds")

      if bson.is_exact(max_staleness) then
        max_staleness = max_staleness:to_number()
      end

      options.read_preference = {
        max_staleness_seconds = max_staleness,
        mode = read_preference:get("mode"),
      }
    end

    if write_concern then
      local concern_valid
      concern_valid, err = validate_fields(
        write_concern,
        { w = true },
        "$.collection.collectionOptions.writeConcern"
      )

      if not concern_valid then
        return nil, err
      end

      local w = write_concern:get("w")

      if bson.is_exact(w) then
        w = w:to_number()
      end

      options.write_concern = { w = w }
    end
  end

  return database:collection(specification:get("collectionName"), options)
end

local function session_factory(runner, specification)
  local valid, err = validate_fields(specification, {
    client = true,
    id = true,
    sessionOptions = true,
  }, "$.session")

  if not valid then
    return nil, err
  end

  local client
  client, err = runner:get_entity(
    specification:get("client"),
    "client",
    "$.session.client"
  )

  if not client then
    return nil, err
  end

  local options = {}
  local session_options = specification:get("sessionOptions")

  if session_options then
    valid, err = validate_fields(
      session_options,
      { causalConsistency = true },
      "$.session.sessionOptions"
    )

    if not valid then
      return nil, err
    end

    options.causal_consistency = session_options:get("causalConsistency")
  end

  return client:start_session(options)
end

local call_driver
local operation_options

local function insert_one(_, collection, arguments)
  local result, err = call_driver(function()
    return collection:insert_one(arguments:get("document"), operation_options(
      arguments,
      {
        bypassDocumentValidation = "bypass_document_validation",
        comment = "comment",
        rawData = "raw_data",
      }
    ))
  end)

  if not result then
    return nil, err
  end

  if not result.acknowledged then
    return bson.document({ { "acknowledged", false } })
  end

  return bson.document({ { "insertedId", result.inserted_id } })
end

operation_options = function(arguments, fields)
  local options = {}

  for unified_name, lua_name in pairs(fields) do
    local value = arguments:get(unified_name)

    if value ~= nil then
      if bson.is_exact(value) then
        value = value:to_number()
      elseif unified_name == "returnDocument" then
        value = value:lower()
      end

      options[lua_name] = value
    end
  end

  if arguments:get("session") ~= nil then
    options.session = arguments:get("session")
  end

  return options
end

local function end_session(_, session)
  return session:end_session()
end

local function assert_session_dirty(expected)
  return function(runner, arguments, path)
    local session, err = runner:get_entity(
      arguments:get("session"),
      "session",
      path .. ".arguments.session"
    )

    if not session then
      return nil, err
    end

    if session:is_dirty() ~= expected then
      return configuration_error(
        expected and "session is not dirty" or "session is dirty",
        path
      )
    end

    return true
  end
end

local function assert_last_lsids(state, expected_same)
  return function(runner, arguments, path)
    local client, err = runner:get_entity(
      arguments:get("client"),
      "client",
      path .. ".arguments.client"
    )

    if not client then
      return nil, err
    end

    local collector = state.collectors[client]
    local lsids = {}

    for _, event in ipairs(collector and collector.events or {}) do
      if event.type == "command_started" then
        local lsid = event.command:get("lsid")

        if lsid then
          lsids[#lsids + 1] = assert(bson.encode(lsid))
        end
      end
    end

    if #lsids < 2 or (lsids[#lsids - 1] == lsids[#lsids]) ~= expected_same then
      return configuration_error(
        expected_same and "last two commands have different lsids"
          or "last two commands have the same lsid",
        path
      )
    end

    return true
  end
end

local function collect_cursor(cursor)
  local documents = {}

  while true do
    local document, err = cursor:next()

    if document == nil then
      local closed, close_err = cursor:close()

      if err then
        return nil, err
      end

      if closed == nil then
        return nil, close_err
      end

      return bson.array(documents)
    end

    documents[#documents + 1] = document
  end
end

local function list_databases(_, client, arguments)
  local cursor, err = client:list_databases(operation_options(arguments, {
    filter = "filter",
  }))

  if not cursor then
    return nil, err
  end

  return collect_cursor(cursor)
end

local function list_database_names(_, client, arguments)
  return client:list_database_names(operation_options(arguments, {
    filter = "filter",
  }))
end

local function list_collections(_, database, arguments)
  local cursor, err = database:list_collections(operation_options(arguments, {
    filter = "filter",
  }))

  if not cursor then
    return nil, err
  end

  return collect_cursor(cursor)
end

local function list_collection_names(_, database, arguments)
  return database:list_collection_names(operation_options(arguments, {
    filter = "filter",
  }))
end

local function list_indexes(_, collection)
  local cursor, err = collection:list_indexes()

  if not cursor then
    return nil, err
  end

  return collect_cursor(cursor)
end

local function list_index_names(_, collection)
  local documents, err = list_indexes(nil, collection)

  if not documents then
    return nil, err
  end

  local names = {}

  for index, document in documents:iter() do
    names[index] = document:get("name")
  end

  return bson.array(names)
end

local function aggregate(_, collection, arguments)
  local cursor, err = collection:aggregate(arguments:get("pipeline"), operation_options(
    arguments,
    {
      allowDiskUse = "allow_disk_use",
      batchSize = "batch_size",
      bypassDocumentValidation = "bypass_document_validation",
      collation = "collation",
      comment = "comment",
      hint = "hint",
      let = "let",
      maxTimeMS = "max_time_ms",
      rawData = "raw_data",
    }
  ))

  if not cursor then
    return nil, err
  end

  return collect_cursor(cursor)
end

local function find(_, collection, arguments)
  local cursor, err = collection:find(arguments:get("filter"), operation_options(
    arguments,
    {
      allowDiskUse = "allow_disk_use",
      batchSize = "batch_size",
      collation = "collation",
      comment = "comment",
      hint = "hint",
      let = "let",
      limit = "limit",
      maxTimeMS = "max_time_ms",
      projection = "projection",
      rawData = "raw_data",
      skip = "skip",
      sort = "sort",
    }
  ))

  if not cursor then
    return nil, err
  end

  return collect_cursor(cursor)
end

local function count_documents(_, collection, arguments)
  return collection:count_documents(arguments:get("filter"), operation_options(
    arguments,
    {
      collation = "collation",
      comment = "comment",
      hint = "hint",
      limit = "limit",
      maxTimeMS = "max_time_ms",
      rawData = "raw_data",
      skip = "skip",
    }
  ))
end

local function estimated_document_count(_, collection, arguments)
  return collection:estimated_document_count(operation_options(arguments, {
    comment = "comment",
    maxTimeMS = "max_time_ms",
    rawData = "raw_data",
  }))
end

local function distinct(_, collection, arguments)
  return collection:distinct(
    arguments:get("fieldName"),
    arguments:get("filter"),
    operation_options(arguments, {
      collation = "collation",
      comment = "comment",
      hint = "hint",
      maxTimeMS = "max_time_ms",
      rawData = "raw_data",
    })
  )
end

local FIND_ONE_OPTIONS = {
  arrayFilters = "array_filters",
  bypassDocumentValidation = "bypass_document_validation",
  collation = "collation",
  comment = "comment",
  hint = "hint",
  let = "let",
  maxTimeMS = "max_time_ms",
  projection = "projection",
  rawData = "raw_data",
  returnDocument = "return_document",
  sort = "sort",
  upsert = "upsert",
}

local function find_one_and_delete(_, collection, arguments)
  return collection:find_one_and_delete(
    arguments:get("filter"),
    operation_options(arguments, FIND_ONE_OPTIONS)
  )
end

local function find_one_and_replace(_, collection, arguments)
  return collection:find_one_and_replace(
    arguments:get("filter"),
    arguments:get("replacement"),
    operation_options(arguments, FIND_ONE_OPTIONS)
  )
end

local function find_one_and_update(_, collection, arguments)
  return collection:find_one_and_update(
    arguments:get("filter"),
    arguments:get("update"),
    operation_options(arguments, FIND_ONE_OPTIONS)
  )
end

local function find_one(_, collection, arguments)
  return collection:find_one(
    arguments:get("filter"),
    operation_options(arguments, {
      collation = "collation",
      comment = "comment",
      hint = "hint",
      let = "let",
      maxTimeMS = "max_time_ms",
      projection = "projection",
      rawData = "raw_data",
      skip = "skip",
      sort = "sort",
    })
  )
end

local function null_result(value)
  return value == nil and bson.null or value
end

call_driver = function(callback)
  local outcome = table.pack(pcall(callback))

  if not outcome[1] then
    return configuration_error(tostring(outcome[2]), "$.arguments")
  end

  return table.unpack(outcome, 2, outcome.n)
end

local function array_values(value)
  local values = {}

  for index, item in value:iter() do
    values[index] = item
  end

  return values
end

local WRITE_OPTIONS = {
  arrayFilters = "array_filters",
  bypassDocumentValidation = "bypass_document_validation",
  collation = "collation",
  comment = "comment",
  hint = "hint",
  let = "let",
  ordered = "ordered",
  rawData = "raw_data",
  sort = "sort",
  upsert = "upsert",
}

local function insert_many(_, collection, arguments)
  return call_driver(function()
    return collection:insert_many(
      array_values(arguments:get("documents")),
      operation_options(arguments, WRITE_OPTIONS)
    )
  end)
end

local function update_one(_, collection, arguments)
  return call_driver(function()
    return collection:update_one(
      arguments:get("filter"),
      arguments:get("update"),
      operation_options(arguments, WRITE_OPTIONS)
    )
  end)
end

local function update_many(_, collection, arguments)
  return call_driver(function()
    return collection:update_many(
      arguments:get("filter"),
      arguments:get("update"),
      operation_options(arguments, WRITE_OPTIONS)
    )
  end)
end

local function replace_one(_, collection, arguments)
  return call_driver(function()
    return collection:replace_one(
      arguments:get("filter"),
      arguments:get("replacement"),
      operation_options(arguments, WRITE_OPTIONS)
    )
  end)
end

local function delete_one(_, collection, arguments)
  return call_driver(function()
    return collection:delete_one(
      arguments:get("filter"),
      operation_options(arguments, WRITE_OPTIONS)
    )
  end)
end

local function delete_many(_, collection, arguments)
  return call_driver(function()
    return collection:delete_many(
      arguments:get("filter"),
      operation_options(arguments, WRITE_OPTIONS)
    )
  end)
end

local MODEL_FACTORIES = {
  deleteMany = function(arguments)
    return bulk.delete_many(
      arguments:get("filter"),
      operation_options(arguments, WRITE_OPTIONS)
    )
  end,
  deleteOne = function(arguments)
    return bulk.delete_one(
      arguments:get("filter"),
      operation_options(arguments, WRITE_OPTIONS)
    )
  end,
  insertOne = function(arguments)
    return bulk.insert_one(arguments:get("document"))
  end,
  replaceOne = function(arguments)
    return bulk.replace_one(
      arguments:get("filter"),
      arguments:get("replacement"),
      operation_options(arguments, WRITE_OPTIONS)
    )
  end,
  updateMany = function(arguments)
    return bulk.update_many(
      arguments:get("filter"),
      arguments:get("update"),
      operation_options(arguments, WRITE_OPTIONS)
    )
  end,
  updateOne = function(arguments)
    return bulk.update_one(
      arguments:get("filter"),
      arguments:get("update"),
      operation_options(arguments, WRITE_OPTIONS)
    )
  end,
}

local function bulk_write(_, collection, arguments)
  return call_driver(function()
    local models = {}

    for index, request in arguments:get("requests"):iter() do
      if not bson.is_document(request) or #request ~= 1 then
        error("bulkWrite requests must contain exactly one write model", 0)
      end

      local name, model_arguments = request:get_at(1)
      local factory = MODEL_FACTORIES[name]

      if not factory then
        error("unsupported unified bulkWrite model: " .. tostring(name), 0)
      end

      models[index] = factory(model_arguments)
    end

    return collection:bulk_write(
      models,
      operation_options(arguments, {
        bypassDocumentValidation = "bypass_document_validation",
        comment = "comment",
        let = "let",
        ordered = "ordered",
        rawData = "raw_data",
      })
    )
  end)
end

local function indexed_ids(values)
  local entries = {}

  for index, value in pairs(values or {}) do
    entries[#entries + 1] = { tostring(index - 1), value }
  end

  table.sort(entries, function(left, right)
    return tonumber(left[1]) < tonumber(right[1])
  end)
  return bson.document(entries)
end

local function insert_many_result(value)
  if not value.acknowledged then
    return bson.document({ { "acknowledged", false } })
  end

  return bson.document({ { "insertedIds", indexed_ids(value.inserted_ids) } })
end

local function update_result(value)
  if not value.acknowledged then
    return bson.document({ { "acknowledged", false } })
  end

  local entries = {
    { "matchedCount", value.matched_count },
    { "modifiedCount", value.modified_count },
    { "upsertedCount", value.upserted_count },
  }

  if value.upserted_id ~= nil then
    entries[#entries + 1] = { "upsertedId", value.upserted_id }
  end

  return bson.document(entries)
end

local function delete_result(value)
  if not value.acknowledged then
    return bson.document({ { "acknowledged", false } })
  end

  return bson.document({ { "deletedCount", value.deleted_count } })
end

local function bulk_result(value)
  if not value.acknowledged then
    return bson.document({ { "acknowledged", false } })
  end

  local entries = {
    { "deletedCount", value.deleted_count },
    { "insertedCount", value.inserted_count },
    { "matchedCount", value.matched_count },
    { "modifiedCount", value.modified_count },
    { "upsertedCount", value.upserted_count },
    { "upsertedIds", indexed_ids(value.upserted_ids) },
  }

  if value.inserted_ids ~= nil then
    entries[#entries + 1] = { "insertedIds", indexed_ids(value.inserted_ids) }
  end

  return bson.document(entries)
end

local function internal_client_adapter(client)
  local adapter = {}

  function adapter.setup_initial_data(_, initial_data)
    for index, specification in initial_data:iter() do
      local database_name = specification:get("databaseName")
      local collection_name = specification:get("collectionName")
      local create_options = specification:get("createOptions")

      if create_options and #create_options > 0 then
        return configuration_error(
          "createOptions are not supported by the first unified CRUD adapter",
          "$.initialData[" .. index .. "].createOptions"
        )
      end

      local database, err = client:database(database_name, {
        write_concern = { w = "majority" },
      })

      if not database then
        return nil, err
      end

      local dropped
      dropped, err = database:drop_collection(collection_name)

      if not dropped then
        return nil, err
      end

      local documents = specification:get("documents")

      if #documents > 0 then
        local values = {}

        for document_index, document in documents:iter() do
          values[document_index] = document
        end

        local collection
        collection, err = database:collection(collection_name)

        if not collection then
          return nil, err
        end

        local inserted
        inserted, err = collection:insert_many(values)

        if not inserted then
          return nil, err
        end
      else
        local created
        created, err = database:create_collection(collection_name)

        if not created then
          return nil, err
        end
      end
    end

    return true
  end

  function adapter.read_outcome(_, specification)
    local database, err = client:database(specification:get("databaseName"), {
      read_concern = { level = "local" },
      read_preference = { mode = "primary" },
    })

    if not database then
      return nil, err
    end

    local collection
    collection, err = database:collection(specification:get("collectionName"))

    if not collection then
      return nil, err
    end

    local cursor
    cursor, err = collection:find(bson.document({}), {
      sort = bson.document({ { "_id", 1 } }),
    })

    if not cursor then
      return nil, err
    end

    local documents = {}

    while true do
      local document
      document, err = cursor:next()

      if document == nil then
        cursor:close()

        if err then
          return nil, err
        end

        break
      end

      documents[#documents + 1] = document
    end

    return bson.array(documents)
  end

  function adapter.close()
    return client:close()
  end

  return adapter
end

function M.new(options)
  options = options or {}

  if type(options) ~= "table" then
    error("unified driver options must be a table", 2)
  end

  if type(options.uri) ~= "string" or options.uri == "" then
    error("unified driver requires a URI", 2)
  end

  local internal_client, err = client_module.connect(options.uri, {
    runtime = options.runtime,
  })

  if not internal_client then
    return nil, err
  end

  local state = {
    collectors = setmetatable({}, { __mode = "k" }),
    runtime = options.runtime,
    uri = options.uri,
  }
  local failpoint_handler = failpoints.new({
    cleanup_database = function()
      local cleanup_client, cleanup_err = client_module.connect(state.uri, {
        runtime = state.runtime,
      })

      if not cleanup_client then
        return nil, cleanup_err
      end

      local cleanup_database
      cleanup_database, cleanup_err = cleanup_client:database("admin")

      if not cleanup_database then
        cleanup_client:close()
        return nil, cleanup_err
      end

      return cleanup_database, function()
        return cleanup_client:close()
      end
    end,
  })
  local lifecycle = lifecycle_module.new({
    assert_events = function(runner, expected, path)
      return event_module.assert_all(runner, expected, state.collectors, path)
    end,
    environment = options.environment,
    entity_factories = {
      client = client_factory(state),
      collection = collection_factory,
      database = database_factory,
      session = session_factory,
    },
    internal_client = internal_client_adapter(internal_client),
    operations = {
      client = {
        listDatabaseNames = {
          arguments = { "filter" },
          handler = list_database_names,
        },
        listDatabaseObjects = {
          arguments = { "filter" },
          handler = list_databases,
        },
        listDatabases = {
          arguments = { "filter" },
          handler = list_databases,
        },
      },
      collection = {
        aggregate = {
          arguments = {
            "allowDiskUse", "batchSize", "bypassDocumentValidation", "collation",
            "comment", "hint", "let", "maxTimeMS", "pipeline", "rawData",
          },
          handler = aggregate,
        },
        countDocuments = {
          arguments = {
            "collation", "comment", "filter", "hint", "limit", "maxTimeMS",
            "rawData", "skip",
          },
          handler = count_documents,
        },
        distinct = {
          arguments = {
            "collation", "comment", "fieldName", "filter", "hint", "maxTimeMS",
            "rawData",
          },
          handler = distinct,
        },
        estimatedDocumentCount = {
          arguments = { "comment", "maxTimeMS", "rawData" },
          handler = estimated_document_count,
        },
        find = {
          arguments = {
            "allowDiskUse", "batchSize", "collation", "comment", "filter", "hint",
            "let", "limit", "maxTimeMS", "projection", "rawData", "skip", "sort",
          },
          handler = find,
        },
        findOne = {
          arguments = {
            "collation", "comment", "filter", "hint", "let", "maxTimeMS",
            "projection", "rawData", "skip", "sort",
          },
          coerce_result = null_result,
          handler = find_one,
        },
        findOneAndDelete = {
          arguments = {
            "collation", "comment", "filter", "hint", "let", "maxTimeMS",
            "projection", "rawData", "sort",
          },
          coerce_result = null_result,
          handler = find_one_and_delete,
        },
        findOneAndReplace = {
          arguments = {
            "bypassDocumentValidation", "collation", "comment", "filter", "hint",
            "let", "maxTimeMS", "projection", "rawData", "replacement",
            "returnDocument", "sort", "upsert",
          },
          coerce_result = null_result,
          handler = find_one_and_replace,
        },
        findOneAndUpdate = {
          arguments = {
            "arrayFilters", "bypassDocumentValidation", "collation", "comment",
            "filter", "hint", "let", "maxTimeMS", "projection", "rawData",
            "returnDocument", "sort", "update", "upsert",
          },
          coerce_result = null_result,
          handler = find_one_and_update,
        },
        bulkWrite = {
          arguments = {
            "bypassDocumentValidation", "comment", "let", "ordered", "rawData",
            "requests",
          },
          coerce_result = bulk_result,
          handler = bulk_write,
        },
        deleteMany = {
          arguments = { "collation", "comment", "filter", "hint", "let", "rawData" },
          coerce_result = delete_result,
          handler = delete_many,
        },
        deleteOne = {
          arguments = { "collation", "comment", "filter", "hint", "let", "rawData" },
          coerce_result = delete_result,
          handler = delete_one,
        },
        insertMany = {
          arguments = {
            "bypassDocumentValidation", "comment", "documents", "ordered", "rawData",
          },
          coerce_result = insert_many_result,
          handler = insert_many,
        },
        insertOne = {
          arguments = { "bypassDocumentValidation", "comment", "document", "rawData" },
          handler = insert_one,
        },
        listIndexNames = {
          arguments = {},
          handler = list_index_names,
        },
        listIndexes = {
          arguments = {},
          handler = list_indexes,
        },
        replaceOne = {
          arguments = {
            "bypassDocumentValidation", "collation", "comment", "filter", "hint",
            "let", "rawData", "replacement", "sort", "upsert",
          },
          coerce_result = update_result,
          handler = replace_one,
        },
        updateMany = {
          arguments = {
            "arrayFilters", "bypassDocumentValidation", "collation", "comment",
            "filter", "hint", "let", "rawData", "update", "upsert",
          },
          coerce_result = update_result,
          handler = update_many,
        },
        updateOne = {
          arguments = {
            "arrayFilters", "bypassDocumentValidation", "collation", "comment",
            "filter", "hint", "let", "rawData", "sort", "update", "upsert",
          },
          coerce_result = update_result,
          handler = update_one,
        },
      },
      database = {
        listCollectionNames = {
          arguments = { "filter" },
          handler = list_collection_names,
        },
        listCollectionObjects = {
          arguments = { "filter" },
          handler = list_collections,
        },
        listCollections = {
          arguments = { "filter" },
          handler = list_collections,
        },
      },
      session = {
        endSession = {
          arguments = {},
          handler = end_session,
        },
      },
    },
    runtime = options.runtime,
    test_operations = {
      assertDifferentLsidOnLastTwoCommands = assert_last_lsids(state, false),
      assertSameLsidOnLastTwoCommands = assert_last_lsids(state, true),
      assertSessionDirty = assert_session_dirty(true),
      assertSessionNotDirty = assert_session_dirty(false),
      failPoint = failpoint_handler,
    },
  })

  return lifecycle
end

return M
