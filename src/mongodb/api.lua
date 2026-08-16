local admin = require("mongodb.admin")
local bson = require("mongodb.bson")
local bulk = require("mongodb.bulk")
local errors = require("mongodb.error")
local driver_options = require("mongodb.config.options")
local crud = require("mongodb.crud")
local cursor_model = require("mongodb.cursor")
local operation_timeout = require("mongodb.operation_timeout")

local M = {}

local CLIENT_STATES = setmetatable({}, { __mode = "k" })
local DATABASE_STATES = setmetatable({}, { __mode = "k" })
local COLLECTION_STATES = setmetatable({}, { __mode = "k" })
local CLIENT_METHODS = {}
local DATABASE_METHODS = {}
local COLLECTION_METHODS = {}

local PRIMARY_READ_PREFERENCE = {
  max_staleness_seconds = -1,
  mode = "primary",
  tag_sets = { {} },
}

local function immutable(kind)
  return function()
    error("MongoDB " .. kind .. " handles are immutable", 2)
  end
end

local function readonly_warnings(warnings)
  local data = {}

  for index = 1, #warnings do
    data[index] = warnings[index]
  end

  return setmetatable({}, {
    __index = data,
    __len = function()
      return #data
    end,
    __metatable = "mongodb.client.warnings",
    __newindex = immutable("client"),
    __pairs = function()
      return next, data, nil
    end,
  })
end

local function handle_metatable(kind, methods, states)
  return {
    __index = function(value, key)
      local method = methods[key]

      if method then
        return method
      end

      local state = states[value]
      return state and state[key] or nil
    end,
    __metatable = "mongodb." .. kind,
    __newindex = immutable(kind),
  }
end

local CLIENT_METATABLE = handle_metatable("client", CLIENT_METHODS, CLIENT_STATES)
local DATABASE_METATABLE = handle_metatable("database", DATABASE_METHODS, DATABASE_STATES)
local COLLECTION_METATABLE = handle_metatable(
  "collection",
  COLLECTION_METHODS,
  COLLECTION_STATES
)

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

local function require_name(kind, name)
  if type(name) ~= "string" then
    error(kind .. " name must be a string", 3)
  end

  if utf8.len(name) == nil then
    error(kind .. " name must be valid UTF-8", 3)
  end
end

local function validate_database_name(name)
  require_name("database", name)

  if name == "" then
    error("database name cannot be empty", 3)
  end

  if name ~= "$external" and name:find('[/\\ "$%z]') then
    error("database name contains a prohibited character", 3)
  end
end

local function validate_collection_name(name)
  require_name("collection", name)

  if name == "" or name:find("..", 1, true) then
    error("collection name cannot be empty or contain '..'", 3)
  end

  if name:sub(1, 1) == "." or name:sub(-1) == "." then
    error("collection name cannot start or end with '.'", 3)
  end

  if name:find("%z") then
    error("collection name cannot contain a null byte", 3)
  end

  if name:find("$", 1, true)
      and name:sub(1, 5) ~= "$cmd."
      and name ~= "$cmd"
      and name:sub(1, 11) ~= "oplog.$main"
  then
    error("collection name cannot contain '$'", 3)
  end
end

local function inherited_options(parent, overrides)
  overrides = overrides or {}

  if type(overrides) ~= "table" then
    error("handle options must be a table", 3)
  end

  local allowed = {
    read_concern = true,
    read_preference = true,
    timeout_ms = true,
    write_concern = true,
  }

  for key in pairs(overrides) do
    if not allowed[key] then
      error("unknown handle option: " .. tostring(key), 3)
    end
  end

  local normalized, err = driver_options.normalize(nil, overrides)

  if not normalized then
    return nil, err
  end

  return {
    read_concern = overrides.read_concern ~= nil
      and normalized.read_concern or parent.read_concern,
    read_preference = overrides.read_preference ~= nil
      and normalized.read_preference or parent.read_preference,
    timeout_ms = overrides.timeout_ms ~= nil
      and normalized.timeout_ms or parent.timeout_ms,
    write_concern = overrides.write_concern ~= nil
      and normalized.write_concern or parent.write_concern,
  }
