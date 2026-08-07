local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime")
local sdam = require("mongodb.sdam")
local selection = require("mongodb.selection")

local M = {}

local MANAGER_STATES = setmetatable({}, { __mode = "k" })
local EVENT_STATES = setmetatable({}, { __mode = "k" })
local MANAGER_METHODS = {}
local start_monitor

local DATA_BEARING_TYPES = {
  [sdam.SERVER_TYPE.LOAD_BALANCER] = true,
  [sdam.SERVER_TYPE.MONGOS] = true,
  [sdam.SERVER_TYPE.RS_PRIMARY] = true,
  [sdam.SERVER_TYPE.RS_SECONDARY] = true,
  [sdam.SERVER_TYPE.STANDALONE] = true,
}

local RECOVERING_CODES = {
  [91] = true,
  [189] = true,
  [11600] = true,
  [11602] = true,
  [13436] = true,
}

local NOT_WRITABLE_PRIMARY_CODES = {
  [10058] = true,
  [10107] = true,
  [13435] = true,
}

local SHUTDOWN_CODES = {
  [91] = true,
  [11600] = true,
}

local EVENT_METATABLE = {
  __index = function(value, key)
    local state = EVENT_STATES[value]

    return state and state[key] or nil
  end,
  __metatable = "mongodb.topology.event",
  __newindex = function()
    error("SDAM events are immutable", 2)
  end,
}

local MANAGER_METATABLE = {
  __index = function(value, key)
    if MANAGER_METHODS[key] then
      return MANAGER_METHODS[key]
    end

    local state = MANAGER_STATES[value]

    if not state then
      return nil
    elseif key == "description" or key == "state" or key == "topology_id" then
      return state[key]
    end
  end,
  __metatable = "mongodb.topology",
  __newindex = function()
    error("topology managers expose immutable state", 2)
  end,
}

local function new_event(fields)
  local event = {}

  EVENT_STATES[event] = fields
  return setmetatable(event, EVENT_METATABLE)
end

local function callback_for(listener, event_type)
  if type(listener) == "function" then
    return listener, false
  end

  return listener[event_type] or listener.event, true
end

local function publish(state, event_type, fields, heartbeat)
  fields = fields or {}
  fields.awaited = fields.awaited or false
  fields.topology_id = state.topology_id
  fields.type = event_type
  local event = new_event(fields)
  local listeners = heartbeat and state.heartbeat_listeners or state.listeners

  for _, listener in ipairs(listeners) do
    local callback, method = callback_for(listener, event_type)

    if callback then
      local ok, listener_err

      if method then
        ok, listener_err = pcall(callback, listener, event)
      else
        ok, listener_err = pcall(callback, event)
      end

      if not ok and state.on_listener_error then
        pcall(state.on_listener_error, listener_err)
      end
    end
  end

  return event
end

local function publish_heartbeat(state, event_type, fields)
  return publish(state, event_type, fields, true)
end

local function validate_listeners(name, listeners)
  listeners = listeners or {}

  if type(listeners) ~= "table" then
    error(name .. " must be an array", 3)
  end

  local result = {}

  for index = 1, #listeners do
    local listener = listeners[index]

    if type(listener) ~= "function" and type(listener) ~= "table" then
      error(name .. " must contain functions or tables", 3)
    end

    result[index] = listener
  end

  for key in pairs(listeners) do
    if math.type(key) ~= "integer" or key < 1 or key > #listeners then
      error(name .. " must be a dense array", 3)
    end
  end

  return result
end

local function no_op_pool()
  local value = { generation = 0, operation_count = 0, state = "paused" }

  function value:ready()
    if self.state == "closed" then
      return false
    end

    self.state = "ready"
    return true
  end

  function value:clear()
    if self.state == "closed" then
      return false
    end

    self.generation = self.generation + 1
    self.state = "paused"
    return true
  end

  function value:close()
    if self.state == "closed" then
      return false
    end

    self.state = "closed"
    return true
  end

  return value
end

local function topology_error(message, options)
  options = options or {}

  return errors.new({
    category = errors.CATEGORY.TOPOLOGY,
    details = options.details,
    message = message,
    server = options.server,
  })
end

