local errors = require("mongodb.error")
local operation_timeout = require("mongodb.operation_timeout")
local runtime_contract = require("mongodb.runtime")

local M = {}

local POOL_STATES = setmetatable({}, { __mode = "k" })
local CONNECTION_STATES = setmetatable({}, { __mode = "k" })
local EVENT_STATES = setmetatable({}, { __mode = "k" })
local POOL_METHODS = {}
local CONNECTION_METHODS = {}
local POOL_PROPERTIES = {
  address = true,
  generation = true,
  max_connecting = true,
  max_idle_time_ms = true,
  max_pool_size = true,
  min_pool_size = true,
  options = true,
  state = true,
  wait_queue_timeout_ms = true,
}
local CONNECTION_PROPERTIES = {
  address = true,
  generation = true,
  id = true,
  interrupted = true,
  resource = true,
  state = true,
}

local EVENT_METATABLE = {
  __index = function(value, key)
    local state = EVENT_STATES[value]

    if state then
      return state[key]
    end
  end,
  __metatable = "mongodb.pool.event",
  __newindex = function()
    error("CMAP events are immutable", 2)
  end,
}

local POOL_METATABLE = {
  __index = function(value, key)
    if POOL_METHODS[key] then
      return POOL_METHODS[key]
    end

    local state = POOL_STATES[value]

    if not state then
      return nil
    elseif key == "available_connection_count" then
      return #state.available
    elseif key == "operation_count" then
      return state.operation_count
    elseif key == "pending_connection_count" then
      return state.pending_count
    elseif key == "total_connection_count" then
      return state.total_count
    end

    if POOL_PROPERTIES[key] then
      return state[key]
    end
  end,
  __metatable = "mongodb.pool",
  __newindex = function()
    error("connection pools expose immutable state", 2)
  end,
}

local CONNECTION_METATABLE = {
  __index = function(value, key)
    if CONNECTION_METHODS[key] then
      return CONNECTION_METHODS[key]
    end

    local state = CONNECTION_STATES[value]

    if state and CONNECTION_PROPERTIES[key] then
      return state[key]
    end
  end,
  __metatable = "mongodb.pool.connection",
  __newindex = function()
    error("pooled connections expose immutable state", 2)
  end,
}

local function readonly_copy(values)
  local data = {}

  for key, value in pairs(values) do
    data[key] = value
  end

  return setmetatable({}, {
    __index = data,
    __metatable = "mongodb.pool.options",
    __newindex = function()
      error("pool options are immutable", 2)
    end,
    __pairs = function()
      return next, data, nil
    end,
  })
end

local function new_event(fields)
  local value = {}

  EVENT_STATES[value] = fields
  return setmetatable(value, EVENT_METATABLE)
end

local function publish(state, event_type, fields)
  fields = fields or {}
  fields.address = state.address
  fields.type = event_type
  local event = new_event(fields)

  for _, listener in ipairs(state.listeners) do
    local callback = type(listener) == "function" and listener
      or listener[event_type] or listener.event

    if callback then
      local ok, listener_err

      if type(listener) == "function" then
        ok, listener_err = pcall(callback, event)
      else
        ok, listener_err = pcall(callback, listener, event)
      end

      if not ok and state.on_listener_error then
        pcall(state.on_listener_error, listener_err)
      end
    end
  end

  return event
end

local function duration_ms(state, started_at)
  return math.max(0, (state.runtime.clock:now() - started_at) * 1000)
end

local function pool_error(state, reason, message, options)
  options = options or {}

  return errors.new({
    category = errors.CATEGORY.POOL,
    details = {
      address = state.address,
      reason = reason,
    },
    message = message,
    retryable = options.retryable,
    server = state.address,
    timeout = options.timeout,
  })
end

local function paused_error(state)
  return pool_error(
    state,
    "connectionError",
    "connection pool for " .. state.address .. " is paused",
    { retryable = true }
  )
end

local function closed_error(state)
  return pool_error(
    state,
    "poolClosed",
    "Attempted to check out a connection from closed connection pool"
  )
end

local function wait_timeout_error(state)
  return pool_error(
    state,
    "timeout",
    string.format(
      "Timed out while checking out a connection from connection pool at %s; "
        .. "maxPoolSize: %s, timeout: %sms",
      state.address,
      tostring(state.max_pool_size),
      tostring(state.wait_queue_timeout_ms)
    ),
    { timeout = true }
  )
end

local function acquire(state, deadline, cancellation)
  return state.lock:acquire(deadline, cancellation)
