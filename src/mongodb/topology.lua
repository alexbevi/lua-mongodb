local bson = require("mongodb.bson")
local dns_discovery = require("mongodb.discovery.dns")
local errors = require("mongodb.error")
local runtime_contract = require("mongodb.runtime")
local sdam = require("mongodb.sdam")
local selection = require("mongodb.selection")

local M = {}

local MANAGER_STATES = setmetatable({}, { __mode = "k" })
local EVENT_STATES = setmetatable({}, { __mode = "k" })
local MANAGER_METHODS = {}
local start_monitor
local start_rtt_monitor
local start_srv_polling

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
    elseif key == "description" or key == "state" or key == "topology_id"
        or key == "srv_rescan_interval_ms"
    then
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
    check_cancellation = nil,
    check_requested = false,
    last_check_at = nil,
    pool = created,
    rtt_cancellation = nil,
    rtt_sleep_cancellation = nil,
    rtt_task = nil,
    sleep_cancellation = nil,
    task = nil,
  }

  state.servers[address] = server
  publish(state, "ServerOpening", { address = address })
  return server
end


local function cancel_server_monitors(server)
  if server.sleep_cancellation then
    server.sleep_cancellation:cancel("server monitor removed")
  end

  if server.check_cancellation then
    server.check_cancellation:cancel("server monitor removed")
  end

  if server.rtt_cancellation then
    server.rtt_cancellation:cancel("server RTT monitor removed")
  end

  if server.rtt_sleep_cancellation then
    server.rtt_sleep_cancellation:cancel("server RTT monitor removed")
  end
end

local function await_server_monitors(state, server)
  if server.task and server.task:status() == "pending" then
    state.runtime.task:await(server.task)
  end

  if server.rtt_task and server.rtt_task:status() == "pending" then
    state.runtime.task:await(server.rtt_task)
  end
end

local function remove_server(state, address)
  local server = state.servers[address]

  if not server then
    return false
  end

  cancel_server_monitors(server)

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

local function srv_polling_enabled(state)
  return state.srv ~= nil and (
    state.description.type == sdam.TOPOLOGY_TYPE.UNKNOWN
      or state.description.type == sdam.TOPOLOGY_TYPE.SHARDED
  )
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

  if not srv_polling_enabled(state) and state.srv_cancellation then
    state.srv_cancellation:cancel("SRV polling topology type changed")
  end

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