local function copy_addresses(description)
  local result = {}

  for _, address in ipairs(description:addresses()) do
    result[address] = true
  end

  return result
end

local function address_for(state, address)
  local server = state.description:server(address)

  return server and server.address or nil
end

local function add_server(state, address)
  if state.servers[address] then
    return state.servers[address]
  end

  local created = state.pool_factory(address)

  if type(created) ~= "table" or type(created.ready) ~= "function"
      or type(created.clear) ~= "function" or type(created.close) ~= "function"
  then
    error("pool_factory must return a pool with ready, clear, and close methods", 3)
  end

  local server = {
    address = address,
    check_requested = false,
    last_check_at = nil,
    pool = created,
    sleep_cancellation = nil,
    task = nil,
  }

  state.servers[address] = server
  publish(state, "ServerOpening", { address = address })
  return server
end


local function remove_server(state, address)
  local server = state.servers[address]

  if not server then
    return false
  end

  if server.sleep_cancellation then
    server.sleep_cancellation:cancel("server monitor removed")
  end

  if server.task and server.task:status() == "pending" then
    state.runtime.task:cancel(server.task, "server monitor removed")
  end

  server.pool:close()

  if state.on_server_close then
    state.on_server_close(address)
  end

  state.servers[address] = nil
  publish(state, "ServerClosed", { address = address })
  return true
end

local function sync_servers(state, old_description, new_description)
  local old_addresses = copy_addresses(old_description)
  local new_addresses = copy_addresses(new_description)

  for address in pairs(old_addresses) do
    if not new_addresses[address] then
      remove_server(state, address)
    end
  end

  for _, address in ipairs(new_description:addresses()) do
    if not old_addresses[address] then
      add_server(state, address)
    end
  end

  for address in pairs(new_addresses) do
    start_monitor(state, state.manager, address)
  end
end

local function ready_pool(state, address, server_description)
  if DATA_BEARING_TYPES[server_description.type]
      or state.description.type == sdam.TOPOLOGY_TYPE.SINGLE
        and server_description.type ~= sdam.SERVER_TYPE.UNKNOWN
  then
    return state.servers[address].pool:ready()
  end

  return true
end

local function process_description(state, address, response, options)
  local old_topology = state.description
  local old_server = old_topology:server(address)
  local updated = old_topology:update(address, response, options)

  if updated == old_topology then
    return true
  end

  local new_server = updated:server(address)
  local changed = old_server ~= nil and new_server ~= nil
    and not old_server:equals(new_server)

  state.description = updated

  if new_server then
    ready_pool(state, new_server.address, new_server)
  end

  if changed then
    publish(state, "ServerDescriptionChanged", {
      address = address,
      new_description = new_server,
      previous_description = old_server,
    })
  end

  sync_servers(state, old_topology, updated)

  if changed or #old_topology:addresses() ~= #updated:addresses()
      or old_topology.type ~= updated.type
  then
    publish(state, "TopologyDescriptionChanged", {
      new_description = updated,
      previous_description = old_topology,
    })
  end

  return true
end

local function process_check_result(state, address, response, err, fields)
  local server = state.servers[address]

  if not server or state.state ~= "open" then
    return false
  end

  fields = fields or {}
  local duration = fields.duration or 0
  local awaited = fields.awaited == true
  local current = state.description:server(address)
  local round_trip_time = fields.round_trip_time

  if awaited and round_trip_time == nil and current then
    round_trip_time = current.round_trip_time
  end

  if response then
    if round_trip_time == nil and not awaited then
      round_trip_time = selection.average_rtt(
        current and current.round_trip_time or nil,
        duration * 1000
      )
    end

    publish_heartbeat(state, "ServerHeartbeatSucceeded", {
      address = address,
      awaited = awaited,
      duration = duration,
      reply = response,
    })
  else
    if not errors.is(err) then
      err = topology_error("server heartbeat failed", { server = address })
    end

    publish_heartbeat(state, "ServerHeartbeatFailed", {
      address = address,
      awaited = awaited,
      duration = duration,
      error = err,
    })
    response = bson.document({})
  end

  assert(state.lock:acquire())
  local processed = process_description(state, address, response, {
    error = err,
    generation = server.pool.generation or 0,
    last_update_time = state.runtime.clock:now(),
    round_trip_time = round_trip_time,
  })

  if not fields.success and state.servers[address] then
    state.servers[address].pool:clear(fields.timeout == true)
    state.description = state.description:with_generation(
      address,
      state.servers[address].pool.generation or 0
    )
  end

  state.lock:release()
  return processed