end

local function ensure_open(state)
  if state.closed then
    return client_error("client is closed")
  end

  return true
end

local function run_operation(state, options, callback)
  return operation_timeout.run(
    state.runtime,
    state.timeout_ms,
    options,
    callback
  )
end

local function command_document(command)
  if type(command) == "string" then
    if command == "" then
      error("command name must be non-empty", 3)
    end

    return bson.document({ { command, 1 } })
  elseif not bson.is_document(command) then
    error("command must be a name or BSON document", 3)
  elseif #command == 0 then
    error("command document must not be empty", 3)
  end

  return command
end

local function command_options(options)
  local result = {}

  for key, value in pairs(options) do
    result[key] = value
  end

  if options.read_preference == nil then
    result.read_preference = PRIMARY_READ_PREFERENCE
  else
    local normalized, err = driver_options.normalize(nil, {
      read_preference = options.read_preference,
    })

    if not normalized then
      return nil, err
    end

    result.read_preference = normalized.read_preference
  end

  result.read_operation = true
  return result
end

local COMMAND_CURSOR_OPTIONS = {
  batch_size = true,
  cancellation = true,
  comment = true,
  cursor_type = true,
  deadline = true,
  max_await_time_ms = true,
  read_preference = true,
  session = true,
  timeout_mode = true,
  timeout_ms = true,
}

local function command_cursor_options(options)
  options = options or {}

  if type(options) ~= "table" then
    error("command cursor options must be a table", 3)
  end

  for key in pairs(options) do
    if not COMMAND_CURSOR_OPTIONS[key] then
      error("unknown command cursor option: " .. tostring(key), 3)
    end
  end

  if options.batch_size ~= nil
      and (math.type(options.batch_size) ~= "integer" or options.batch_size <= 0)
  then
    error("batch_size must be a positive integer", 3)
  end

  if options.max_await_time_ms ~= nil
      and (math.type(options.max_await_time_ms) ~= "integer"
        or options.max_await_time_ms < 0)
  then
    error("max_await_time_ms must be a non-negative integer", 3)
  end

  if options.cursor_type ~= nil
      and options.cursor_type ~= "non_tailable"
      and options.cursor_type ~= "tailable"
      and options.cursor_type ~= "tailable_await"
  then
    error("cursor_type must be non_tailable, tailable, or tailable_await", 3)
  end

  return options
end

