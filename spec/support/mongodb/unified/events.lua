local bson = require("mongodb.bson")
local command_security = require("mongodb.command.security")
local errors = require("mongodb.error")

local M = {}

local EVENT_NAMES = {
  command_failed = "commandFailedEvent",
  command_started = "commandStartedEvent",
  command_succeeded = "commandSucceededEvent",
  connection_checkout_started = "connectionCheckOutStartedEvent",
  connection_checked_in = "connectionCheckedInEvent",
  connection_checked_out = "connectionCheckedOutEvent",
  connection_closed = "connectionClosedEvent",
  connection_created = "connectionCreatedEvent",
  connection_ready = "connectionReadyEvent",
  pool_cleared = "poolClearedEvent",
  pool_ready = "poolReadyEvent",
  server_heartbeat_failed = "serverHeartbeatFailedEvent",
  server_heartbeat_started = "serverHeartbeatStartedEvent",
  server_heartbeat_succeeded = "serverHeartbeatSucceededEvent",
  server_description_changed = "serverDescriptionChangedEvent",
  topology_closed = "topologyClosedEvent",
  topology_description_changed = "topologyDescriptionChangedEvent",
  topology_opening = "topologyOpeningEvent",
}
local EVENT_TYPES = {
  commandFailedEvent = "command_failed",
  commandStartedEvent = "command_started",
  commandSucceededEvent = "command_succeeded",
  connectionCheckOutStartedEvent = "connection_checkout_started",
  connectionCheckedInEvent = "connection_checked_in",
  connectionCheckedOutEvent = "connection_checked_out",
  connectionClosedEvent = "connection_closed",
  connectionCreatedEvent = "connection_created",
  connectionReadyEvent = "connection_ready",
  poolClearedEvent = "pool_cleared",
  poolReadyEvent = "pool_ready",
  serverHeartbeatFailedEvent = "server_heartbeat_failed",
  serverHeartbeatStartedEvent = "server_heartbeat_started",
  serverHeartbeatSucceededEvent = "server_heartbeat_succeeded",
  serverDescriptionChangedEvent = "server_description_changed",
  topologyClosedEvent = "topology_closed",
  topologyDescriptionChangedEvent = "topology_description_changed",
  topologyOpeningEvent = "topology_opening",
}
local CMAP_EVENT_TYPES = {
  connection_checkout_started = true,
  connection_checked_in = true,
  connection_checked_out = true,
  connection_closed = true,
  connection_created = true,
  connection_ready = true,
  pool_cleared = true,
  pool_ready = true,
}
local SDAM_EVENT_TYPES = {
  server_description_changed = true,
  topology_closed = true,
  topology_description_changed = true,
  topology_opening = true,
}
local HEARTBEAT_EVENT_TYPES = {
  server_heartbeat_failed = true,
  server_heartbeat_started = true,
  server_heartbeat_succeeded = true,
}
local function configuration_error(message, path, details)
  details = details or {}
  details.path = path or "$"

  return nil, errors.new({
    category = errors.CATEGORY.CONFIGURATION,
    details = details,
    message = message,
  })
end

local function validate_fields(document, allowed, path)
  for key in document:iter() do
    if not allowed[key] then
      return configuration_error("unsupported unified event field: " .. key, path .. "." .. key)
    end
  end

  return true
end

local function string_set(value, path, mapping)
  local result = {}

  if value == nil then
    return result
  end

  if not bson.is_array(value) then
    return configuration_error("unified event option must be an array", path)
  end

  for index, item in value:iter() do
    if type(item) ~= "string" or item == "" then
      return configuration_error(
        "unified event option must contain strings",
        path .. "[" .. index .. "]"
      )
    end

    local normalized = mapping and mapping[item]

    if mapping and not normalized then
      return configuration_error(
        "unsupported observed event type: " .. item,
        path .. "[" .. index .. "]"
      )
    end

    result[normalized or item:lower()] = true
  end

  return result
end


local COLLECTOR_METHODS = {}
local COLLECTOR_METATABLE = { __index = COLLECTOR_METHODS }

local function is_sensitive(event)
  local name = event.command_name:lower()

  if command_security.is_always_sensitive(name) then
    return true
  end

  return (name == "hello" or name == "ismaster")
    and event.command and #event.command == 0
end