end

local function monitor_once(state, address)
  local server = state.servers[address]

  if not server or state.state ~= "open" then
    return false
  end

  local current = state.description:server(address)
  local awaited = state.server_monitoring_mode ~= "poll"
    and current ~= nil
    and current.type ~= sdam.SERVER_TYPE.UNKNOWN
    and current.topology_version ~= nil
  local started_at = state.runtime.clock:now()

  publish_heartbeat(state, "ServerHeartbeatStarted", {
    address = address,
    awaited = awaited,
  })
  local response, check_err, round_trip_time = state.check(address, {
    awaited = awaited,
    cancellation = state.cancellation,
    max_await_time_ms = awaited and state.heartbeat_frequency_ms or nil,
    topology_version = awaited and current.topology_version or nil,
  })
  local duration = state.runtime.clock:now() - started_at

  if response and awaited and state.rtt_check then
    local rtt_sample = state.rtt_check(address, {
      cancellation = state.cancellation,
    })

    if type(rtt_sample) == "number" and rtt_sample >= 0 then
      round_trip_time = selection.average_rtt(
        current.round_trip_time,
        rtt_sample
      )
    end
  end

  server.last_check_at = state.runtime.clock:now()
  server.last_awaited = awaited and response ~= nil
  return process_check_result(state, address, response, check_err, {
    awaited = awaited,
    duration = duration,
    round_trip_time = round_trip_time,
    success = response ~= nil,
    timeout = errors.is(check_err, errors.CATEGORY.TIMEOUT),
  })
end

local function monitor_loop(manager, address)
  local state = MANAGER_STATES[manager]

  while state.state == "open" and state.servers[address] do
    local server = state.servers[address]
    local now = state.runtime.clock:now()
    local earliest = server.last_check_at
      and server.last_check_at + state.min_heartbeat_frequency_ms / 1000 or now
    local delay

    if server.last_awaited then
      delay = 0
    elseif server.check_requested then
      delay = math.max(0, earliest - now)
      server.check_requested = false
    else
      delay = math.max(
        earliest - now,
        state.heartbeat_frequency_ms / 1000
      )
    end

    if server.last_check_at == nil then
      delay = 0
    end

    if delay > 0 then
      server.sleep_cancellation = state.runtime.cancellation:new()
      state.runtime.clock:sleep(delay, server.sleep_cancellation)
      server.sleep_cancellation = nil
    end

    if state.state == "open" and state.servers[address] then
      monitor_once(state, address)
    end
  end

  return true
end

start_monitor = function(state, manager, address)
  local server = state.servers[address]

  if state.background and server and server.task == nil then
    server.task = state.runtime.task:spawn(monitor_loop, manager, address)
  end
end

local function command_error(response, address)
  local code = response and response:get("code")

  if bson.is_exact(code) then
    code = code:to_number()
  end

  local message = response and response:get("errmsg") or "command failed"

  return errors.new({
    category = errors.CATEGORY.SERVER,
    code = math.type(code) == "integer" and code or nil,
    details = response and { response = response } or nil,
    message = type(message) == "string" and message or "command failed",
    server = address,
  })
end

local function topology_version_is_stale(current, incoming)
  if current == nil or incoming == nil then
    return false
  end

  if current:get("processId") ~= incoming:get("processId") then
    return false
  end

  local current_counter = current:get("counter")
  local incoming_counter = incoming:get("counter")

  if bson.is_exact(current_counter) then
    current_counter = current_counter:to_number()
  end

  if bson.is_exact(incoming_counter) then
    incoming_counter = incoming_counter:to_number()
  end

  return current_counter >= incoming_counter
end

