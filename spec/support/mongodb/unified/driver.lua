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
  local function create_client(_, specification)
    local valid, err = validate_fields(specification, {
      id = true,
      awaitMinPoolSizeMS = true,
      ignoreCommandMonitoringEvents = true,
      observeEvents = true,
      observeSensitiveCommands = true,
      serverApi = true,
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
      pool_listeners = { collector.pool_listener },
      runtime = state.runtime,
    }

    if collector:observes_heartbeat() then
      options.heartbeat_listeners = { collector.heartbeat_listener }
    end

    if collector:observes_sdam() or state.environment_topology == "replicaset" then
      options.sdam_listeners = { collector.sdam_listener }
    end

    local server_api = specification:get("serverApi")

    if server_api then
      local api_valid
      api_valid, err = validate_fields(server_api, {
        deprecationErrors = true,
        strict = true,
        version = true,
      }, "$.client.serverApi")

      if not api_valid then
        return nil, err
      end

      options.server_api = {
        deprecation_errors = server_api:get("deprecationErrors"),
        strict = server_api:get("strict"),
        version = server_api:get("version"),
      }
    end
    local uri_options = specification:get("uriOptions")

    if uri_options then
      local options_valid
      options_valid, err = validate_fields(uri_options, {
        authMechanism = true,
        authMechanismProperties = true,
        readConcernLevel = true,
        readPreference = true,
        appName = true,
        appname = true,
        connectTimeoutMS = true,
        heartbeatFrequencyMS = true,
        maxConnecting = true,
        maxPoolSize = true,
        minPoolSize = true,
        retryReads = true,
        retryWrites = true,
        serverMonitoringMode = true,
        serverSelectionTimeoutMS = true,
        socketTimeoutMS = true,
        timeoutMS = true,
        w = true,
        wTimeoutMS = true,
        waitQueueTimeoutMS = true,
      }, "$.client.uriOptions")

      if not options_valid then
        return nil, err
      end

      local read_concern = uri_options:get("readConcernLevel")
      local retry_reads = uri_options:get("retryReads")
      local retry_writes = uri_options:get("retryWrites")
      local w = uri_options:get("w")
      local socket_timeout_ms = uri_options:get("socketTimeoutMS")
      local timeout_ms = uri_options:get("timeoutMS")
      local w_timeout_ms = uri_options:get("wTimeoutMS")

      if read_concern ~= nil then
        options.read_concern = { level = read_concern }
      end

      if uri_options:get("readPreference") ~= nil then
        options.read_preference = { mode = uri_options:get("readPreference") }
      end

      if retry_reads ~= nil then
        options.retry_reads = retry_reads
      end

      if retry_writes ~= nil then
        options.retry_writes = retry_writes
      end

      if bson.is_exact(socket_timeout_ms) then
        socket_timeout_ms = socket_timeout_ms:to_number()
      end

      if socket_timeout_ms ~= nil then
        options.socket_timeout_ms = socket_timeout_ms
      end

      if bson.is_exact(timeout_ms) then
        timeout_ms = timeout_ms:to_number()
      end

      if timeout_ms ~= nil then
        options.timeout_ms = timeout_ms
      end

      for unified_name, lua_name in pairs({
        connectTimeoutMS = "connect_timeout_ms",
        heartbeatFrequencyMS = "heartbeat_frequency_ms",
        maxConnecting = "max_connecting",
        maxPoolSize = "max_pool_size",
        minPoolSize = "min_pool_size",
        serverMonitoringMode = "server_monitoring_mode",
        serverSelectionTimeoutMS = "server_selection_timeout_ms",
        waitQueueTimeoutMS = "wait_queue_timeout_ms",
      }) do
        local value = uri_options:get(unified_name)

        if bson.is_exact(value) then
          value = value:to_number()
        end

        if value ~= nil then
          options[lua_name] = value
        end
      end

      options.app_name = uri_options:get("appName") or uri_options:get("appname")

      local auth_mechanism = uri_options:get("authMechanism")
      local auth_properties = uri_options:get("authMechanismProperties")

      if auth_mechanism ~= nil then
        options.auth_mechanism = auth_mechanism
      end

      if auth_properties ~= nil then
        local properties_valid
        properties_valid, err = validate_fields(auth_properties, {
          ["$$placeholder"] = true,
        }, "$.client.uriOptions.authMechanismProperties")

        if not properties_valid then
          return nil, err
        end

        if auth_mechanism ~= "MONGODB-OIDC"
            or auth_properties:get("$$placeholder") == nil
            or type(state.oidc_callback) ~= "function"
        then
          return configuration_error(
            "unsupported unified authentication mechanism properties",
            "$.client.uriOptions.authMechanismProperties"
          )
        end

        options.auth_mechanism_properties = {
          OIDC_CALLBACK = state.oidc_callback,
        }
      end

      if bson.is_exact(w) then
        w = w:to_number()
      end

      if bson.is_exact(w_timeout_ms) then
        w_timeout_ms = w_timeout_ms:to_number()
      end

      if w ~= nil or w_timeout_ms ~= nil then
        options.write_concern = { w = w, w_timeout_ms = w_timeout_ms }
      end
    end

    local uri = state.uri

    if specification:get("useMultipleMongoses") == true then
      uri = state.multiple_mongos_uri

      if type(uri) ~= "string" or uri == "" then
        return configuration_error(
          "multiple mongos URI is unavailable",
          "$.client.useMultipleMongoses"
        )
      end
    end

    local client
    client, err = client_module.connect(uri, options)

    if not client then
      return nil, err
    end

    local await_min_pool_size_ms = specification:get("awaitMinPoolSizeMS")

    if bson.is_exact(await_min_pool_size_ms) then
      await_min_pool_size_ms = await_min_pool_size_ms:to_number()
    end

    if await_min_pool_size_ms ~= nil
        and (math.type(await_min_pool_size_ms) ~= "integer"
          or await_min_pool_size_ms < 0)
    then
      client:close()
      return configuration_error(
        "awaitMinPoolSizeMS must be a non-negative integer",
        "$.client.awaitMinPoolSizeMS"
      )
    end

    local min_pool_size = options.min_pool_size or 0

    if await_min_pool_size_ms ~= nil and min_pool_size > 0 then
      local deadline = state.runtime.clock:now() + await_min_pool_size_ms / 1000

      while not collector:pools_populated(min_pool_size) do
        local remaining = deadline - state.runtime.clock:now()

        if remaining <= 0 then
          client:close()
          return configuration_error(
            "connection pools did not reach minPoolSize before awaitMinPoolSizeMS",
            "$.client.awaitMinPoolSizeMS"
          )
        end

        local slept
        slept, err = state.runtime.clock:sleep(math.min(remaining, 0.01))

        if not slept then
          client:close()
          return nil, err
        end
      end

      collector:reset()
    end

    collector:discard_type("connection_checkout_started")
    state.collectors[client] = collector
    return client
  end

  return create_client
end

local function database_factory(runner, specification)
  local valid, err = validate_fields(specification, {
    client = true,
    databaseOptions = true,
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

  local options = {}
  local database_options = specification:get("databaseOptions")

  if database_options then
    local read_concern = database_options:get("readConcern")
    local read_preference = database_options:get("readPreference")
    local write_concern = database_options:get("writeConcern")
    local timeout_ms = database_options:get("timeoutMS")

    if read_concern then
      options.read_concern = { level = read_concern:get("level") }
    end

    if read_preference then
      options.read_preference = { mode = read_preference:get("mode") }
    end

    if write_concern then
      local w = write_concern:get("w")
      options.write_concern = { w = bson.is_exact(w) and w:to_number() or w }
    end


    if bson.is_exact(timeout_ms) then
      timeout_ms = timeout_ms:to_number()
    end

    options.timeout_ms = timeout_ms
  end

  return client:database(specification:get("databaseName"), options)
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
      {
        readConcern = true,
        readPreference = true,
        timeoutMS = true,
        writeConcern = true,
      },
      "$.collection.collectionOptions"
    )

    if not options_valid then
      return nil, err
    end

    local write_concern = collection_options:get("writeConcern")
    local read_concern = collection_options:get("readConcern")
    local read_preference = collection_options:get("readPreference")
    local timeout_ms = collection_options:get("timeoutMS")

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


    if bson.is_exact(timeout_ms) then
      timeout_ms = timeout_ms:to_number()
    end

    options.timeout_ms = timeout_ms
  end

  return database:collection(specification:get("collectionName"), options)
end

local function session_factory(state)
  return function(runner, specification)
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
        {
          causalConsistency = true,
          defaultTimeoutMS = true,
          defaultTransactionOptions = true,
          snapshot = true,
          snapshotTime = true,
        },
        "$.session.sessionOptions"
      )

      if not valid then
        return nil, err
      end

      options.causal_consistency = session_options:get("causalConsistency")
      options.snapshot = session_options:get("snapshot")
      local snapshot_time = session_options:get("snapshotTime")

      if type(snapshot_time) == "string" then
        snapshot_time, err = runner:get_entity(
          snapshot_time,
          "bson",
          "$.session.sessionOptions.snapshotTime"
        )

        if snapshot_time == nil then
          return nil, err
        end
      end

      options.snapshot_time = snapshot_time
      local default_timeout_ms = session_options:get("defaultTimeoutMS")

      if bson.is_exact(default_timeout_ms) then
        default_timeout_ms = default_timeout_ms:to_number()
      end

      options.timeout_ms = default_timeout_ms
      local defaults = session_options:get("defaultTransactionOptions")

      if defaults then
        local max_commit_time_ms = defaults:get("maxCommitTimeMS")

        if bson.is_exact(max_commit_time_ms) then
          max_commit_time_ms = max_commit_time_ms:to_number()
        end

        options.default_transaction_options = {
          max_commit_time_ms = max_commit_time_ms,
          read_concern = defaults:get("readConcern"),
          read_preference = defaults:get("readPreference"),
          write_concern = defaults:get("writeConcern"),
        }
      end
    end

    local session
    session, err = client:start_session(options)

    if session then
      if state.initial_cluster_time ~= nil then
        local advanced

        advanced, err = session:advance_cluster_time(
          state.initial_cluster_time
        )

        if not advanced then
          session:end_session()
          return nil, err
        end
      end

      state.session_clients[session] = client
    end

    return session, err
  end
end

local call_driver
local operation_options

local function convert_read_preference(value)
  if not bson.is_document(value) then
    return value
  end

  local max_staleness = value:get("maxStalenessSeconds")

  if bson.is_exact(max_staleness) then
    max_staleness = max_staleness:to_number()
  end

  local tag_sets = {}
  local tags = value:get("tagSets")

  if bson.is_array(tags) then
    for index, tag_set in tags:iter() do
      local converted = {}

      if bson.is_document(tag_set) then
        for key, item in tag_set:iter() do
          converted[key] = item
        end
      end

      tag_sets[index] = converted
    end
  end

  return {
    max_staleness_seconds = max_staleness,
    mode = value:get("mode"),
    tag_sets = #tag_sets > 0 and tag_sets or nil,
  }
end

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

  fields.timeoutMS = fields.timeoutMS or "timeout_ms"
  fields.timeoutMode = fields.timeoutMode or "timeout_mode"

  for unified_name, lua_name in pairs(fields) do
    local value = arguments:get(unified_name)

    if value ~= nil then
      if bson.is_exact(value) then
        value = value:to_number()
      elseif unified_name == "returnDocument" then
        value = value:lower()
      elseif unified_name == "timeoutMode" then
        value = value == "cursorLifetime" and "cursor_lifetime"
          or value == "iteration" and "iteration" or value
      elseif unified_name == "cursorType" then
        value = value == "nonTailable" and "non_tailable"
          or value == "tailableAwait" and "tailable_await" or value
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

local function get_snapshot_time(_, session)
  return session:get_snapshot_time()
end

local function transaction_options(arguments)
  local options = {}
  local read_concern = arguments:get("readConcern")
  local write_concern = arguments:get("writeConcern")
  local max_commit_time = arguments:get("maxCommitTimeMS")
  local read_preference = arguments:get("readPreference")

  if read_concern then
    options.read_concern = read_concern
  end

  if write_concern then
    options.write_concern = write_concern
  end

  if read_preference then
    options.read_preference = read_preference
  end

  if bson.is_exact(max_commit_time) then
    max_commit_time = max_commit_time:to_number()
  end

  options.max_commit_time_ms = max_commit_time
  local timeout_ms = arguments:get("timeoutMS")

  if bson.is_exact(timeout_ms) then
    timeout_ms = timeout_ms:to_number()
  end

  options.timeout_ms = timeout_ms
  return options
end

local function start_transaction(_, session, arguments)
  local options = transaction_options(arguments)

  return session:start_transaction(options)
end

local function with_transaction(runner, session, arguments, _, path)
  local callback = arguments:get("callback")

  return session:with_transaction(function()
    return runner:execute_all(callback, path .. ".arguments.callback", true)
  end, transaction_options(arguments))
end

local function commit_transaction(_, session, arguments)
  return session:commit_transaction(operation_options(arguments, {}))
end

local function abort_transaction(_, session, arguments)
  return session:abort_transaction(operation_options(arguments, {}))
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

local function assert_session_transaction_state(runner, arguments, path)
  local session, err = runner:get_entity(
    arguments:get("session"),
    "session",
    path .. ".arguments.session"
  )

  if not session then
    return nil, err
  end

  if session:get_transaction_state() ~= arguments:get("state") then
    return configuration_error("session transaction state does not match", path)
  end

  return true
end

local function assert_session_pinned(expected)
  return function(runner, arguments, path)
    local session, err = runner:get_entity(
      arguments:get("session"),
      "session",
      path .. ".arguments.session"
    )

    if not session then
      return nil, err
    end

    if session:is_pinned() ~= expected then
      return configuration_error(
        expected and "session is not pinned" or "session is pinned",
        path
      )
    end

    return true
  end
end

local function assert_collection_exists(state, expected)
  return function(_, arguments, path)
    local database, err = state.internal_client:database(
      arguments:get("databaseName")
    )

    if not database then
      return nil, err
    end

    local names
    names, err = database:list_collection_names()

    if not names then
      return nil, err
    end

    local found = false

    for _, name in ipairs(names) do
      found = found or name == arguments:get("collectionName")
    end

    if found ~= expected then
      return configuration_error("collection existence does not match", path)
    end

    return true
  end
end

local function assert_index_exists(state, expected)
  return function(_, arguments, path)
    local database, err = state.internal_client:database(
      arguments:get("databaseName")
    )

    if not database then
      return nil, err
    end

    local collection
    collection, err = database:collection(arguments:get("collectionName"))

    if not collection then
      return nil, err
    end

    local cursor
    cursor, err = collection:list_indexes()

    if not cursor then
      return nil, err
    end

    local found = false

    while true do
      local index
      index, err = cursor:next()

      if index == nil then
        cursor:close()

        if err then
          return nil, err
        end

        break
      end

      found = found or index:get("name") == arguments:get("indexName")
    end

    if found ~= expected then
      return configuration_error("index existence does not match", path)
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

local function event_count_arguments(state, runner, arguments, path, minimum)
  local client, err = runner:get_entity(
    arguments:get("client"),
    "client",
    path .. ".arguments.client"
  )

  if not client then
    return nil, err
  end

  local expected = arguments:get("event")
  local count = arguments:get("count")

  if bson.is_exact(count) then
    count = count:to_number()
  end

  if not bson.is_document(expected) or #expected ~= 1
      or math.type(count) ~= "integer" or count < minimum
  then
    return configuration_error("invalid event count arguments", path)
  end

  local event_name, specification = expected:get_at(1)
  local collector = state.collectors[client]

  if not collector or collector:count(event_name, specification) == nil then
    return configuration_error("unsupported event count event", path)
  end

  return collector, event_name, specification, count
end

local function wait_for_event(state)
  return function(runner, arguments, path)
    local collector, event_name, specification, count = event_count_arguments(
      state,
      runner,
      arguments,
      path,
      1
    )

    if not collector then
      return nil, event_name
    end

    local deadline = state.runtime.clock:now() + 10

    while collector:count(event_name, specification) < count do
      if state.runtime.clock:now() >= deadline then
        return configuration_error("waitForEvent timed out", path)
      end

      local slept, sleep_err = state.runtime.clock:sleep(0.01)

      if not slept then
        return nil, sleep_err
      end
    end

    return true
  end
end

local function assert_event_count(state)
  return function(runner, arguments, path)
    local collector, event_name, specification, count = event_count_arguments(
      state,
      runner,
      arguments,
      path,
      0
    )

    if not collector then
      return nil, event_name
    end

    if collector:count(event_name, specification) ~= count then
      return configuration_error("observed event count does not match", path)
    end

    return true
  end
end

local function validate_topology_arguments(arguments, allowed, path)
  if not bson.is_document(arguments) then
    return configuration_error("topology operation arguments must be an object", path)
  end

  for key in arguments:iter() do
    if not allowed[key] then
      return configuration_error(
        "unsupported topology operation argument: " .. key,
        path .. ".arguments." .. key
      )
    end
  end

  return true
end

local function primary_address(description)
  if description == nil then
    return nil
  end

  for _, address in ipairs(description:addresses()) do
    local server = description:server(address)

    if server and server.type == "RSPrimary" then
      return address
    end
  end
end

local function record_topology_description(state)
  return function(runner, arguments, path)
    local valid, err = validate_topology_arguments(arguments, {
      client = true,
      id = true,
    }, path)

    if not valid then
      return nil, err
    end

    local client_name = arguments:get("client")
    local id = arguments:get("id")

    if type(client_name) ~= "string" or client_name == ""
        or type(id) ~= "string" or id == ""
    then
      return configuration_error(
        "recordTopologyDescription requires non-empty client and id strings",
        path
      )
    end

    local client
    client, err = runner:get_entity(
      client_name,
      "client",
      path .. ".arguments.client"
    )

    if not client then
      return nil, err
    end

    local collector = state.collectors[client]
    local description = collector and collector:topology_description()

    if description == nil then
      return configuration_error("client has no topology description", path)
    end

    return runner:add_entity(id, "topologyDescription", description)
  end
end

local function assert_topology_type(runner, arguments, path)
  local valid, err = validate_topology_arguments(arguments, {
    topologyDescription = true,
    topologyType = true,
  }, path)

  if not valid then
    return nil, err
  end

  local name = arguments:get("topologyDescription")
  local expected = arguments:get("topologyType")

  if type(name) ~= "string" or name == ""
      or type(expected) ~= "string" or expected == ""
  then
    return configuration_error(
      "assertTopologyType requires non-empty topologyDescription and topologyType strings",
      path
    )
  end

  local description
  description, err = runner:get_entity(
    name,
    "topologyDescription",
    path .. ".arguments.topologyDescription"
  )

  if not description then
    return nil, err
  end

  if description.type ~= expected then
    return configuration_error("topology type does not match", path)
  end

  return true
end

local function wait_for_primary_change(state)
  return function(runner, arguments, path)
    local valid, err = validate_topology_arguments(arguments, {
      client = true,
      priorTopologyDescription = true,
      timeoutMS = true,
    }, path)

    if not valid then
      return nil, err
    end

    local client_name = arguments:get("client")
    local prior_name = arguments:get("priorTopologyDescription")
    local timeout_ms = arguments:get("timeoutMS")

    if bson.is_exact(timeout_ms) then
      timeout_ms = timeout_ms:to_number()
    end

    if timeout_ms == nil then
      timeout_ms = 10000
    end

    if type(client_name) ~= "string" or client_name == ""
        or type(prior_name) ~= "string" or prior_name == ""
        or math.type(timeout_ms) ~= "integer" or timeout_ms < 0
    then
      return configuration_error("invalid waitForPrimaryChange arguments", path)
    end

    local client
    client, err = runner:get_entity(
      client_name,
      "client",
      path .. ".arguments.client"
    )

    if not client then
      return nil, err
    end

    local prior
    prior, err = runner:get_entity(
      prior_name,
      "topologyDescription",
      path .. ".arguments.priorTopologyDescription"
    )

    if not prior then
      return nil, err
    end

    local collector = state.collectors[client]

    if not collector then
      return configuration_error("client has no topology collector", path)
    end

    local old_primary = primary_address(prior)
    local deadline = state.runtime.clock:now() + timeout_ms / 1000

    while true do
      local new_primary = primary_address(collector:topology_description())

      if new_primary ~= nil and new_primary ~= old_primary then
        return true
      end

      local remaining = deadline - state.runtime.clock:now()

      if remaining <= 0 then
        local current = collector:topology_description()
        return configuration_error(
          "waitForPrimaryChange timed out; prior primary="
            .. tostring(old_primary) .. ", current primary="
            .. tostring(primary_address(current)) .. ", topology="
            .. tostring(current and current.type),
          path
        )
      end

      local slept, sleep_err = state.runtime.clock:sleep(math.min(remaining, 0.01))

      if not slept then
        return nil, sleep_err
      end
    end
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

local function append_metadata(_, client, arguments)
  local driver_info = arguments:get("driverInfoOptions")

  if not bson.is_document(driver_info) then
    return configuration_error(
      "appendMetadata driverInfoOptions must be a document",
      "$.arguments.driverInfoOptions"
    )
  end

  local valid, err = validate_fields(driver_info, {
    name = true,
    platform = true,
    version = true,
  }, "$.arguments.driverInfoOptions")

  if not valid then
    return nil, err
  end

  return client:append_metadata({
    name = driver_info:get("name"),
    platform = driver_info:get("platform"),
    version = driver_info:get("version"),
  })
end

local function close_client(_, client)
  return client:close()
end

local function finalize_client(_, client)
  if client:is_closed() then
    return true
  end

  return client:close()
end

local function list_collections(_, database, arguments)
  local cursor, err = database:list_collections(operation_options(arguments, {
    filter = "filter",
    rawData = "raw_data",
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

local function ordered_command(arguments, operation_name)
  local command = arguments:get("command")
  local command_name = arguments:get("commandName")

  if not bson.is_document(command) or type(command_name) ~= "string"
      or command_name == ""
  then
    return configuration_error(
      "invalid " .. operation_name .. " arguments",
      "$.arguments"
    )
  end

  local entries = { { command_name, command:get(command_name) or 1 } }

  for key, value in command:iter() do
    if key ~= command_name then
      entries[#entries + 1] = { key, value }
    end
  end

  return bson.document(entries)
end

local function run_command(_, database, arguments)
  local command, err = ordered_command(arguments, "runCommand")

  if not command then
    return nil, err
  end

  local options = operation_options(
    arguments,
    { readPreference = "read_preference" }
  )

  options.read_preference = convert_read_preference(options.read_preference)
  return database:run_command(command, options)
end

local function create_command_cursor(_, database, arguments)
  local command, err = ordered_command(arguments, "createCommandCursor")

  if not command then
    return nil, err
  end

  local options = operation_options(arguments, {
    batchSize = "batch_size",
    comment = "comment",
    cursorType = "cursor_type",
    maxTimeMS = "max_await_time_ms",
    readPreference = "read_preference",
  })

  options.read_preference = convert_read_preference(options.read_preference)
  return database:run_cursor_command(command, options)
end

local function run_cursor_command(runner, database, arguments)
  local cursor, err = create_command_cursor(runner, database, arguments)

  if not cursor then
    return nil, err
  end

  return collect_cursor(cursor)
end

local function iterate_cursor(_, cursor)
  return cursor:next()
end

local function close_cursor(_, cursor, arguments)
  return cursor:close(operation_options(arguments, {}))
end

local function finalize_cursor(_, cursor)
  local closed, close_err = cursor:close()

  if closed == nil then
    return nil, close_err
  end

  return true
end

local CURSOR_OPERATIONS = {
  close = {
    arguments = { "timeoutMS" },
    handler = close_cursor,
  },
  iterateOnce = {
    arguments = {},
    handler = iterate_cursor,
  },
  iterateUntilDocumentOrError = {
    arguments = {},
    handler = iterate_cursor,
  },
}

local function create_change_stream(_, collection, arguments)
  return collection:watch(arguments:get("pipeline") or bson.array({}))
end

local function create_collection(_, database, arguments)
  return database:create_collection(arguments:get("collection"), operation_options(
    arguments,
    {
      clusteredIndex = "clustered_index",
      expireAfterSeconds = "expire_after_seconds",
      pipeline = "pipeline",
      timeseries = "timeseries",
      viewOn = "view_on",
    }
  ))
end

local function modify_collection(_, database, arguments)
  return database:modify_collection(arguments:get("collection"), operation_options(
    arguments,
    {
      index = "index",
      validationAction = "validation_action",
      validationLevel = "validation_level",
      validator = "validator",
    }
  ))
end

local function drop_collection(_, database, arguments)
  return database:drop_collection(arguments:get("collection"), operation_options(
    arguments,
    {}
  ))
end

local function create_index(_, collection, arguments)
  return collection:create_index(arguments:get("keys"), operation_options(
    arguments,
    { name = "name", rawData = "raw_data", unique = "unique" }
  ))
end

local function create_search_index(_, collection, arguments)
  return collection:create_search_index(
    arguments:get("model"),
    operation_options(arguments, {})
  )
end

local function create_search_indexes(_, collection, arguments)
  local models = {}
  local unified_models = arguments:get("models")

  if bson.is_array(unified_models) then
    for index, model in unified_models:iter() do
      models[index] = model
    end
  else
    models = unified_models
  end

  local names, err = collection:create_search_indexes(
    models,
    operation_options(arguments, {})
  )

  if not names then
    return nil, err
  end

  local values = {}

  for index = 1, #names do
    values[index] = names[index]
  end

  return bson.array(values)
end

local function list_search_indexes(_, collection, arguments)
  local aggregation_options = arguments:get("aggregationOptions")
    or bson.document({})
  local fields = {
    allowDiskUse = "allow_disk_use",
    batchSize = "batch_size",
    bypassDocumentValidation = "bypass_document_validation",
    collation = "collation",
    comment = "comment",
    hint = "hint",
    let = "let",
    maxTimeMS = "max_time_ms",
    rawData = "raw_data",
    timeoutMS = "timeout_ms",
    timeoutMode = "timeout_mode",
  }

  if not bson.is_document(aggregation_options) then
    return configuration_error(
      "listSearchIndexes aggregationOptions must be a document",
      "$.arguments.aggregationOptions"
    )
  end

  local valid, err = validate_fields(
    aggregation_options,
    fields,
    "$.arguments.aggregationOptions"
  )

  if not valid then
    return nil, err
  end

  local options = operation_options(aggregation_options, fields)

  if arguments:get("session") ~= nil then
    options.session = arguments:get("session")
  end

  local cursor
  cursor, err = collection:list_search_indexes(
    arguments:get("name"),
    options
  )

  if not cursor then
    return nil, err
  end

  return collect_cursor(cursor)
end

local function update_search_index(_, collection, arguments)
  return collection:update_search_index(
    arguments:get("name"),
    arguments:get("definition"),
    operation_options(arguments, {})
  )
end

local function drop_search_index(_, collection, arguments)
  return collection:drop_search_index(
    arguments:get("name"),
    operation_options(arguments, {})
  )
end

local function drop_index(_, collection, arguments)
  return collection:drop_index(arguments:get("name"), operation_options(
    arguments,
    { rawData = "raw_data" }
  ))
end

local function drop_indexes(_, collection, arguments)
  return collection:drop_indexes(operation_options(arguments, {}))
end

local function list_indexes(_, collection, arguments)
  local cursor, err = collection:list_indexes(operation_options(
    arguments or bson.document({}),
    { rawData = "raw_data" }
  ))

  if not cursor then
    return nil, err
  end

  return collect_cursor(cursor)
end

local function list_index_names(_, collection, arguments)
  local documents, err = list_indexes(nil, collection, arguments)

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

local function create_find_cursor(_, collection, arguments, _, path)
  local filter = arguments:get("filter")

  if filter == nil then
    return configuration_error(
      "createFindCursor requires a filter argument",
      path .. ".arguments.filter"
    )
  end

  return collection:find(filter, operation_options(
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

local function internal_client_adapter(client, state)
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

    local admin, err = client:database("admin")

    if not admin then
      return nil, err
    end

    local response
    response, err = admin:run_command(
      bson.document({ { "ping", 1 } }),
      { monitor = false }
    )

    if not response then
      return nil, err
    end

    state.initial_cluster_time = response:get("$clusterTime")
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

  if options.multiple_mongos_uri ~= nil
      and (type(options.multiple_mongos_uri) ~= "string"
        or options.multiple_mongos_uri == "")
  then
    error("unified driver multiple mongos URI must be a non-empty string", 2)
  end

  if options.oidc_callback ~= nil and type(options.oidc_callback) ~= "function" then
    error("unified driver OIDC callback must be a function", 2)
  end

  local internal_client, err = client_module.connect(options.uri, {
    runtime = options.runtime,
  })

  if not internal_client then
    return nil, err
  end

  local state = {
    collectors = setmetatable({}, { __mode = "k" }),
    environment_topology = options.environment and options.environment.topology,
    initial_cluster_time = nil,
    internal_client = internal_client,
    multiple_mongos_uri = options.multiple_mongos_uri,
    oidc_callback = options.oidc_callback,
    runtime = options.runtime,
    session_clients = setmetatable({}, { __mode = "k" }),
    uri = options.uri,
  }
  local failpoint_handler = failpoints.new({
    cleanup_database = function()
      local cleanup_client, cleanup_err = client_module.connect(
        state.multiple_mongos_uri or state.uri,
        { pool_listeners = {}, runtime = state.runtime }
      )

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
    session_client = function(session)
      return state.session_clients[session]
    end,
  })
  local lifecycle = lifecycle_module.new({
    assert_events = function(runner, expected, path)
      return event_module.assert_all(runner, expected, state.collectors, path)
    end,
    environment = options.environment,
    entity_finalizers = {
      changeStream = finalize_cursor,
      client = finalize_client,
      commandCursor = finalize_cursor,
      findCursor = finalize_cursor,
    },
    entity_factories = {
      client = client_factory(state),
      collection = collection_factory,
      database = database_factory,
      session = session_factory(state),
    },
    internal_client = internal_client_adapter(internal_client, state),
    operations = {
      changeStream = CURSOR_OPERATIONS,
      client = {
        appendMetadata = {
          arguments = { "driverInfoOptions" },
          handler = append_metadata,
        },
        close = {
          arguments = {},
          handler = close_client,
        },
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
        createChangeStream = {
          arguments = { "pipeline" },
          handler = create_change_stream,
          result_kind = "changeStream",
        },
        createFindCursor = {
          arguments = {
            "allowDiskUse", "batchSize", "collation", "comment", "filter",
            "hint", "let", "limit", "maxTimeMS", "projection", "rawData",
            "skip", "sort", "timeoutMode", "timeoutMS",
          },
          handler = create_find_cursor,
          result_kind = "findCursor",
        },
        createIndex = {
          arguments = { "keys", "name", "rawData", "timeoutMS", "unique" },
          handler = create_index,
        },
        createSearchIndex = {
          arguments = { "model" },
          handler = create_search_index,
        },
        createSearchIndexes = {
          arguments = { "models" },
          handler = create_search_indexes,
        },
        listSearchIndexes = {
          arguments = { "aggregationOptions", "name" },
          handler = list_search_indexes,
        },
        updateSearchIndex = {
          arguments = { "definition", "name" },
          handler = update_search_index,
        },
        dropSearchIndex = {
          arguments = { "name" },
          handler = drop_search_index,
        },
        dropIndex = {
          arguments = { "name", "rawData", "timeoutMS" },
          handler = drop_index,
        },
        dropIndexes = {
          arguments = { "timeoutMS" },
          handler = drop_indexes,
        },
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
          arguments = { "timeoutMS" },
          handler = list_index_names,
        },
        listIndexes = {
          arguments = { "rawData", "timeoutMS" },
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
        createCommandCursor = {
          arguments = {
            "batchSize", "command", "commandName", "comment", "cursorType",
            "maxTimeMS", "readPreference", "timeoutMode", "timeoutMS",
          },
          handler = create_command_cursor,
          result_kind = "commandCursor",
        },
        createCollection = {
          arguments = {
            "clusteredIndex", "collection", "expireAfterSeconds", "pipeline",
            "timeseries", "viewOn",
          },
          handler = create_collection,
        },
        dropCollection = {
          arguments = { "collection" },
          handler = drop_collection,
        },
        listCollectionNames = {
          arguments = { "filter" },
          handler = list_collection_names,
        },
        listCollectionObjects = {
          arguments = { "filter", "rawData" },
          handler = list_collections,
        },
        listCollections = {
          arguments = { "filter", "rawData" },
          handler = list_collections,
        },
        modifyCollection = {
          arguments = {
            "collection", "index", "validationAction", "validationLevel", "validator",
          },
          handler = modify_collection,
        },
        runCommand = {
          arguments = { "command", "commandName", "readPreference" },
          handler = run_command,
        },
        runCursorCommand = {
          arguments = {
            "batchSize", "command", "commandName", "comment", "cursorType",
            "maxTimeMS", "readPreference", "timeoutMode", "timeoutMS",
          },
          handler = run_cursor_command,
        },
      },
      commandCursor = CURSOR_OPERATIONS,
      findCursor = CURSOR_OPERATIONS,
      session = {
        abortTransaction = {
          arguments = {},
          handler = abort_transaction,
        },
        commitTransaction = {
          arguments = {},
          handler = commit_transaction,
        },
        endSession = {
          arguments = {},
          handler = end_session,
        },
        getSnapshotTime = {
          arguments = {},
          handler = get_snapshot_time,
          result_kind = "bson",
        },
        startTransaction = {
          arguments = {
            "maxCommitTimeMS", "readConcern", "readPreference", "writeConcern",
          },
          handler = start_transaction,
        },
        withTransaction = {
          arguments = {
            "callback", "maxCommitTimeMS", "readConcern", "readPreference",
            "writeConcern",
          },
          handler = with_transaction,
        },
      },
    },
    runtime = options.runtime,
    test_operations = {
      assertCollectionExists = assert_collection_exists(state, true),
      assertCollectionNotExists = assert_collection_exists(state, false),
      assertEventCount = assert_event_count(state),
      assertTopologyType = assert_topology_type,
      assertDifferentLsidOnLastTwoCommands = assert_last_lsids(state, false),
      assertIndexExists = assert_index_exists(state, true),
      assertIndexNotExists = assert_index_exists(state, false),
      assertSameLsidOnLastTwoCommands = assert_last_lsids(state, true),
      assertSessionDirty = assert_session_dirty(true),
      assertSessionNotDirty = assert_session_dirty(false),
      assertSessionPinned = assert_session_pinned(true),
      assertSessionTransactionState = assert_session_transaction_state,
      assertSessionUnpinned = assert_session_pinned(false),
      failPoint = failpoint_handler,
      recordTopologyDescription = record_topology_description(state),
      targetedFailPoint = failpoint_handler,
      waitForEvent = wait_for_event(state),
      waitForPrimaryChange = wait_for_primary_change(state),
    },
  })

  return lifecycle
end

return M