end

local function remove_value(values, wanted)
  for index, value in ipairs(values) do
    if value == wanted then
      table.remove(values, index)
      return true
    end
  end

  return false
end

local function close_resource(resource)
  if resource and type(resource.close) == "function" then
    pcall(resource.close, resource)
  end
end

local function finish_close(state, connection, reason)
  local connection_state = CONNECTION_STATES[connection]

  publish(state, "ConnectionClosed", {
    connection_id = connection_state.id,
    reason = reason,
  })

  if not connection_state.resource_closed then
    connection_state.resource_closed = true
    close_resource(connection_state.resource)
  end
end

local function detach_locked(state, connection)
  local connection_state = CONNECTION_STATES[connection]

  if not connection_state or connection_state.state == "closed" then
    return false
  end

  if connection_state.state == "available" then
    remove_value(state.available, connection)
  elseif connection_state.state == "pending" then
    state.pending_count = state.pending_count - 1
    state.pending[connection] = nil
  elseif connection_state.state == "in_use" then
    state.in_use[connection] = nil
    state.in_use_count = state.in_use_count - 1
  end

  connection_state.state = "closed"
  state.connections[connection] = nil
  state.total_count = state.total_count - 1
  return true
end

local function new_connection_locked(state)
  local connection = {}
  local connection_state = {
    address = state.address,
    created_at = state.runtime.clock:now(),
    generation = state.generation,
    id = state.next_connection_id,
    owner = state.pool,
    resource = nil,
    setup_cancellation = state.runtime.cancellation:new(),
    state = "pending",
  }

  state.next_connection_id = state.next_connection_id + 1
  state.pending_count = state.pending_count + 1
  state.total_count = state.total_count + 1
  state.connections[connection] = true
  state.pending[connection] = true
  CONNECTION_STATES[connection] = connection_state
  return setmetatable(connection, CONNECTION_METATABLE)
end

local function add_backpressure_labels(err)
  if not errors.is(err, errors.CATEGORY.NETWORK)
      and not errors.is(err, errors.CATEGORY.TIMEOUT)
  then
    return err
  end

  local details = err.details

  if details and (details.phase == "authentication" or details.never_overload == true) then
    return err
  end

  err = errors.with_label(err, "SystemOverloadedError")
  return errors.with_label(err, "RetryableError")
end

