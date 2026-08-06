local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local driver_options = require("mongodb.config.options")
local crud = require("mongodb.crud")

local M = {}

local CLIENT_STATES = setmetatable({}, { __mode = "k" })
local DATABASE_STATES = setmetatable({}, { __mode = "k" })
local COLLECTION_STATES = setmetatable({}, { __mode = "k" })
local CLIENT_METHODS = {}
local DATABASE_METHODS = {}
local COLLECTION_METHODS = {}

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
    name = name,
    read_concern = concerns.read_concern,
    read_preference = concerns.read_preference,
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

function CLIENT_METHODS:close()
  local state = CLIENT_STATES[self]

  if state.closed then
    return false
  end

  for cursor in pairs(state.cursors) do
    cursor:close()
  end

  state.closed = true
  state.executor:close()
  return true
end

function CLIENT_METHODS:is_closed()
  return CLIENT_STATES[self].closed
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
    max_wire_version = CLIENT_STATES[state.client].max_wire_version,
    name = name,
    object_ids = CLIENT_STATES[state.client].object_ids,
    on_cursor_close = function(cursor)
      CLIENT_STATES[state.client].cursors[cursor] = nil
    end,
    read_concern = concerns.read_concern,
    read_preference = concerns.read_preference,
    write_concern = concerns.write_concern,
  }
  return setmetatable(value, COLLECTION_METATABLE)
end

function DATABASE_METHODS:run_command(command, options)
  local state = DATABASE_STATES[self]
  local client_state = CLIENT_STATES[state.client]
  local open, err = ensure_open(client_state)

  if not open then
    return nil, err
  end

  if type(command) == "string" then
    if command == "" then
      error("command name must be non-empty", 2)
    end

    command = bson.document({ { command, 1 } })
  elseif not bson.is_document(command) then
    error("command must be a name or BSON document", 2)
  end

  return client_state.executor:command(state.name, command, options)
end

local function collection_operation(collection, operation, ...)
  local state = COLLECTION_STATES[collection]
  local client_state = CLIENT_STATES[state.client]
  local open, err = ensure_open(client_state)

  if not open then
    return nil, err
  end

  return operation(state, ...)
end

function COLLECTION_METHODS:insert_one(document, options)
  return collection_operation(self, crud.insert_one, document, options)
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

function COLLECTION_METHODS:find(filter, options)
  local cursor, err = collection_operation(self, crud.find, filter, options)

  if not cursor then
    return nil, err
  end

  local state = COLLECTION_STATES[self]

  CLIENT_STATES[state.client].cursors[cursor] = true
  return cursor
end

function M.new_client(executor, options, default_database_name, warnings, object_ids)
  if type(executor) ~= "table" or type(executor.command) ~= "function"
      or type(executor.close) ~= "function"
  then
    error("client handles require a command executor", 2)
  end

  if type(options) ~= "table" then
    error("client handles require normalized options", 2)
  end

  if default_database_name ~= nil then
    validate_database_name(default_database_name)
  end

  local value = {}
  local capabilities = type(executor.capabilities) == "function" and executor:capabilities()

  CLIENT_STATES[value] = {
    closed = false,
    cursors = setmetatable({}, { __mode = "k" }),
    default_database_name = default_database_name,
    executor = executor,
    max_wire_version = capabilities and capabilities.max_wire_version or 0,
    object_ids = object_ids,
    options = options,
    read_concern = options.read_concern,
    read_preference = options.read_preference,
    warnings = readonly_warnings(warnings or {}),
    write_concern = options.write_concern,
  }
  return setmetatable(value, CLIENT_METATABLE)
end

return M
