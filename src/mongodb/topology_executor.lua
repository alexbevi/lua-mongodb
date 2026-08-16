local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local operation_timeout = require("mongodb.operation_timeout")

local M = {}

local EXECUTOR_STATES = setmetatable({}, { __mode = "k" })
local METHODS = {}

local READ_COMMANDS = {
  aggregate = true,
  count = true,
  distinct = true,
  find = true,
  getMore = true,
  listCollections = true,
  listDatabases = true,
  listIndexes = true,
}

local WIRE_READ_PREFERENCE_MODES = {
  nearest = "nearest",
  primary_preferred = "primaryPreferred",
  secondary = "secondary",
  secondary_preferred = "secondaryPreferred",
}

local METATABLE = {
  __index = METHODS,
  __metatable = "mongodb.topology_executor",
  __newindex = function()
    error("topology executors are immutable", 2)
  end,
}

local function copy_read_preference(preference)
  local tag_sets = {}

  for index, tag_set in ipairs(preference.tag_sets or {}) do
    local copy = {}

    for key, value in pairs(tag_set) do
      copy[key] = value
    end

    tag_sets[index] = copy
  end

  return {
    max_staleness_seconds = preference.max_staleness_seconds,
    mode = preference.mode,
    tag_sets = tag_sets,
  }
end

local function operation_for(command, options)
  if options and options.read_operation == true then
    return "read"
  end

  local name = command:keys()[1]

  return READ_COMMANDS[name] and "read" or "write"
end