local function record(collector, event)
  if not collector.active then
    return
  end

  local name = EVENT_NAMES[event.type]

  if not name or not collector.observed[event.type] then
    return
  end

  if CMAP_EVENT_TYPES[event.type] or SDAM_EVENT_TYPES[event.type]
      or HEARTBEAT_EVENT_TYPES[event.type]
  then
    collector.events[#collector.events + 1] = event
    return
  end

  local command_name = event.command_name:lower()

  if collector.ignored[command_name]
    or command_name == "configurefailpoint"
    or not collector.observe_sensitive and is_sensitive(event)
  then
    return
  end

  collector.events[#collector.events + 1] = event
end

local function topology_description(description)
  if description == nil then
    return nil
  end

  return bson.document({ { "type", description.type } })
end

function COLLECTOR_METHODS:disable()
  self.active = false
end

function COLLECTOR_METHODS:observes_sdam()
  for event_type in pairs(self.observed) do
    if SDAM_EVENT_TYPES[event_type] then
      return true
    end
  end

  return false
end

function COLLECTOR_METHODS:observes_heartbeat()
  for event_type in pairs(self.observed) do
    if HEARTBEAT_EVENT_TYPES[event_type] then
      return true
    end
  end

  return false
end

local function count_matches(event, specification)
  if type(specification) == "string" then
    return event.command_name == specification
  elseif not bson.is_document(specification) then
    return specification == nil
  end

  if #specification == 0 then
    return true
  elseif event.type == "server_description_changed" then
    local new_description = specification:get("newDescription")

    return #specification == 1
      and bson.is_document(new_description)
      and #new_description == 1
      and new_description:get("type") == event.new_description.type
  end

  return #specification == 1
    and specification:get("commandName") == event.command_name
end

function COLLECTOR_METHODS:count(event_name, specification)
  local event_type = EVENT_TYPES[event_name]

  if not event_type then
    return nil
  end

  local count = 0

  for _, event in ipairs(self.events) do
    if event.type == event_type and count_matches(event, specification)
    then
      count = count + 1
    end
  end

  return count
end

function COLLECTOR_METHODS:discard_type(event_type)
  local retained = {}

  for _, event in ipairs(self.events) do
    if event.type ~= event_type then
      retained[#retained + 1] = event
    end
  end

  self.events = retained
end

function COLLECTOR_METHODS:pools_populated(min_pool_size)
  local found = false

  for _, pool in pairs(self.pools) do
    found = true
    local count = 0

    for _ in pairs(pool.connections) do
      count = count + 1
    end

    if count < min_pool_size then
      return false
    end
  end

  return found
end

function COLLECTOR_METHODS:reset()
  self.events = {}
end

function COLLECTOR_METHODS:topology_description()
  return self.current_topology_description
end

function M.new(specification)
  local observed, err = string_set(
    specification:get("observeEvents"),
    "$.client.observeEvents",
    EVENT_TYPES
  )

  if not observed then
    return nil, err
  end

  local ignored
  ignored, err = string_set(
    specification:get("ignoreCommandMonitoringEvents"),
    "$.client.ignoreCommandMonitoringEvents"
  )

  if not ignored then
    return nil, err
  end

  local observe_sensitive = specification:get("observeSensitiveCommands")

  if observe_sensitive ~= nil and type(observe_sensitive) ~= "boolean" then
    return configuration_error(
      "observeSensitiveCommands must be a boolean",
      "$.client.observeSensitiveCommands"
    )
  end

  local collector = setmetatable({
    active = true,
    current_topology_description = nil,
    events = {},
    ignored = ignored,
    observed = observed,
    observe_sensitive = observe_sensitive == true,
    pools = {},
  }, COLLECTOR_METATABLE)

  collector.listener = {
    failed = function(_, event)
      record(collector, event)
    end,
    started = function(_, event)
      record(collector, event)
    end,
    succeeded = function(_, event)
      record(collector, event)
    end,
  }
  collector.pool_listener = {
    ConnectionCheckOutStarted = function(_, event)
      record(collector, {
        address = event.address,
        type = "connection_checkout_started",
      })
    end,
    ConnectionClosed = function(_, event)
      local pool = collector.pools[event.address]

      if pool then
        pool.connections[event.connection_id] = nil
      end

      record(collector, {
        address = event.address,
        connection_id = event.connection_id,
        type = "connection_closed",
      })
    end,
    ConnectionCreated = function(_, event)
      record(collector, {
        address = event.address,
        connection_id = event.connection_id,
        type = "connection_created",
      })
    end,
    ConnectionPoolClosed = function(_, event)
      collector.pools[event.address] = nil
    end,
    ConnectionPoolCleared = function(_, event)
      record(collector, {
        address = event.address,
        interrupt_in_use_connections = event.interrupt_in_use_connections,
        type = "pool_cleared",
      })
    end,
    ConnectionPoolReady = function(_, event)
      collector.pools[event.address] = collector.pools[event.address]
        or { connections = {} }
      record(collector, {
        address = event.address,
        type = "pool_ready",
      })
    end,
    ConnectionCheckedIn = function(_, event)
      record(collector, {
        address = event.address,
        connection_id = event.connection_id,
        type = "connection_checked_in",
      })
    end,
    ConnectionCheckedOut = function(_, event)
      record(collector, {
        address = event.address,
        connection_id = event.connection_id,
        duration_ms = event.duration_ms,
        type = "connection_checked_out",
      })
    end,
    ConnectionReady = function(_, event)
      local pool = collector.pools[event.address]
        or { connections = {} }

      collector.pools[event.address] = pool
      pool.connections[event.connection_id] = true
      record(collector, {
        address = event.address,
        connection_id = event.connection_id,
        duration_ms = event.duration_ms,
        type = "connection_ready",
      })
    end,
  }
  collector.heartbeat_listener = {
    ServerHeartbeatFailed = function(_, event)
      record(collector, {
        address = event.address,
        awaited = event.awaited,
        type = "server_heartbeat_failed",
      })
    end,
    ServerHeartbeatStarted = function(_, event)
      record(collector, {
        address = event.address,
        awaited = event.awaited,
        type = "server_heartbeat_started",
      })
    end,
    ServerHeartbeatSucceeded = function(_, event)
      record(collector, {
        address = event.address,
        awaited = event.awaited,
        type = "server_heartbeat_succeeded",
      })
    end,
  }
  collector.sdam_listener = {
    ServerDescriptionChanged = function(_, event)
      record(collector, {
        address = event.address,
        new_description = {
          type = event.new_description.type,
        },
        type = "server_description_changed",
      })
    end,
    TopologyClosed = function()
      record(collector, { type = "topology_closed" })
    end,
    TopologyDescriptionChanged = function(_, event)
      collector.current_topology_description = event.new_description
      record(collector, {
        new_description = topology_description(event.new_description),
        previous_description = topology_description(event.previous_description),
        type = "topology_description_changed",
      })
    end,
    TopologyOpening = function()
      record(collector, { type = "topology_opening" })
    end,
  }
  return collector
end

local function has_server_connection_id(value)
  return math.type(value) == "integer" and value >= 0
end

local function has_service_id(value)
  return bson.is_tagged(value, "object_id")
end

local function match_event(runner, expected, actual, path)
  if not bson.is_document(expected) or #expected ~= 1 then
    return configuration_error("expected event must contain exactly one event type", path)
  end

  local name, specification = expected:get_at(1)
  local wanted_type = EVENT_TYPES[name]

  if not wanted_type then
    return configuration_error("unsupported expected event type: " .. tostring(name), path)
  end

  if actual.type ~= wanted_type then
    return configuration_error(
      "event type does not match",
      path,
      { actual = actual.type, expected = wanted_type }
    )
  end

  if not bson.is_document(specification) then
    return configuration_error("expected event assertions must be a document", path .. "." .. name)
  end

  local allowed = {
    commandName = true,
    databaseName = true,
    hasServerConnectionId = true,
    hasServiceId = true,
  }

  if name == "topologyDescriptionChangedEvent" then
    allowed = {
      newDescription = true,
      previousDescription = true,
    }
  elseif HEARTBEAT_EVENT_TYPES[wanted_type] then
    allowed = { awaited = true }
  elseif SDAM_EVENT_TYPES[wanted_type] then
    allowed = {}
  elseif name == "poolClearedEvent" then
    allowed = {
      hasServiceId = true,
      interruptInUseConnections = true,
    }
  elseif name == "commandStartedEvent" then
    allowed.command = true
  elseif name == "commandSucceededEvent" then
    allowed.reply = true
  end

  local valid, err = validate_fields(specification, allowed, path .. "." .. name)

  if not valid then
    return nil, err
  end

  for field, expected_value in specification:iter() do
    local field_path = path .. "." .. name .. "." .. field

    if field == "command" then
      local matched
      matched, err = runner:match(expected_value, actual.command, field_path)

      if not matched then
        return nil, err
      end
    elseif field == "reply" then
      local matched
      matched, err = runner:match(expected_value, actual.reply, field_path)

      if not matched then
        return nil, err
      end
    elseif field == "commandName" then
      if actual.command_name ~= expected_value then
        return configuration_error("event command name does not match", field_path)
      end
    elseif field == "databaseName" then
      if actual.database_name ~= expected_value then
        return configuration_error("event database name does not match", field_path)
      end
    elseif field == "awaited" then
      if type(expected_value) ~= "boolean" or actual.awaited ~= expected_value then
        return configuration_error(
          "event awaited state does not match"
            .. " (expected " .. tostring(expected_value)
            .. ", actual " .. tostring(actual.awaited) .. ")",
          field_path
        )
      end
    elseif field == "hasServerConnectionId" then
      if type(expected_value) ~= "boolean"
        or has_server_connection_id(actual.server_connection_id) ~= expected_value
      then
        return configuration_error("event server connection id presence does not match", field_path)
      end
    elseif field == "hasServiceId" then
      if type(expected_value) ~= "boolean"
        or has_service_id(actual.service_id) ~= expected_value
      then
        return configuration_error("event service id presence does not match", field_path)
      end
    elseif field == "interruptInUseConnections" then
      if type(expected_value) ~= "boolean"
        or actual.interrupt_in_use_connections ~= expected_value
      then
        return configuration_error(
          "event interrupt-in-use state does not match",
          field_path
        )
      end
    elseif field == "newDescription" or field == "previousDescription" then
      local actual_description = field == "newDescription"
        and actual.new_description or actual.previous_description
      local matched

      matched, err = runner:match(expected_value, actual_description, field_path)

      if not matched then
        return nil, err
      end
    end
  end

  return true
end

function M.assert_all(runner, expected_groups, collectors, path)
  path = path or "$.expectEvents"

  for _, collector in pairs(collectors) do
    collector:disable()
  end

  for group_index, group in expected_groups:iter() do
    local group_path = path .. "[" .. group_index .. "]"

    if not bson.is_document(group) then
      return configuration_error("expected events for client must be a document", group_path)
    end

    local valid, err = validate_fields(group, {
      client = true,
      events = true,
      eventType = true,
      ignoreExtraEvents = true,
    }, group_path)

    if not valid then
      return nil, err
    end

    local event_type = group:get("eventType") or "command"

    if event_type ~= "command" and event_type ~= "cmap" and event_type ~= "sdam" then
      return configuration_error(
        "unsupported unified event category: " .. tostring(event_type),
        group_path .. ".eventType"
      )
    end

    local client
    client, err = runner:get_entity(group:get("client"), "client", group_path .. ".client")

    if not client then
      return nil, err
    end

    local collector = collectors[client]

    if not collector then
      return configuration_error("client has no unified event collector", group_path .. ".client")
    end

    local expected_events = group:get("events")

    if not bson.is_array(expected_events) then
      return configuration_error("expected client events must be an array", group_path .. ".events")
    end

    local ignore_extra = group:get("ignoreExtraEvents") or false

    if type(ignore_extra) ~= "boolean" then
      return configuration_error(
        "ignoreExtraEvents must be a boolean",
        group_path .. ".ignoreExtraEvents"
      )
    end

    local actual_events = {}

    for _, event in ipairs(collector.events) do
      local category = CMAP_EVENT_TYPES[event.type] and "cmap"
        or (SDAM_EVENT_TYPES[event.type] or HEARTBEAT_EVENT_TYPES[event.type])
          and "sdam"
        or "command"

      if event_type == category then
        actual_events[#actual_events + 1] = event
      end
    end

    if #actual_events < #expected_events
      or not ignore_extra and #actual_events ~= #expected_events
    then
      return configuration_error(
        "observed event count does not match",
        group_path .. ".events",
        { actual = #actual_events, expected = #expected_events }
      )
    end

    for event_index, expected in expected_events:iter() do
      local matched
      matched, err = match_event(
        runner,
        expected,
        actual_events[event_index],
        group_path .. ".events[" .. event_index .. "]"
      )

      if not matched then
        return nil, err
      end
    end
  end

  return true
end

return M