local function state_change_kind(response)
  local code = response:get("code")

  if bson.is_exact(code) then
    code = code:to_number()
  end

  if math.type(code) == "integer" then
    if RECOVERING_CODES[code] then
      return "recovering", code
    elseif NOT_WRITABLE_PRIMARY_CODES[code] then
      return "notWritablePrimary", code
    end

    return nil, code
  end

  local message = response:get("errmsg")

  if type(message) ~= "string" then
    return nil
  elseif message:find("not master or secondary", 1, true)
      or message:find("node is recovering", 1, true)
  then
    return "recovering"
  elseif message:find("not master", 1, true) then
    return "notWritablePrimary"
  end

  return nil
end

function M.new(options)
  if type(options) ~= "table" then
    error("topology manager options must be a table", 2)
  end

  local allowed = {
    check = true,
    heartbeat_frequency_ms = true,
    heartbeat_listeners = true,
    listeners = true,
    min_heartbeat_frequency_ms = true,
    on_listener_error = true,
    on_server_close = true,
    pool_factory = true,
    runtime = true,
    rtt_check = true,
    seeds = true,
    server_monitoring_mode = true,
    set_name = true,
    topology_id = true,
    type = true,
  }

  for key in pairs(options) do
    if not allowed[key] then
      error("unknown topology manager option: " .. tostring(key), 2)
    end
  end

  runtime_contract.validate(options.runtime)

  if options.check ~= nil and type(options.check) ~= "function" then
    error("topology check adapter must be a function", 2)
  end

  if options.pool_factory ~= nil and type(options.pool_factory) ~= "function" then
    error("pool_factory must be a function", 2)
  end

  if options.rtt_check ~= nil and type(options.rtt_check) ~= "function" then
    error("topology RTT check adapter must be a function", 2)
  end

  if options.on_listener_error ~= nil
      and type(options.on_listener_error) ~= "function"
  then
    error("on_listener_error must be a function", 2)
  end

  if options.on_server_close ~= nil and type(options.on_server_close) ~= "function" then
    error("on_server_close must be a function", 2)
  end

  local heartbeat_frequency_ms = options.heartbeat_frequency_ms or 10000
  local min_heartbeat_frequency_ms = options.min_heartbeat_frequency_ms or 500

  for name, value in pairs({
    heartbeat_frequency_ms = heartbeat_frequency_ms,
    min_heartbeat_frequency_ms = min_heartbeat_frequency_ms,
  }) do
    if type(value) ~= "number" or value ~= value or value <= 0
        or value == math.huge
    then
      error(name .. " must be a finite positive number", 2)
    end
  end

  local mode = options.server_monitoring_mode or "auto"

  if mode ~= "auto" and mode ~= "poll" and mode ~= "stream" then
    error("server_monitoring_mode must be auto, poll, or stream", 2)
  end

  local description = sdam.new({
    seeds = options.seeds,
    set_name = options.set_name,
    type = options.type,
  })
  local value = {}
  local listeners = validate_listeners("listeners", options.listeners)
  local heartbeat_listeners = validate_listeners(
    "heartbeat_listeners",
    options.heartbeat_listeners
  )

  local state = {
    background = false,
    cancellation = options.runtime.cancellation:new(),
    check = options.check or function(address)
      return nil, topology_error("no check adapter for " .. address, { server = address })
    end,
    description = description,
    heartbeat_frequency_ms = heartbeat_frequency_ms,
    heartbeat_listeners = heartbeat_listeners,
    listeners = listeners,
    lock = options.runtime.lock:new(),
    min_heartbeat_frequency_ms = min_heartbeat_frequency_ms,
    on_listener_error = options.on_listener_error,
    on_server_close = options.on_server_close,
    pool_factory = options.pool_factory or no_op_pool,
    runtime = options.runtime,
    rtt_check = options.rtt_check,
    server_monitoring_mode = mode == "auto" and "stream" or mode,
    servers = {},
    state = "closed",
    topology_id = options.topology_id or tostring(value),
  }
  state.manager = value
  MANAGER_STATES[value] = state
  return setmetatable(value, MANAGER_METATABLE)
end