local function decorate_read_preference(selected, command)
  local preference = selected.read_preference
  local command_name = command:keys()[1]

  if preference == nil or preference.mode == "primary"
      or command_name == "getMore"
      or command:get("$readPreference") ~= nil
      or selected.server_type == "Standalone"
  then
    return command
  end

  local preference_entries = {
    { "mode", WIRE_READ_PREFERENCE_MODES[preference.mode] },
  }

  if #preference.tag_sets > 1
      or (#preference.tag_sets == 1 and next(preference.tag_sets[1]) ~= nil)
  then
    local tag_sets = {}

    for index, tag_set in ipairs(preference.tag_sets) do
      tag_sets[index] = bson.document(tag_set)
    end

    preference_entries[#preference_entries + 1] = {
      "tags",
      bson.array(tag_sets),
    }
  end

  if preference.max_staleness_seconds ~= nil
      and preference.max_staleness_seconds ~= -1
  then
    preference_entries[#preference_entries + 1] = {
      "maxStalenessSeconds",
      preference.max_staleness_seconds,
    }
  end

  local entries = command:entries()
  entries[#entries + 1] = {
    "$readPreference",
    bson.document(preference_entries),
  }
  return bson.document(entries)
end

local function application_error_type(err)
  if errors.is(err, errors.CATEGORY.NETWORK) then
    return "network"
  elseif errors.is(err, errors.CATEGORY.TIMEOUT) then
    return "timeout"
  elseif errors.is(err, errors.CATEGORY.SERVER) then
    return "command"
  end

  return "handshake"
end

local function report_error(state, address, generation, err, when)
  local response = err.details and err.details.response

  state.topology:handle_application_error(address, {
    error = err,
    generation = generation,
    response = response,
    type = application_error_type(err),
    when = when,
  })
end

local function refresh_socket_deadline(options)
  local factory = options.socket_deadline_factory

  if factory then
    options.socket_deadline = factory()
    options.socket_deadline_factory = nil
  end
end

local function select_connection(state, operation, options)
  local context = operation_timeout.current()
  local deadline = options and options.deadline or context and context.deadline
  local read_preference = operation == "read"
    and options and options.read_preference or nil

  if operation == "read" and read_preference == nil then
    read_preference = state.read_preference
  end

  if read_preference ~= nil then
    read_preference = copy_read_preference(read_preference)
  end

  local selected, pool_or_err = state.topology:select_server(
    operation,
    read_preference,
    {
      cancellation = options and options.cancellation,
      deadline = deadline,
      deprioritized_servers = options and options.deprioritized_servers,
      local_threshold_ms = state.local_threshold_ms,
      server_address = options and options.server_address,
      timeout_ms = state.server_selection_timeout_ms,
    }
  )

  if not selected then
    return nil, pool_or_err
  end

  local pool = pool_or_err
  local connection, checkout_err, reported = pool:check_out({
    cancellation = options and options.cancellation,
    deadline = deadline,
  })

  if not connection then
    if not reported and not errors.is(checkout_err, errors.CATEGORY.POOL) then
      report_error(
        state,
        selected.address,
        pool.generation or 0,
        checkout_err,
        "beforeHandshakeCompletes"
      )
    end

    return nil, checkout_err
  end

  return {
    address = selected.address,
    connection = connection,
    executor = connection.resource,
    minimum_round_trip_time_ms = selected.minimum_round_trip_time or 0,
    pool = pool,
    read_preference = read_preference,
    server_type = selected.type,
  }
end

local function finish_connection(state, selected, err)
  if err then
    if errors.is(err, errors.CATEGORY.NETWORK)
        or errors.is(err, errors.CATEGORY.PROTOCOL)
        or errors.is(err, errors.CATEGORY.TIMEOUT)
    then
      selected.connection:mark_error()
    end

    report_error(
      state,
      selected.address,
      selected.connection.generation,
      err,
      "afterHandshakeCompletes"
    )
  end

  selected.pool:check_in(selected.connection)
end

function METHODS:command(database, command, options)
  if not bson.is_document(command) then
    error("command must be a BSON document", 2)
  end

  local state = EXECUTOR_STATES[self]

  if options and options.on_server_selected ~= nil
      and type(options.on_server_selected) ~= "function"
  then
    error("on_server_selected must be a function", 2)
  end

  if options and options.server_address ~= nil
      and type(options.server_address) ~= "string"
  then
    error("server_address must be a string", 2)
  end

  local selected, err = select_connection(state, operation_for(command, options), options)

  if not selected then
    return nil, err
  end

  local command_options = {}

  for key, value in pairs(options or {}) do
    if key ~= "on_server_selected" and key ~= "server_address" then
      command_options[key] = value
    end
  end

  command_options.minimum_round_trip_time_ms =
    selected.minimum_round_trip_time_ms
  refresh_socket_deadline(command_options)
  local response

  if options and options.on_server_selected then
    options.on_server_selected(selected.address)
  end

  command = decorate_read_preference(selected, command)
  response, err = selected.executor:command(database, command, command_options)
  finish_connection(state, selected, err)
  return response, err
end

function METHODS:measure(database, command, options)
  if not bson.is_document(command) then
    error("command must be a BSON document", 2)
  end

  local state = EXECUTOR_STATES[self]
  local selected, err = select_connection(state, operation_for(command, options), options)

  if not selected then
    return nil, err
  end

  local measurement
  local measure_options = {}

  for key, value in pairs(options or {}) do
    measure_options[key] = value
  end

  measure_options.minimum_round_trip_time_ms =
    selected.minimum_round_trip_time_ms
  refresh_socket_deadline(measure_options)
  command = decorate_read_preference(selected, command)
  measurement, err = selected.executor:measure(database, command, measure_options)
  finish_connection(state, selected, err)
  return measurement, err
end

function METHODS:capabilities()
  local state = EXECUTOR_STATES[self]

  if state.capabilities then
    return state.capabilities
  end

  local selected, err = select_connection(state, "write")

  if not selected then
    return nil, err
  end

  state.capabilities = selected.executor:capabilities()
  finish_connection(state, selected)
  return state.capabilities
end

function METHODS:close()
  local state = EXECUTOR_STATES[self]

  if state.closed then
    return false
  end

  state.closed = true
  local closed = state.topology:close()

  if state.on_close then
    state.on_close()
  end

  return closed
end

function M.new(topology, options)
  if getmetatable(topology) ~= "mongodb.topology" then
    error("topology executor requires a monitored topology", 2)
  end

  options = options or {}

  if type(options) ~= "table" then
    error("topology executor options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "local_threshold_ms" and key ~= "on_close"
        and key ~= "read_preference"
        and key ~= "server_selection_timeout_ms"
    then
      error("unknown topology executor option: " .. tostring(key), 2)
    end
  end

  local value = {}

  if options.on_close ~= nil and type(options.on_close) ~= "function" then
    error("on_close must be a function", 2)
  end

  EXECUTOR_STATES[value] = {
    capabilities = nil,
    closed = false,
    local_threshold_ms = options.local_threshold_ms or 15,
    on_close = options.on_close,
    read_preference = copy_read_preference(options.read_preference or {
      max_staleness_seconds = -1,
      mode = "primary",
      tag_sets = { {} },
    }),
    server_selection_timeout_ms = options.server_selection_timeout_ms or 30000,
    topology = topology,
  }
  return setmetatable(value, METATABLE)
end

return M
