local bson = require("mongodb.bson")
local client_module = require("mongodb.client")
local errors = require("mongodb.error")
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
      observeEvents = true,
      useMultipleMongoses = true,
    }, "$.client")

    if not valid then
      return nil, err
    end

    return client_module.connect(state.uri, { runtime = state.runtime })
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
      { writeConcern = true },
      "$.collection.collectionOptions"
    )

    if not options_valid then
      return nil, err
    end

    local write_concern = collection_options:get("writeConcern")

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

local function insert_one(_, collection, arguments)
  local result, err = collection:insert_one(arguments:get("document"))

  if not result then
    return nil, err
  end

  return bson.document({ { "insertedId", result.inserted_id } })
end

local function operation_options(arguments, fields)
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

  return options
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

local function aggregate(_, collection, arguments)
  local cursor, err = collection:aggregate(arguments:get("pipeline"), operation_options(
    arguments,
    {
      allowDiskUse = "allow_disk_use",
      batchSize = "batch_size",
      collation = "collation",
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
      batchSize = "batch_size",
      collation = "collation",
      limit = "limit",
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
      limit = "limit",
      skip = "skip",
    }
  ))
end

local function estimated_document_count(_, collection, arguments)
  return collection:estimated_document_count(operation_options(arguments, {}))
end

local function distinct(_, collection, arguments)
  return collection:distinct(
    arguments:get("fieldName"),
    arguments:get("filter"),
    operation_options(arguments, { collation = "collation" })
  )
end

local FIND_ONE_OPTIONS = {
  arrayFilters = "array_filters",
  collation = "collation",
  hint = "hint",
  projection = "projection",
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

local function null_result(value)
  return value == nil and bson.null or value
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
    runtime = options.runtime,
    uri = options.uri,
  }
  local lifecycle = lifecycle_module.new({
    environment = options.environment,
    entity_factories = {
      client = client_factory(state),
      collection = collection_factory,
      database = database_factory,
    },
    internal_client = internal_client_adapter(internal_client),
    operations = {
      collection = {
        aggregate = {
          arguments = { "allowDiskUse", "batchSize", "collation", "pipeline" },
          handler = aggregate,
        },
        countDocuments = {
          arguments = { "collation", "filter", "limit", "skip" },
          handler = count_documents,
        },
        distinct = {
          arguments = { "collation", "fieldName", "filter" },
          handler = distinct,
        },
        estimatedDocumentCount = {
          arguments = {},
          handler = estimated_document_count,
        },
        find = {
          arguments = { "batchSize", "collation", "filter", "limit", "skip", "sort" },
          handler = find,
        },
        findOneAndDelete = {
          arguments = { "collation", "filter", "hint", "projection", "sort" },
          coerce_result = null_result,
          handler = find_one_and_delete,
        },
        findOneAndReplace = {
          arguments = {
            "collation", "filter", "hint", "projection", "replacement",
            "returnDocument", "sort", "upsert",
          },
          coerce_result = null_result,
          handler = find_one_and_replace,
        },
        findOneAndUpdate = {
          arguments = {
            "arrayFilters", "collation", "filter", "hint", "projection",
            "returnDocument", "sort", "update", "upsert",
          },
          coerce_result = null_result,
          handler = find_one_and_update,
        },
        insertOne = {
          arguments = { "document" },
          handler = insert_one,
        },
      },
    },
    runtime = options.runtime,
  })

  return lifecycle
end

return M
