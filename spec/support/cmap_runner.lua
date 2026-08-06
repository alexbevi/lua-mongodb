local bson = require("mongodb.bson")
local copas = require("copas")
local errors = require("mongodb.error")
local pool = require("mongodb.pool")
local runtime_module = require("mongodb.runtime")

local M = {}

local FIXTURE_ROOT = (os.getenv("PWD") or ".")
  .. "/planning/specifications/source/connection-monitoring-and-pooling/tests/"

local function require_equal(expected, actual, message)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", message, expected, actual), 3)
  end
end

local function require_not_nil(value, message)
  if value == nil then
    error(message .. ": expected a value", 3)
  end
end

local function require_table(value, message)
  if type(value) ~= "table" then
    error(message .. ": expected a table", 3)
  end
end

local function number_value(value)
  if type(value) == "number" then
    return value
  end

  if bson.is_exact(value) then
    return value:to_number()
  end

  return value
end

local function read_fixture(path)
  local file = assert(io.open(FIXTURE_ROOT .. path, "rb"))
  local content = file:read("*a")

  file:close()
  return assert(bson.json.decode(content))
end

function M.fixture_paths(style)
  local paths = {}
  local process = assert(io.popen(
    'find "' .. FIXTURE_ROOT
      .. 'cmap-format" -type f -name "*.json" -print | sort',
    "r"
  ))

  for full_path in process:lines() do
    local path = full_path:sub(#FIXTURE_ROOT + 1)

    if read_fixture(path):get("style") == style then
      paths[#paths + 1] = path
    end
  end

  assert(process:close())
  return paths
end

local function option(document, name, default)
  local value = document and document:get(name)

  if value == nil or bson.is_null(value) then
    return default
  end

  return number_value(value)
end

local function pool_options(document, scale)
  return {
    max_connecting = option(document, "maxConnecting", 2),
    max_idle_time_ms = option(document, "maxIdleTimeMS", 0) * scale,
    max_pool_size = option(document, "maxPoolSize", 100),
    min_pool_size = option(document, "minPoolSize", 0),
    wait_queue_timeout_ms = option(document, "waitQueueTimeoutMS", 0) * scale,
  }
end

local function event_count(events, event_type)
  local count = 0

  for _, event in ipairs(events) do
    if event.type == event_type then
      count = count + 1
    end
  end

  return count
end

local function expected_field(actual, name)
  local names = {
    connectionId = "connection_id",
    duration = "duration_ms",
    interruptInUseConnections = "interrupt_in_use_connections",
  }

  return actual[names[name] or name]
end

local function option_field(actual, name)
  local names = {
    maxConnecting = "max_connecting",
    maxIdleTimeMS = "max_idle_time_ms",
    maxPoolSize = "max_pool_size",
    minPoolSize = "min_pool_size",
    waitQueueTimeoutMS = "wait_queue_timeout_ms",
  }

  return actual[names[name] or name]
end

local function matches(expected, actual, path, options_document)
  expected = number_value(expected)

  if expected == 42 or expected == "42" then
    require_not_nil(actual, path)
  elseif bson.is_document(expected) then
    require_table(actual, path)

    for key, value in expected:iter() do
      local item = options_document and option_field(actual, key)
        or expected_field(actual, key)

      matches(value, item, path .. "." .. key, options_document)
    end
  elseif bson.is_array(expected) then
    require_table(actual, path)

    for index, value in expected:iter() do
      matches(value, actual[index], path .. "[" .. index .. "]", options_document)
    end
  else
    require_equal(expected, actual, path)
  end
end

local function assert_events(fixture, events, path)
  local ignored = {}
  local ignore = fixture:get("ignore")

  if bson.is_array(ignore) then
    for _, event_type in ignore:iter() do
      ignored[event_type] = true
    end
  end

  local actual = {}

  for _, event in ipairs(events) do
    if not ignored[event.type] then
      actual[#actual + 1] = event
    end
  end

  local expected = fixture:get("events")
  local expected_count = 0

  for index, event in expected:iter() do
    expected_count = expected_count + 1
    require_not_nil(actual[index], path .. " event " .. index)

    for key, value in event:iter() do
      if key == "options" and bson.is_document(value) then
        matches(value, actual[index].options, path .. " event " .. index .. ".options", true)
      else
        matches(
          value,
          expected_field(actual[index], key),
          path .. " event " .. index .. "." .. key
        )
      end
    end
  end

  require_equal(expected_count, #actual, path .. " event count")
end

local function assert_expected_error(fixture, actual, path)
  local expected = fixture:get("error")

  if not bson.is_document(expected) then
    if actual ~= nil then
      error(path .. ": unexpected error " .. tostring(actual), 2)
    end

    return
  end

  require_not_nil(actual, path .. ": expected an error")
  local expected_type = expected:get("type")
  local reason = actual.details and actual.details.reason
  local types = {
    PoolClearedError = "connectionError",
    PoolClosedError = "poolClosed",
    WaitQueueTimeoutError = "timeout",
  }

  if expected_type then
    require_equal(types[expected_type], reason, path .. " error type")
  end

  local message = expected:get("message")

  if message then
    require_not_nil(actual.message:find(message, 1, true), path .. " error message")
  end
end

local function new_resource()
  local resource = { closed = false }

  function resource:close()
    self.closed = true
    return true
  end

  function resource:is_closed()
    return self.closed
  end

  return resource
end

local function run_inside_copas(path, fixture, integration)
  local scale = integration and 0.1 or 1
  local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
  local events = {}
  local fail_point = fixture:get("failPoint")
  local fail_data = bson.is_document(fail_point) and fail_point:get("data") or nil
  local pool_values = pool_options(fixture:get("poolOptions"), scale)
  local connection_pool = pool.new({
    address = "fixture:27017",
    connect = function(fields)
      if bson.is_document(fail_data) and fail_data:get("blockConnection") == true then
        local milliseconds = number_value(fail_data:get("blockTimeMS"))
        local slept, sleep_err = runtime.clock:sleep(
          milliseconds / 1000 * scale,
          fields.cancellation
        )

        if not slept then
          return nil, sleep_err
        end
      end

      if bson.is_document(fail_data) and fail_data:get("errorCode") ~= nil then
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          code = number_value(fail_data:get("errorCode")),
          message = "fixture connection establishment failed",
        })
      end

      return new_resource()
    end,
    listeners = {
      function(event)
        events[#events + 1] = event
      end,
    },
    max_connecting = pool_values.max_connecting,
    max_idle_time_ms = pool_values.max_idle_time_ms,
    max_pool_size = pool_values.max_pool_size,
    min_pool_size = pool_values.min_pool_size,
    poll_interval_ms = 1,
    runtime = runtime,
    wait_queue_timeout_ms = pool_values.wait_queue_timeout_ms,
  })
  local labels = {}
  local held = {}
  local threads = {}
  local actual_error

  local function checkout(operation)
    local connection, checkout_err = connection_pool:check_out()

    if not connection then
      return nil, checkout_err
    end

    held[#held + 1] = connection
    local label = operation:get("label")

    if label then
      labels[label] = connection
    end

    return connection
  end

  local function wait_for_event(operation)
    local event_type = operation:get("event")
    local wanted = number_value(operation:get("count"))
    local timeout_ms = number_value(operation:get("timeout")) or 5000
    local deadline = runtime.clock:now() + timeout_ms / 1000 * scale

    while event_count(events, event_type) < wanted do
      if runtime.clock:now() >= deadline then
        error(path .. ": timed out waiting for " .. event_type)
      end

      assert(runtime.clock:sleep(0.001))
    end

    return true
  end

  for _, operation in fixture:get("operations"):iter() do
    local name = operation:get("name")
    local thread = operation:get("thread")
    local operation_err

    if name == "start" then
      threads[operation:get("target")] = false
    elseif thread then
      require_equal(false, threads[thread], path .. ": thread was already used")
      threads[thread] = runtime.task:spawn(function()
        return checkout(operation)
      end)
    elseif name == "checkOut" then
      operation_err = select(2, checkout(operation))
    elseif name == "checkIn" then
      operation_err = select(2, connection_pool:check_in(
        labels[operation:get("connection")]
      ))
    elseif name == "clear" then
      operation_err = select(2, connection_pool:clear(
        operation:get("interruptInUseConnections") == true
      ))
    elseif name == "close" then
      operation_err = select(2, connection_pool:close())
    elseif name == "ready" then
      operation_err = select(2, connection_pool:ready())
    elseif name == "wait" then
      operation_err = select(2, runtime.clock:sleep(
        number_value(operation:get("ms")) / 1000 * scale
      ))
    elseif name == "waitForEvent" then
      wait_for_event(operation)
    elseif name == "waitForThread" then
      operation_err = select(2, runtime.task:await(
        threads[operation:get("target")]
      ))
    else
      error(path .. ": unknown CMAP operation " .. tostring(name))
    end

    if operation_err then
      actual_error = operation_err
      break
    end
  end

  assert_expected_error(fixture, actual_error, path)
  assert_events(fixture, events, path)
  connection_pool:close()

  for _, task in pairs(threads) do
    if task and task:status() == "pending" then
      runtime.task:await(task)
    end
  end

  for _, connection in ipairs(held) do
    if connection.state == "in_use" then
      connection_pool:check_in(connection)
    end
  end
end

function M.run(path, integration)
  local fixture = read_fixture(path)
  local outcome

  copas.loop(function()
    outcome = table.pack(pcall(run_inside_copas, path, fixture, integration))
  end)

  require_table(outcome, path .. " outcome")

  if not outcome[1] then
    error(outcome[2], 0)
  end

  return true
end

return M