local function establish(
  pool,
  connection,
  target_state,
  deadline,
  cancellation,
  defer_failure_close
)
  local state = POOL_STATES[pool]
  local connection_state = CONNECTION_STATES[connection]
  local unsubscribe = function() end

  if cancellation then
    unsubscribe = cancellation:on_cancel(function(reason)
      connection_state.setup_cancellation:cancel(reason)
    end)
  end

  publish(state, "ConnectionCreated", {
    connection_id = connection_state.id,
  })
  local resource, connect_err = state.connect({
    address = state.address,
    cancellation = connection_state.setup_cancellation,
    deadline = deadline,
    generation = connection_state.generation,
    id = connection_state.id,
  })

  unsubscribe()

  if resource == nil and not errors.is(connect_err) then
    error("pool connection adapter must return a resource or structured error", 3)
  elseif resource ~= nil and type(resource) ~= "table" then
    error("pool connection adapter resource must be a table", 3)
  end

  if not resource then
    connect_err = add_backpressure_labels(connect_err)
    assert(acquire(state))
    local detached = detach_locked(state, connection)
    local reported = false

    state.lock:release()

    if detached and not defer_failure_close then
      if errors.is(connect_err, errors.CATEGORY.AUTHENTICATION)
          and state.on_connection_error
      then
        local callback_ok, decision = pcall(state.on_connection_error, connect_err)

        reported = callback_ok and type(decision) == "boolean"
      end

      finish_close(state, connection, "error")
    end

    return nil, connect_err, detached, reported
  end

  connection_state.resource = resource
  publish(state, "ConnectionReady", {
    connection_id = connection_state.id,
    duration_ms = duration_ms(state, connection_state.created_at),
  })

  assert(acquire(state))
  state.pending_count = state.pending_count - 1
  state.pending[connection] = nil
  local usable = state.state == "ready"
    and connection_state.generation == state.generation
    and not connection_state.setup_cancellation:is_cancelled()

  if usable then
    connection_state.state = target_state

    if target_state == "available" then
      connection_state.last_available_at = state.runtime.clock:now()
      state.available[#state.available + 1] = connection
    else
      state.in_use[connection] = true
      state.in_use_count = state.in_use_count + 1
    end
  else
    connection_state.state = "closed"
    state.connections[connection] = nil
    state.total_count = state.total_count - 1
  end

  state.lock:release()

  if not usable then
    local reason = state.state == "closed" and "poolClosed" or "stale"

    finish_close(state, connection, reason)
    return nil, state.state == "closed" and closed_error(state) or paused_error(state)
  end

  return connection
end

local function schedule_maintenance(pool, delayed)
  local state = POOL_STATES[pool]

  if state.maintenance_scheduled or state.state == "closed" then
    return false
  end

  state.maintenance_scheduled = true
  state.maintenance_task = state.runtime.task:spawn(function()
    if delayed then
      local slept, sleep_err = state.runtime.clock:sleep(state.poll_interval)

      if not slept then
        state.maintenance_scheduled = false
        return nil, sleep_err
      end
    end

    state.maintenance_scheduled = false
    return pool:maintain()
  end)
  return true
end

local function normalize_listeners(listeners)
  listeners = listeners or {}

  if type(listeners) ~= "table" then
    error("pool listeners must be an array", 3)
  end

  local result = {}

  for index = 1, #listeners do
    local listener = listeners[index]

    if type(listener) ~= "function" and type(listener) ~= "table" then
      error("pool listeners must be functions or tables", 3)
    end

    result[index] = listener
  end

  for key in pairs(listeners) do
    if math.type(key) ~= "integer" or key < 1 or key > #listeners then
      error("pool listeners must be a dense array", 3)
    end
  end

  return result
end

local function require_integer(name, value, minimum)
  if math.type(value) ~= "integer" or value < minimum then
    error(name .. " must be an integer of at least " .. minimum, 3)
  end

  return value
end

local function validate_options(options)
  if type(options) ~= "table" then
    error("pool options must be a table", 3)
  end

  local allowed = {
    address = true,
    connect = true,
    listeners = true,
    max_connecting = true,
    max_idle_time_ms = true,
    max_pool_size = true,
    min_pool_size = true,
    on_connection_error = true,
    on_listener_error = true,
    poll_interval_ms = true,
    runtime = true,
    wait_queue_timeout_ms = true,
  }

  for key in pairs(options) do
    if not allowed[key] then
      error("unknown pool option: " .. tostring(key), 3)
    end
  end

  if type(options.address) ~= "string" or options.address == "" then
    error("pool address must be a non-empty string", 3)
  end

  if type(options.connect) ~= "function" then
    error("pool connect adapter must be a function", 3)
  end

  runtime_contract.validate(options.runtime)

  for _, name in ipairs({ "on_connection_error", "on_listener_error" }) do
    if options[name] ~= nil and type(options[name]) ~= "function" then
      error(name .. " must be a function", 3)
    end
  end

  local max_pool_size = require_integer("max_pool_size", options.max_pool_size or 100, 0)
  local min_pool_size = require_integer("min_pool_size", options.min_pool_size or 0, 0)
  local max_connecting = require_integer("max_connecting", options.max_connecting or 2, 1)
  local max_idle_time_ms = options.max_idle_time_ms or 0
  local wait_queue_timeout_ms = options.wait_queue_timeout_ms or 0
  local poll_interval_ms = options.poll_interval_ms or 1

  for name, value in pairs({
    max_idle_time_ms = max_idle_time_ms,
    poll_interval_ms = poll_interval_ms,
    wait_queue_timeout_ms = wait_queue_timeout_ms,
  }) do
    if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge then
      error(name .. " must be a finite non-negative number", 3)
    end
  end

  if poll_interval_ms == 0 then
    error("poll_interval_ms must be greater than zero", 3)
  end

  if max_pool_size > 0 and min_pool_size > max_pool_size then
    error("min_pool_size must not exceed max_pool_size", 3)
  end

  return {
    max_connecting = max_connecting,
    max_idle_time_ms = max_idle_time_ms,
    max_pool_size = max_pool_size,
    min_pool_size = min_pool_size,
    wait_queue_timeout_ms = wait_queue_timeout_ms,
  }, poll_interval_ms / 1000
end

function M.new(options)
  local normalized, poll_interval = validate_options(options)
  local pool = {}
  local state = {
    address = options.address:lower(),
    available = {},
    connect = options.connect,
    connections = {},
    generation = 0,
    in_use = {},
    in_use_count = 0,
    listeners = normalize_listeners(options.listeners),
    lock = options.runtime.lock:new(),
    maintenance_scheduled = false,
    max_connecting = normalized.max_connecting,
    max_idle_time_ms = normalized.max_idle_time_ms,
    max_pool_size = normalized.max_pool_size,
    min_pool_size = normalized.min_pool_size,
    next_connection_id = 1,
    on_connection_error = options.on_connection_error,
    on_listener_error = options.on_listener_error,
    options = readonly_copy(normalized),
    operation_count = 0,
    pending = {},
    pending_count = 0,
    poll_interval = poll_interval,
    pool = pool,
    runtime = options.runtime,
    state = "paused",
    total_count = 0,
    wait_queue = {},
    wait_queue_timeout_ms = normalized.wait_queue_timeout_ms,
  }

  POOL_STATES[pool] = state
  setmetatable(pool, POOL_METATABLE)
  publish(state, "ConnectionPoolCreated", { options = state.options })
  return pool
end

function POOL_METHODS:ready()
  local state = POOL_STATES[self]

  assert(acquire(state))

  if state.state == "closed" then
    state.lock:release()
    return nil, closed_error(state)
  elseif state.state == "ready" then
    state.lock:release()
    return true
  end

  state.state = "ready"
  state.lock:release()
  publish(state, "ConnectionPoolReady")
  schedule_maintenance(self)
  return true
end

local function connection_is_perished(state, connection)
  local connection_state = CONNECTION_STATES[connection]

  if connection_state.generation ~= state.generation then
    return true, "stale"
  end

  if state.max_idle_time_ms > 0
      and (state.runtime.clock:now() - connection_state.last_available_at) * 1000
        > state.max_idle_time_ms
  then
    return true, "idle"
  end

  if connection_state.resource
      and type(connection_state.resource.is_closed) == "function"
      and connection_state.resource:is_closed()
  then
    return true, "error"
  end

  return false
end

local function checkout_failed(state, reason, started_at, err, counted, reported)
  if counted then
    assert(acquire(state))
    state.operation_count = state.operation_count - 1
    state.lock:release()
  end

  publish(state, "ConnectionCheckOutFailed", {
    duration_ms = duration_ms(state, started_at),
    reason = reason,
  })
  return nil, err, reported
end

local function remove_waiter(state, waiter)
  remove_value(state.wait_queue, waiter)
  waiter.active = false
end

function POOL_METHODS:check_out(options)
  options = options or {}

  if type(options) ~= "table" then
    error("checkout options must be a table", 2)
  end

  for key in pairs(options) do
    if key ~= "cancellation" and key ~= "deadline" then
      error("unknown checkout option: " .. tostring(key), 2)
    end
  end

  local state = POOL_STATES[self]
  local started_at = state.runtime.clock:now()
  local deadline = options.deadline

  if operation_timeout.current() == nil and state.wait_queue_timeout_ms > 0 then
    local wait_deadline = started_at + state.wait_queue_timeout_ms / 1000

    deadline = deadline and math.min(deadline, wait_deadline) or wait_deadline
  end

  publish(state, "ConnectionCheckOutStarted")
  local ok, check_err = runtime_contract.check(
    state.runtime,
    deadline,
    options.cancellation
  )

  if not ok then
    local reason = errors.is(check_err, errors.CATEGORY.TIMEOUT) and "timeout"
      or "connectionError"

    return checkout_failed(state, reason, started_at, check_err)
  end

  assert(acquire(state))

  if state.state == "closed" then
    state.lock:release()
    return checkout_failed(state, "poolClosed", started_at, closed_error(state))
  elseif state.state ~= "ready" then
    state.lock:release()
    return checkout_failed(state, "connectionError", started_at, paused_error(state))
  end

  local waiter = { active = true }

  state.wait_queue[#state.wait_queue + 1] = waiter
  state.operation_count = state.operation_count + 1
  state.lock:release()

  while true do
    ok, check_err = runtime_contract.check(state.runtime, deadline, options.cancellation)

    if not ok then
      assert(acquire(state))
      remove_waiter(state, waiter)
      state.lock:release()
      local reason = errors.is(check_err, errors.CATEGORY.TIMEOUT) and "timeout"
        or "connectionError"

      if reason == "timeout" then
        check_err = wait_timeout_error(state)
      end

      return checkout_failed(state, reason, started_at, check_err, true)
    end

    assert(acquire(state))

    if waiter.evicted then
      remove_waiter(state, waiter)
      local evicted_reason = waiter.evicted

      state.lock:release()

      if evicted_reason == "poolClosed" then
        return checkout_failed(
          state,
          "poolClosed",
          started_at,
          closed_error(state),
          true
        )
      end

      return checkout_failed(
        state,
        "connectionError",
        started_at,
        paused_error(state),
        true
      )
    elseif state.wait_queue[1] == waiter then
      local closed = {}
      local connection

      while #state.available > 0 and connection == nil do
        local candidate = table.remove(state.available, 1)
        local perished, reason = connection_is_perished(state, candidate)

        if perished then
          detach_locked(state, candidate)
          closed[#closed + 1] = { candidate, reason }
        else
          connection = candidate
        end
      end

      if connection then
        local connection_state = CONNECTION_STATES[connection]

        connection_state.state = "in_use"
        connection_state.checked_in = false
        state.in_use[connection] = true
        state.in_use_count = state.in_use_count + 1
        remove_waiter(state, waiter)
        state.lock:release()

        for _, item in ipairs(closed) do
          finish_close(state, item[1], item[2])
        end

        publish(state, "ConnectionCheckedOut", {
          connection_id = connection_state.id,
          duration_ms = duration_ms(state, started_at),
        })
        return connection
      end

      local under_limit = state.max_pool_size == 0
        or state.total_count < state.max_pool_size

      if under_limit and state.pending_count < state.max_connecting then
        connection = new_connection_locked(state)
        remove_waiter(state, waiter)
        state.lock:release()

        for _, item in ipairs(closed) do
          finish_close(state, item[1], item[2])
        end

        local established, establish_err, _, reported = establish(
          self,
          connection,
          "in_use",
          deadline,
          options.cancellation
        )

        if not established then
          return checkout_failed(
            state,
            "connectionError",
            started_at,
            establish_err,
            true,
            reported
          )
        end

        publish(state, "ConnectionCheckedOut", {
          connection_id = connection.id,
          duration_ms = duration_ms(state, started_at),
        })
        schedule_maintenance(self)
        return connection
      end

      state.lock:release()

      for _, item in ipairs(closed) do
        finish_close(state, item[1], item[2])
      end
    else
      state.lock:release()
    end

    local remaining = runtime_contract.remaining(state.runtime, deadline)
    local sleep_for = remaining and math.min(state.poll_interval, remaining)
      or state.poll_interval
    local slept, sleep_err = state.runtime.clock:sleep(sleep_for, options.cancellation)

    if not slept then
      assert(acquire(state))
      remove_waiter(state, waiter)
      state.lock:release()
      return checkout_failed(
        state,
        "connectionError",
        started_at,
        sleep_err,
        true
      )
    end
  end
end

function POOL_METHODS:check_in(connection)
  local state = POOL_STATES[self]
  local connection_state = CONNECTION_STATES[connection]

  if not connection_state or connection_state.owner ~= self then
    error("connection does not belong to this pool", 2)
  end

  assert(acquire(state))

  if connection_state.state ~= "in_use"
      and not (connection_state.state == "closed" and not connection_state.checked_in)
  then
    state.lock:release()
    error("connection is not checked out", 2)
  end

  connection_state.checked_in = true
  state.operation_count = state.operation_count - 1

  if connection_state.state == "closed" then
    state.lock:release()
    publish(state, "ConnectionCheckedIn", {
      connection_id = connection_state.id,
    })
    return true
  end

  state.in_use[connection] = nil
  state.in_use_count = state.in_use_count - 1
  local reason

  if state.state == "closed" then
    reason = "poolClosed"
  elseif connection_state.generation ~= state.generation then
    reason = "stale"
  elseif connection_state.errored then
    reason = "error"
  end

  if reason then
    connection_state.state = "closed"
    state.connections[connection] = nil
    state.total_count = state.total_count - 1
  else
    connection_state.state = "available"
    connection_state.last_available_at = state.runtime.clock:now()
    state.available[#state.available + 1] = connection
  end

  state.lock:release()
  publish(state, "ConnectionCheckedIn", {
    connection_id = connection_state.id,
  })

  if reason then
    finish_close(state, connection, reason)
  end

  schedule_maintenance(self)
  return true
end

function CONNECTION_METHODS:check_in()
  local state = CONNECTION_STATES[self]

  return state.owner:check_in(self)
end

function CONNECTION_METHODS:mark_error()
  local state = CONNECTION_STATES[self]

  if state.state == "closed" then
    return false
  end

  state.errored = true
  return true
end

local function collect_available_locked(state)
  local connections = state.available

  state.available = {}

  for _, connection in ipairs(connections) do
    local connection_state = CONNECTION_STATES[connection]

    connection_state.state = "closed"
    state.connections[connection] = nil
    state.total_count = state.total_count - 1
  end

  return connections
end

function POOL_METHODS:clear(interrupt_in_use_connections)
  if interrupt_in_use_connections == nil then
    interrupt_in_use_connections = false
  elseif type(interrupt_in_use_connections) ~= "boolean" then
    error("interrupt_in_use_connections must be a boolean", 2)
  end

  local state = POOL_STATES[self]

  assert(acquire(state))

  if state.state == "closed" then
    state.lock:release()
    return false
  end

  local prior_state = state.state
  local cleared_generation = state.generation

  state.generation = state.generation + 1
  state.state = "paused"

  for _, waiter in ipairs(state.wait_queue) do
    waiter.evicted = "connectionError"
  end

  local available = collect_available_locked(state)
  local interrupted = {}

  if interrupt_in_use_connections then
    local in_use = {}

    for connection in pairs(state.in_use) do
      in_use[#in_use + 1] = connection
    end

    for _, connection in ipairs(in_use) do
      local connection_state = CONNECTION_STATES[connection]

      if connection_state.generation <= cleared_generation then
        connection_state.interrupted = true
        interrupted[#interrupted + 1] = connection
      end
    end

    for connection in pairs(state.pending) do
      CONNECTION_STATES[connection].setup_cancellation:cancel(
        "connection interrupted by pool clear"
      )
    end
  end

  state.lock:release()

  if prior_state ~= "paused" then
    publish(state, "ConnectionPoolCleared", {
      interrupt_in_use_connections = interrupt_in_use_connections,
    })
  end

  for _, connection in ipairs(available) do
    finish_close(state, connection, "stale")
  end

  for _, connection in ipairs(interrupted) do
    local connection_state = CONNECTION_STATES[connection]

    if not connection_state.resource_closed then
      connection_state.resource_closed = true
      close_resource(connection_state.resource)
    end
  end

  schedule_maintenance(self)
  return true
end

function POOL_METHODS:close()
  local state = POOL_STATES[self]

  assert(acquire(state))

  if state.state == "closed" then
    state.lock:release()
    return false
  end

  state.state = "closed"

  for _, waiter in ipairs(state.wait_queue) do
    waiter.evicted = "poolClosed"
  end

  for connection in pairs(state.pending) do
    CONNECTION_STATES[connection].setup_cancellation:cancel("connection pool closed")
  end

  local available = collect_available_locked(state)
  local maintenance_task = state.maintenance_task

  state.lock:release()

  for _, connection in ipairs(available) do
    finish_close(state, connection, "poolClosed")
  end

  if maintenance_task and maintenance_task:status() == "pending" then
    state.runtime.task:await(maintenance_task)
  end

  publish(state, "ConnectionPoolClosed")
  return true
end

function POOL_METHODS:maintain()
  local state = POOL_STATES[self]
  local stale = {}

  assert(acquire(state))

  for index = #state.available, 1, -1 do
    local connection = state.available[index]
    local perished, reason = connection_is_perished(state, connection)

    if perished then
      detach_locked(state, connection)
      stale[#stale + 1] = { connection, reason }
    end
  end

  local ready = state.state == "ready"

  state.lock:release()

  for _, item in ipairs(stale) do
    finish_close(state, item[1], item[2])
  end

  if not ready then
    return true
  end

  while true do
    assert(acquire(state))
    local under_limit = state.max_pool_size == 0
      or state.total_count < state.max_pool_size
    local needs_connection = state.state == "ready"
      and state.total_count < state.min_pool_size
      and under_limit
      and state.pending_count < state.max_connecting

    if not needs_connection then
      state.lock:release()
      return true
    end

    local connection = new_connection_locked(state)

    state.lock:release()
    local established, establish_err, detached = establish(
      self,
      connection,
      "available",
      nil,
      nil,
      true
    )

    if not established then
      local decision_made = false

      if state.on_connection_error then
        local callback_ok, decision = pcall(
          state.on_connection_error,
          establish_err
        )

        decision_made = callback_ok and type(decision) == "boolean"
      end

      if not decision_made then
        self:clear(false)
      end

      if detached then
        finish_close(state, connection, "error")
      end

      schedule_maintenance(self, true)
      return nil, establish_err
    end
  end
end

return M