local function record_rtt_sample(state, address, sample)
  local samples = state.rtt_samples[address] or {}

  samples[#samples + 1] = sample

  if #samples > 10 then
    table.remove(samples, 1)
  end

  state.rtt_samples[address] = samples
  local current = state.description:server(address)
  local average = selection.average_rtt(
    current and current.round_trip_time or nil,
    sample
  )
  local minimum = #samples >= 2 and math.min(table.unpack(samples)) or 0

  return average, minimum
end

local function process_check_result(state, address, response, err, fields)
  local server = state.servers[address]

  if not server or state.state ~= "open" then
    return false
  end

  fields = fields or {}
  local duration = fields.duration or 0
  local awaited = fields.awaited == true
  local rtt_sample = fields.rtt_sample
  local succeeded = response ~= nil

  if response then
    if rtt_sample == nil and not awaited then
      rtt_sample = fields.round_trip_time or duration * 1000
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
  local current = state.description:server(address)
  local round_trip_time = current and current.round_trip_time or nil
  local minimum_round_trip_time = current
    and current.minimum_round_trip_time or nil

  if succeeded and type(rtt_sample) == "number" and rtt_sample >= 0 then
    round_trip_time, minimum_round_trip_time = record_rtt_sample(
      state,
      address,
      rtt_sample
    )
  elseif not succeeded then
    state.rtt_samples[address] = nil
    round_trip_time = nil
    minimum_round_trip_time = nil
  end

  local processed = process_description(state, address, response, {
    error = err,
    generation = server.pool.generation or 0,
    last_update_time = state.runtime.clock:now(),
    minimum_round_trip_time = minimum_round_trip_time,
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
  local check_cancellation = state.runtime.cancellation:new()

  server.check_cancellation = check_cancellation
  local response, check_err, round_trip_time = state.check(address, {
    awaited = awaited,
    cancellation = check_cancellation,
    max_await_time_ms = awaited and state.heartbeat_frequency_ms or nil,
    topology_version = awaited and current.topology_version or nil,
  })
  server.check_cancellation = nil
  local duration = state.runtime.clock:now() - started_at

  server.last_check_at = state.runtime.clock:now()
  server.last_awaited = awaited and response ~= nil

  if not response and check_cancellation:is_cancelled()
      and server.check_requested
  then
    return true
  end

  local processed = process_check_result(state, address, response, check_err, {
    awaited = awaited,
    duration = duration,
    round_trip_time = round_trip_time,
    success = response ~= nil,
    timeout = errors.is(check_err, errors.CATEGORY.TIMEOUT),
  })

  current = state.description:server(address)

  if processed and response and current and current.topology_version ~= nil then
    start_rtt_monitor(state, state.manager, address)
  end

  return processed
end

local function monitor_loop(manager, address)
  local state = MANAGER_STATES[manager]

  while state.state == "open" and state.servers[address] do
    local server = state.servers[address]
    local now = state.runtime.clock:now()
    local earliest = server.last_check_at
      and server.last_check_at + state.min_heartbeat_frequency_ms / 1000 or now
    local current = state.description:server(address)
    local streaming = state.server_monitoring_mode ~= "poll"
      and current ~= nil
      and current.type ~= sdam.SERVER_TYPE.UNKNOWN
      and current.topology_version ~= nil
    local delay

    if server.last_awaited or streaming then
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

local function rtt_loop(manager, address)
  local state = MANAGER_STATES[manager]

  while state.state == "open" and state.servers[address] do
    local server = state.servers[address]
    server.rtt_sleep_cancellation = state.runtime.cancellation:new()
    local slept = state.runtime.clock:sleep(
      state.heartbeat_frequency_ms / 1000,
      server.rtt_sleep_cancellation
    )

    server.rtt_sleep_cancellation = nil

    if not slept then
      break
    end

    server = state.servers[address]

    if state.state ~= "open" or not server then
      break
    end

    local sample = state.rtt_check(address, {
      cancellation = server.rtt_cancellation,
    })

    if type(sample) == "number" and sample >= 0 then
      assert(state.lock:acquire())

      if state.state == "open" and state.servers[address]
          and state.description:server(address)
      then
        local average, minimum = record_rtt_sample(state, address, sample)

        state.description = state.description:with_round_trip_times(
          address,
          average,
          minimum
        )
      end

      state.lock:release()
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

start_rtt_monitor = function(state, manager, address)
  local server = state.servers[address]

  if state.background and state.server_monitoring_mode ~= "poll"
      and state.rtt_check and server and server.rtt_task == nil
  then
    server.rtt_cancellation = state.runtime.cancellation:new()
    server.rtt_task = state.runtime.task:spawn(rtt_loop, manager, address)
  end
end

local function srv_polling_loop(manager)
  local state = MANAGER_STATES[manager]

  while state.state == "open" and srv_polling_enabled(state) do
    local cancellation = state.runtime.cancellation:new()

    state.srv_cancellation = cancellation
    local slept = state.runtime.clock:sleep(
      state.srv_rescan_interval_ms / 1000,
      cancellation
    )

    if not slept or cancellation:is_cancelled() then
      break
    end

    manager:rescan_srv()
  end

  state.srv_cancellation = nil
  return true
end

start_srv_polling = function(state, manager)
  if state.background and srv_polling_enabled(state) and state.srv_task == nil then
    state.srv_task = state.runtime.task:spawn(srv_polling_loop, manager)
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
    srv = true,
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

  local srv

  if options.srv ~= nil then
    if type(options.srv) ~= "table"
        or type(options.srv.hostname) ~= "string" or options.srv.hostname == ""
        or type(options.srv.service_name) ~= "string"
        or options.srv.service_name == ""
        or math.type(options.srv.max_hosts) ~= "integer"
        or options.srv.max_hosts < 0
        or math.type(options.srv.minimum_ttl) ~= "integer"
        or options.srv.minimum_ttl < 0
    then
      error("srv must contain valid seedlist discovery metadata", 2)
    end

    if options.srv.random ~= nil and type(options.srv.random) ~= "function" then
      error("srv.random must be a function", 2)
    end

    local allowed_srv = {
      hostname = true,
      max_hosts = true,
      minimum_ttl = true,
      random = true,
      service_name = true,
    }

    for key in pairs(options.srv) do
      if not allowed_srv[key] then
        error("unknown srv polling option: " .. tostring(key), 2)
      end
    end

    srv = {
      hostname = options.srv.hostname,
      max_hosts = options.srv.max_hosts,
      minimum_ttl = options.srv.minimum_ttl,
      random = options.srv.random,
      service_name = options.srv.service_name,
    }
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
    rtt_samples = {},
    runtime = options.runtime,
    rtt_check = options.rtt_check,
    server_monitoring_mode = mode == "auto" and "stream" or mode,
    servers = {},
    srv = srv,
    srv_cancellation = nil,
    srv_rescan_interval_ms = srv
      and math.max(srv.minimum_ttl * 1000, 60000) or nil,
    srv_task = nil,
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
    previous_description = state.description:closed(),
  })

  for _, address in ipairs(state.description:addresses()) do
    add_server(state, address)
  end

  for _, address in ipairs(state.description:addresses()) do
    start_monitor(state, self, address)
  end

  start_srv_polling(state, self)

  return true
end

function MANAGER_METHODS:rescan_srv()
  local state = MANAGER_STATES[self]

  if state.state ~= "open" or not srv_polling_enabled(state) then
    return false
  end

  local result = dns_discovery.poll(state.srv, state.runtime, {
    cancellation = state.srv_cancellation,
    current_addresses = state.description:addresses(),
    random = state.srv.random,
  })

  assert(state.lock:acquire())

  if state.state ~= "open" or not srv_polling_enabled(state) then
    state.lock:release()
    return false
  end

  if result == nil or #result.hosts == 0 then
    state.srv_rescan_interval_ms = state.heartbeat_frequency_ms
    state.lock:release()
    return true
  end

  local addresses = {}

  for index, host in ipairs(result.hosts) do
    addresses[index] = host.host .. ":" .. tostring(host.port)
  end

  local old_description = state.description
  local new_description = old_description:with_srv_hosts(addresses)

  state.srv_rescan_interval_ms = math.max(result.minimum_ttl * 1000, 60000)

  if new_description ~= old_description then
    state.description = new_description
    sync_servers(state, old_description, new_description)
    publish(state, "TopologyDescriptionChanged", {
      new_description = new_description,
      previous_description = old_description,
    })
  end

  state.lock:release()
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
    rtt_sample = options.round_trip_time,
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

  self:request_check(normalized)
  server = state.servers[normalized]

  if server and server.check_cancellation then
    server.check_cancellation:cancel("application error requested a server check")
  end

  state.lock:release()

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

  if options.server_address ~= nil and type(options.server_address) ~= "string" then
    error("server_address must be a string", 2)
  end

  local pinned_selector

  if options.server_address then
    pinned_selector = function(servers)
      local result = {}

      for _, server in ipairs(servers) do
        if server.address == options.server_address then
          result[#result + 1] = server
        end
      end

      return result
    end
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

    local selected

    if options.server_address then
      selected = state.description:server(options.server_address)

      if selected and selected.type == "Unknown" then
        selected = nil
      end
    else
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

      selected = selection.choose(candidates, {
        operation_counts = counts,
        random = options.random,
      })
    end

    if selected and state.servers[selected.address] then
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
        selector = pinned_selector,
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

  if state.srv_cancellation then
    state.srv_cancellation:cancel("topology closed")
  end
  local old_description = state.description
  local new_description = old_description:closed()

  state.description = new_description

  publish(state, "TopologyDescriptionChanged", {
    new_description = new_description,
    previous_description = old_description,
  })

  local addresses = {}

  for address in pairs(state.servers) do
    addresses[#addresses + 1] = address
  end

  table.sort(addresses)

  for _, address in ipairs(addresses) do
    cancel_server_monitors(state.servers[address])
  end

  for _, address in ipairs(addresses) do
    await_server_monitors(state, state.servers[address])
  end

  if state.srv_task and state.srv_task:status() == "pending" then
    state.runtime.task:await(state.srv_task)
  end

  for _, address in ipairs(addresses) do
    remove_server(state, address)
  end

  publish(state, "TopologyClosed")
  return true
end

return M