function MANAGER_METHODS:open(options)
  local state = MANAGER_STATES[self]

  options = options or {}

  if type(options) ~= "table" then
    error("topology open options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "background" then
      error("unknown topology open option: " .. tostring(key), 2)
    end
  end

  if options.background ~= nil and type(options.background) ~= "boolean" then
    error("background must be a boolean", 2)
  end

  if state.state == "open" then
    return true
  elseif state.state == "closed_permanently" then
    return nil, topology_error("topology is closed")
  end

  state.state = "open"
  state.background = options.background ~= false
  publish(state, "TopologyOpening")
  publish(state, "TopologyDescriptionChanged", {
    new_description = state.description,
    previous_description = nil,
  })

  for _, address in ipairs(state.description:addresses()) do
    add_server(state, address)
  end

  for _, address in ipairs(state.description:addresses()) do
    start_monitor(state, self, address)
  end

  return true
end

function MANAGER_METHODS:process_hello(address, response, options)
  local state = MANAGER_STATES[self]

  if state.state ~= "open" then
    return false
  end

  local normalized = address_for(state, address)

  if not normalized then
    return false
  end

  if not bson.is_document(response) then
    error("hello response must be a BSON document", 2)
  end

  options = options or {}

  if type(options) ~= "table" then
    error("hello processing options must be a table", 2)
  end

  publish_heartbeat(state, "ServerHeartbeatStarted", {
    address = normalized,
    awaited = options.awaited == true,
  })
  local success = #response > 0
  local heartbeat_err

  if not success then
    heartbeat_err = topology_error("server heartbeat failed", {
      server = normalized,
    })
  end

  return process_check_result(state, normalized, success and response or nil, heartbeat_err, {
    awaited = options.awaited == true,
    duration = options.duration or 0,
    round_trip_time = options.round_trip_time,
    success = success,
  })
end

function MANAGER_METHODS:check_server(address)
  local state = MANAGER_STATES[self]
  local normalized = address_for(state, address)

  if not normalized then
    return false
  end

  return monitor_once(state, normalized)
end

function MANAGER_METHODS:request_check(address)
  local state = MANAGER_STATES[self]
  local normalized = address_for(state, address)

  if not normalized then
    return false
  end

  local server = state.servers[normalized]

  server.check_requested = true

  if server.sleep_cancellation then
    server.sleep_cancellation:cancel("immediate server check requested")
  end

  return true
end


function MANAGER_METHODS:request_check_all()
  local state = MANAGER_STATES[self]

  for address in pairs(state.servers) do
    self:request_check(address)
  end

  return true
end


function MANAGER_METHODS:pool(address)
  local state = MANAGER_STATES[self]
  local normalized = address_for(state, address)
  local server = normalized and state.servers[normalized]

  return server and server.pool or nil
end

function MANAGER_METHODS:handle_application_error(address, fields)
  local state = MANAGER_STATES[self]
  local normalized = address_for(state, address)

  if not normalized then
    return false
  end

  if type(fields) ~= "table" then
    error("application error fields must be a table", 2)
  end

  local allowed = {
    error = true,
    generation = true,
    labels = true,
    max_wire_version = true,
    response = true,
    type = true,
    when = true,
  }

  for key in pairs(fields) do
    if not allowed[key] then
      error("unknown application error field: " .. tostring(key), 2)
    end
  end

  local server = state.servers[normalized]
  local pool = server.pool
  local generation = fields.generation

  if generation == nil then
    generation = pool.generation or 0
  elseif math.type(generation) ~= "integer" or generation < 0 then
    error("application error generation must be a non-negative integer", 2)
  end

  if generation < (pool.generation or 0) then
    return false
  end

  local response = fields.response
  local current = state.description:server(normalized)
  local incoming_version = bson.is_document(response)
    and response:get("topologyVersion") or nil

  if topology_version_is_stale(current.topology_version, incoming_version) then
    return false
  end

  local labels = {}

  for _, label in ipairs(fields.labels or {}) do
    labels[label] = true
  end

  if fields.error and errors.has_label(fields.error, "SystemOverloadedError")
      or labels.SystemOverloadedError
  then
    return false
  end

  local kind = fields.type

  if kind ~= "command" and kind ~= "handshake"
      and kind ~= "network" and kind ~= "timeout"
  then
    error("application error type must be command, handshake, network, or timeout", 2)
  end

  local before_handshake = fields.when == "beforeHandshakeCompletes"

  if fields.when ~= nil and not before_handshake
      and fields.when ~= "afterHandshakeCompletes"
  then
    error("application error when value is invalid", 2)
  end

  if before_handshake and kind ~= "command" and kind ~= "handshake" then
    return false
  end

  if kind == "timeout" then
    return false
  end

  local clear_pool
  local request_check = false
  local err = fields.error

  if kind == "network" or kind == "handshake" then
    clear_pool = true
    err = err or (kind == "network" and errors.new({
        category = errors.CATEGORY.NETWORK,
        message = "application network error",
        server = normalized,
      }) or topology_error("connection handshake failed", { server = normalized }))
  else
    if not bson.is_document(response) then
      error("command application errors require a BSON response", 2)
    end

    local state_change, code = state_change_kind(response)

    if not state_change then
      return false
    end

    clear_pool = SHUTDOWN_CODES[code] == true or before_handshake
    request_check = true
    err = err or command_error(response, normalized)
  end

  assert(state.lock:acquire())
  local failure_response = response

  if not bson.is_document(failure_response) then
    failure_response = bson.document({})
  end

  process_description(state, normalized, failure_response, {
    error = err,
    generation = generation,
    last_update_time = state.runtime.clock:now(),
  })

  if clear_pool and state.servers[normalized] then
    pool:clear(false)
    state.description = state.description:with_generation(
      normalized,
      pool.generation or 0
    )
  end

  state.lock:release()

  if request_check then
    self:request_check(normalized)
  end

  return true
end

function MANAGER_METHODS:select_server(operation, preference, options)
  local state = MANAGER_STATES[self]

  if state.state ~= "open" then
    return nil, topology_error("topology is closed")
  end

  options = options or {}

  if type(options) ~= "table" then
    error("topology selection options must be a table", 2)
  end

  local deadline = options.deadline

  if deadline == nil then
    deadline = runtime_contract.deadline_after(
      state.runtime,
      (options.timeout_ms or 30000) / 1000
    )
  end

  while true do
    local counts = {}

    for address, server in pairs(state.servers) do
      counts[address] = server.pool.operation_count or 0
    end

    local candidates, candidate_err = selection.candidates(
      state.description,
      operation,
      preference,
      {
        deprioritized_servers = options.deprioritized_servers,
        heartbeat_frequency_ms = state.heartbeat_frequency_ms,
        local_threshold_ms = options.local_threshold_ms,
      }
    )

    if not candidates then
      return nil, candidate_err
    end

    local selected = selection.choose(candidates, {
      operation_counts = counts,
      random = options.random,
    })

    if selected then
      return selected, state.servers[selected.address].pool
    end

    local ok = runtime_contract.check(
      state.runtime,
      deadline,
      options.cancellation
    )

    if not ok then
      return selection.select(state.description, operation, preference, {
        deprioritized_servers = options.deprioritized_servers,
        heartbeat_frequency_ms = state.heartbeat_frequency_ms,
        local_threshold_ms = options.local_threshold_ms,
        operation_counts = counts,
        timeout_ms = math.max(0, (deadline - state.runtime.clock:now()) * 1000),
      })
    end

    self:request_check_all()

    if not state.background then
      for _, address in ipairs(state.description:addresses()) do
        self:check_server(address)
      end
    end

    local remaining = runtime_contract.remaining(state.runtime, deadline)
    local slept, sleep_err = state.runtime.clock:sleep(
      math.min(state.min_heartbeat_frequency_ms / 1000, remaining or math.huge),
      options.cancellation
    )

    if not slept then
      return nil, sleep_err
    end
  end
end

function MANAGER_METHODS:close()
  local state = MANAGER_STATES[self]

  if state.state == "closed_permanently" then
    return false
  end

  state.state = "closed_permanently"
  state.cancellation:cancel("topology closed")
  local old_description = state.description

  publish(state, "TopologyDescriptionChanged", {
    new_description = nil,
    previous_description = old_description,
  })

  local addresses = {}

  for address in pairs(state.servers) do
    addresses[#addresses + 1] = address
  end

  table.sort(addresses)

  for _, address in ipairs(addresses) do
    remove_server(state, address)
  end

  publish(state, "TopologyClosed")
  return true
end

return M