local function command_cursor_collection(response, database_name)
  local cursor = response:get("cursor")

  if not bson.is_document(cursor) then
    return nil
  end

  local namespace = cursor:get("ns")
  local prefix = database_name .. "."

  if type(namespace) ~= "string" or namespace:sub(1, #prefix) ~= prefix
      or #namespace == #prefix
  then
    return protocol_error("command cursor contains an invalid namespace")
  end

  return namespace:sub(#prefix + 1)
end

local function new_database(client, name, options)
  validate_database_name(name)
  local client_state = CLIENT_STATES[client]
  local concerns, err = inherited_options(client_state.options, options)

  if not concerns then
    return nil, err
  end

  local value = {}

  DATABASE_STATES[value] = {
    client = client,
    client_state = client_state,
    executor = client_state.executor,
    max_wire_version = client_state.max_wire_version,
    name = name,
    on_cursor_close = client_state.on_cursor_close,
    read_concern = concerns.read_concern,
    read_preference = concerns.read_preference,
    runtime = client_state.runtime,
    timeout_ms = concerns.timeout_ms,
    write_concern = concerns.write_concern,
  }
  return setmetatable(value, DATABASE_METATABLE)
end

function CLIENT_METHODS:database(name, options)
  local state = CLIENT_STATES[self]

  if name == nil then
    name = state.default_database_name

    if name == nil then
      return client_error("no default database is configured")
    end
  end

  return new_database(self, name, options)
end

function CLIENT_METHODS:start_session(options)
  local state = CLIENT_STATES[self]
  local open, err = ensure_open(state)

  if not open then
    return nil, err
  end

  if state.sessions == nil then
    return client_error("deployment does not support sessions")
  end

  return state.sessions:start(options)
end

function CLIENT_METHODS:append_metadata(driver_info)
  local state = CLIENT_STATES[self]
  local open, err = ensure_open(state)

  if not open then
    return nil, err
  end

  if state.append_metadata == nil then
    return client_error("client metadata updates are unavailable")
  end

  return state.append_metadata(driver_info)
end

function CLIENT_METHODS:close()
  local state = CLIENT_STATES[self]

  if state.closed then
    return false
  end

  for cursor in pairs(state.cursors) do
    cursor:close()
  end

  if state.sessions then
    local identifiers = state.sessions:close()

    if #identifiers > 0 then
      state.executor:command("admin", bson.document({
        { "endSessions", identifiers },
      }), { monitor = false, no_session = true })
    end
  end

  state.closed = true
  state.executor:close()
  return true
end

function CLIENT_METHODS:is_closed()
  return CLIENT_STATES[self].closed
end

local function register_client_cursor(client, cursor)
  if not cursor:is_closed() then
    CLIENT_STATES[client].cursors[cursor] = true
  end

  return cursor
end

function CLIENT_METHODS:list_databases(options)
  local state = CLIENT_STATES[self]
  local open, err = ensure_open(state)

  if not open then
    return nil, err
  end

  local cursor
  cursor, err = run_operation(state, options, function(prepared)
    return admin.list_databases(state, prepared)
  end)

  if not cursor then
    return nil, err
  end

  return register_client_cursor(self, cursor)
end

function CLIENT_METHODS:list_database_names(options)
  local state = CLIENT_STATES[self]
  local open, err = ensure_open(state)

  if not open then
    return nil, err
  end

  return run_operation(state, options, function(prepared)
    return admin.list_database_names(state, prepared)
  end)
end

function CLIENT_METHODS:drop_database(name_or_database, options)
  local name = name_or_database

  if DATABASE_STATES[name_or_database] then
    name = DATABASE_STATES[name_or_database].name
  end

  validate_database_name(name)
  local state = CLIENT_STATES[self]
  local open, err = ensure_open(state)

  if not open then
    return nil, err
  end

  return run_operation(state, options, function(prepared)
    return admin.drop_database(state, name, prepared)
  end)
end

function DATABASE_METHODS:collection(name, options)
  validate_collection_name(name)
  local state = DATABASE_STATES[self]
  local concerns, err = inherited_options(state, options)

  if not concerns then
    return nil, err
  end

  local value = {}

  COLLECTION_STATES[value] = {
    client = state.client,
    client_state = CLIENT_STATES[state.client],
    database = self,
    database_name = state.name,
    executor = CLIENT_STATES[state.client].executor,
    full_name = state.name .. "." .. name,
    max_bson_size = CLIENT_STATES[state.client].max_bson_size,
    max_message_size = CLIENT_STATES[state.client].max_message_size,
    max_wire_version = CLIENT_STATES[state.client].max_wire_version,
    max_write_batch_size = CLIENT_STATES[state.client].max_write_batch_size,
    name = name,
    object_ids = CLIENT_STATES[state.client].object_ids,
    on_cursor_close = function(cursor)
      CLIENT_STATES[state.client].cursors[cursor] = nil
    end,
    read_concern = concerns.read_concern,
    read_preference = concerns.read_preference,
    runtime = state.runtime,
    timeout_ms = concerns.timeout_ms,
    write_concern = concerns.write_concern,
  }
  return setmetatable(value, COLLECTION_METATABLE)
end

function DATABASE_METHODS:create_collection(name, options)
  local collection = self:collection(name)
  local state = DATABASE_STATES[self]
  local client_state = CLIENT_STATES[state.client]
  local open, err = ensure_open(client_state)

  if not open then
    return nil, err
  end

  local response
  response, err = run_operation(state, options, function(prepared)
    return admin.create_collection(state, name, prepared)
  end)

  if not response then
    return nil, err
  end

  return collection
end

function DATABASE_METHODS:modify_collection(name, options)
  self:collection(name)
  local state = DATABASE_STATES[self]
  local open, err = ensure_open(CLIENT_STATES[state.client])

  if not open then
    return nil, err
  end

  return run_operation(state, options, function(prepared)
    return admin.modify_collection(state, name, prepared)
  end)
end

function DATABASE_METHODS:drop_collection(name_or_collection, options)
  local name = name_or_collection

  if COLLECTION_STATES[name_or_collection] then
    local collection_state = COLLECTION_STATES[name_or_collection]

    if collection_state.database ~= self then
      error("collection belongs to a different database", 2)
    end

    name = collection_state.name
  else
    self:collection(name)
  end

  local state = DATABASE_STATES[self]
  local open, err = ensure_open(CLIENT_STATES[state.client])

  if not open then
    return nil, err
  end

  return run_operation(state, options, function(prepared)
    return admin.drop_collection(state, name, prepared)
  end)
end

function DATABASE_METHODS:list_collections(options)
  local state = DATABASE_STATES[self]
  local client_state = CLIENT_STATES[state.client]
  local open, err = ensure_open(client_state)

  if not open then
    return nil, err
  end

  local cursor
  cursor, err = run_operation(state, options, function(prepared)
    return admin.list_collections(state, prepared)
  end)

  if not cursor then
    return nil, err
  end

  return register_client_cursor(state.client, cursor)
end

function DATABASE_METHODS:list_collection_names(options)
  local state = DATABASE_STATES[self]
  local open, err = ensure_open(CLIENT_STATES[state.client])

  if not open then
    return nil, err
  end

  return run_operation(state, options, function(prepared)
    return admin.list_collection_names(state, prepared)
  end)
end

function DATABASE_METHODS:run_command(command, options)
  local state = DATABASE_STATES[self]
  local client_state = CLIENT_STATES[state.client]
  local open, err = ensure_open(client_state)

  if not open then
    return nil, err
  end

  command = command_document(command)

  return run_operation(state, options, function(prepared)
    local execution_options, option_err = command_options(prepared)

    if not execution_options then
      return nil, option_err
    end

    return client_state.executor:command(state.name, command, execution_options)
  end)
end

function DATABASE_METHODS:run_cursor_command(command, options)
  local state = DATABASE_STATES[self]
  local client_state = CLIENT_STATES[state.client]
  local open, err = ensure_open(client_state)

  if not open then
    return nil, err
  end

  command = command_document(command)
  options = command_cursor_options(options)

  if options.cursor_type ~= nil and options.cursor_type ~= "non_tailable" then
    if options.timeout_mode == "cursor_lifetime" then
      return client_error(
        "cursor_lifetime timeout mode is not supported for tailable command cursors"
      )
    end

    return client_error("tailable command cursors are outside production-core v1")
  end

  local cursor

  cursor, err = run_operation(state, options, function(prepared)
    local execution_options, option_err = command_options(prepared)

    if not execution_options then
      return nil, option_err
    end

    local session_context = prepared.session == nil
      and type(state.executor.release_session_context) == "function" and {} or nil
    local server_address

    execution_options.batch_size = nil
    execution_options.comment = nil
    execution_options.max_await_time_ms = nil
    execution_options.on_server_selected = function(address)
      server_address = address
    end
    execution_options.retryable_read = true
    execution_options.session_context = session_context
    local response
    response, option_err = state.executor:command(
      state.name,
      command,
      execution_options
    )

    if not response then
      if session_context then
        state.executor:release_session_context(session_context)
      end

      return nil, option_err
    end

    local collection_name
    collection_name, option_err = command_cursor_collection(response, state.name)

    if option_err then
      if session_context then
        state.executor:release_session_context(session_context)
      end

      return nil, option_err
    end

    return cursor_model.new(response, {
      batch_size = prepared.batch_size or 0,
      cancellation = prepared.cancellation,
      client_state = client_state,
      collection_name = collection_name,
      comment = prepared.comment,
      database_name = state.name,
      deadline = prepared.deadline,
      executor = state.executor,
      max_await_time_ms = prepared.max_await_time_ms,
      on_close = state.on_cursor_close,
      server_address = server_address,
      session = prepared.session,
      session_context = session_context,
      timeout_context = operation_timeout.capture(),
      timeout_mode = prepared.timeout_mode,
    })
  end)

  if not cursor then
    return nil, err
  end

  return register_client_cursor(state.client, cursor)
end

local function collection_operation(collection, operation, ...)
  local state = COLLECTION_STATES[collection]
  local client_state = CLIENT_STATES[state.client]
  local open, err = ensure_open(client_state)

  if not open then
    return nil, err
  end

  local arguments = table.pack(...)
  local options = arguments[arguments.n]

  return run_operation(state, options, function(prepared)
    arguments[arguments.n] = prepared
    return operation(state, table.unpack(arguments, 1, arguments.n))
  end)
end

function COLLECTION_METHODS:insert_one(document, options)
  return collection_operation(self, crud.insert_one, document, options)
end

function COLLECTION_METHODS:insert_many(documents, options)
  return collection_operation(self, bulk.insert_many, documents, options)
end

function COLLECTION_METHODS:bulk_write(models, options)
  return collection_operation(self, bulk.execute, models, options)
end

function COLLECTION_METHODS:create_index(keys, options)
  return collection_operation(self, admin.create_index, keys, options)
end

function COLLECTION_METHODS:create_indexes(models, options)
  return collection_operation(self, admin.create_indexes, models, options)
end

function COLLECTION_METHODS:create_search_index(model, options)
  return collection_operation(self, admin.create_search_index, model, options)
end

function COLLECTION_METHODS:create_search_indexes(models, options)
  return collection_operation(self, admin.create_search_indexes, models, options)
end

function COLLECTION_METHODS:update_search_index(name, definition, options)
  return collection_operation(
    self,
    admin.update_search_index,
    name,
    definition,
    options
  )
end

function COLLECTION_METHODS:drop_search_index(name, options)
  return collection_operation(self, admin.drop_search_index, name, options)
end

function COLLECTION_METHODS:drop(options)
  local state = COLLECTION_STATES[self]
  local client_state = CLIENT_STATES[state.client]
  local open, err = ensure_open(client_state)

  if not open then
    return nil, err
  end

  return run_operation(state, options, function(prepared)
    return admin.drop_collection(
      DATABASE_STATES[state.database],
      state.name,
      prepared
    )
  end)
end

function COLLECTION_METHODS:drop_index(name, options)
  return collection_operation(self, admin.drop_index, name, options)
end

function COLLECTION_METHODS:drop_indexes(options)
  return collection_operation(self, admin.drop_indexes, options)
end

function COLLECTION_METHODS:list_indexes(options)
  local cursor, err = collection_operation(self, admin.list_indexes, options)

  if not cursor then
    return nil, err
  end

  return register_client_cursor(COLLECTION_STATES[self].client, cursor)
end

function COLLECTION_METHODS:list_search_indexes(name, options)
  local cursor, err = collection_operation(
    self,
    admin.list_search_indexes,
    name,
    options
  )

  if not cursor then
    return nil, err
  end

  return register_client_cursor(COLLECTION_STATES[self].client, cursor)
end

function COLLECTION_METHODS:find_one(filter, options)
  return collection_operation(self, crud.find_one, filter, options)
end

function COLLECTION_METHODS:update_one(filter, update, options)
  return collection_operation(self, crud.update_one, filter, update, options)
end

function COLLECTION_METHODS:update_many(filter, update, options)
  return collection_operation(self, crud.update_many, filter, update, options)
end

function COLLECTION_METHODS:replace_one(filter, replacement, options)
  return collection_operation(self, crud.replace_one, filter, replacement, options)
end

function COLLECTION_METHODS:delete_one(filter, options)
  return collection_operation(self, crud.delete_one, filter, options)
end

function COLLECTION_METHODS:delete_many(filter, options)
  return collection_operation(self, crud.delete_many, filter, options)
end

local function register_cursor(collection, cursor)
  if not cursor:is_closed() then
    local state = COLLECTION_STATES[collection]

    CLIENT_STATES[state.client].cursors[cursor] = true
  end

  return cursor
end

function COLLECTION_METHODS:aggregate(pipeline, options)
  local cursor, err = collection_operation(self, crud.aggregate, pipeline, options)

  if not cursor then
    return nil, err
  end

  return register_cursor(self, cursor)
end

function COLLECTION_METHODS:count_documents(filter, options)
  return collection_operation(self, crud.count_documents, filter, options)
end

function COLLECTION_METHODS:estimated_document_count(options)
  return collection_operation(self, crud.estimated_document_count, options)
end

function COLLECTION_METHODS:distinct(key, filter, options)
  return collection_operation(self, crud.distinct, key, filter, options)
end

function COLLECTION_METHODS:find_one_and_delete(filter, options)
  return collection_operation(self, crud.find_one_and_delete, filter, options)
end

function COLLECTION_METHODS:find_one_and_replace(filter, replacement, options)
  return collection_operation(
    self,
    crud.find_one_and_replace,
    filter,
    replacement,
    options
  )
end

function COLLECTION_METHODS:find_one_and_update(filter, update, options)
  return collection_operation(self, crud.find_one_and_update, filter, update, options)
end

function COLLECTION_METHODS:find(filter, options)
  local cursor, err = collection_operation(self, crud.find, filter, options)

  if not cursor then
    return nil, err
  end

  return register_cursor(self, cursor)
end

function M.new_client(
  executor,
  options,
  default_database_name,
  warnings,
  object_ids,
  sessions,
  runtime,
  append_metadata
)
  if type(executor) ~= "table" or type(executor.command) ~= "function"
      or type(executor.close) ~= "function"
  then
    error("client handles require a command executor", 2)
  end

  if type(options) ~= "table" then
    error("client handles require normalized options", 2)
  end

  if append_metadata ~= nil and type(append_metadata) ~= "function" then
    error("client metadata updater must be a function", 2)
  end

  if default_database_name ~= nil then
    validate_database_name(default_database_name)
  end

  local value = {}
  local capabilities = type(executor.capabilities) == "function" and executor:capabilities()

  local state = {
    append_metadata = append_metadata,
    closed = false,
    cursors = setmetatable({}, { __mode = "k" }),
    default_database_name = default_database_name,
    executor = executor,
    max_bson_size = capabilities and capabilities.max_bson_size or 16 * 1024 * 1024,
    max_message_size = capabilities and capabilities.max_message_size or 48000000,
    max_wire_version = capabilities and capabilities.max_wire_version or 0,
    max_write_batch_size = capabilities and capabilities.max_write_batch_size or 100000,
    object_ids = object_ids,
    options = options,
    read_concern = options.read_concern,
    read_preference = options.read_preference,
    runtime = runtime,
    sessions = sessions,
    timeout_ms = options.timeout_ms,
    warnings = readonly_warnings(warnings or {}),
    write_concern = options.write_concern,
  }
  CLIENT_STATES[value] = state
  state.client_state = state
  state.on_cursor_close = function(cursor)
    state.cursors[cursor] = nil
  end
  return setmetatable(value, CLIENT_METATABLE)
end

return M
