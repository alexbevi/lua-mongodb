local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local pool = require("mongodb.pool")
local retry_executor = require("mongodb.retry_executor")
local runtime_contract = require("mongodb.runtime")
local session_module = require("mongodb.session")
local topology = require("mongodb.topology")

local M = {}

local MODULUS = 2147483647
local MULTIPLIER = 48271

local function require_positive_integer(name, value)
  if math.type(value) ~= "integer" or value <= 0 then
    error(name .. " must be a positive integer", 3)
  end
end

local function new_random(seed)
  local state = seed % MODULUS

  if state == 0 then
    state = 1
  end

  return function(limit)
    state = state * MULTIPLIER % MODULUS
    return state % limit + 1
  end
end

local function record(trace, boundary, decision)
  trace[#trace + 1] = boundary .. ":" .. decision
end

local function stress_cancellation(random, trace)
  local runtime = fake_runtime.new()
  local token = runtime.cancellation:new()
  local cancel_before_check = random(2) == 1

  if cancel_before_check then
    assert(token:cancel("seeded cancellation"))
  end

  local ok, err = runtime_contract.check(runtime, nil, token)

  if cancel_before_check then
    assert(ok == nil)
    assert(errors.is(err, errors.CATEGORY.CANCELLED))
  else
    assert(ok)
    assert(token:cancel("seeded cancellation"))
  end

  local task = runtime.task:spawn(function()
    return runtime_contract.check(runtime, nil, token)
  end)
  local value, task_err = runtime.task:await(task)

  assert(value == nil)
  assert(errors.is(task_err, errors.CATEGORY.CANCELLED))
  assert(task:status() == "completed")
  record(trace, "cancellation", cancel_before_check and "before" or "after")
end

local function new_pool_resource()
  local value = { closed = false }

  function value:close()
    self.closed = true
    return true
  end

  function value:is_closed()
    return self.closed
  end

  return value
end

local function remove_at(values, index)
  local value = values[index]

  table.remove(values, index)
  return value
end

local function stress_pool(random, trace)
  local runtime = fake_runtime.new()
  local held = {}
  local connection_pool = pool.new({
    address = "stress:27017",
    connect = function()
      if random(5) == 1 then
        return nil, errors.new({
          category = errors.CATEGORY.NETWORK,
          message = "seeded connection fault",
        })
      end

      return new_pool_resource()
    end,
    max_pool_size = 2,
    runtime = runtime,
  })

  assert(connection_pool:ready())

  for _ = 1, 12 do
    local action = random(4)

    if #held == 0 or action == 1 and #held < 2 then
      local connection, err = connection_pool:check_out()

      if connection then
        held[#held + 1] = connection
        record(trace, "checkout", "success")
      else
        assert(errors.is(err, errors.CATEGORY.NETWORK))
        record(trace, "checkout", "fault")
      end
    elseif action == 2 or #held == 2 then
      local connection = remove_at(held, random(#held))

      assert(connection_pool:check_in(connection))
      record(trace, "checkout", "checkin")
    else
      local interrupt = random(2) == 1

      assert(connection_pool:clear(interrupt))
      assert(connection_pool:ready())
      record(trace, "pool_clear", interrupt and "interrupt" or "stale")
    end

    assert(connection_pool.operation_count == #held)
    assert(connection_pool.pending_connection_count == 0)
  end

  while #held > 0 do
    assert(connection_pool:check_in(remove_at(held, #held)))
  end

  assert(connection_pool.operation_count == 0)
  assert(connection_pool:close())
  assert(connection_pool.total_connection_count == 0)
end

local function hello(primary)
  return bson.document({
    { "ok", 1 },
    { "isWritablePrimary", primary },
    { "secondary", not primary },
    { "setName", "rs" },
    { "hosts", bson.array({ "a:27017", "b:27017" }) },
    { "maxWireVersion", 21 },
  })
end

local function stress_monitoring(random, trace)
  local runtime = fake_runtime.new()
  local pools = {}
  local function pool_factory(address)
    local value = {
      generation = 0,
      operation_count = 0,
      state = "paused",
    }

    function value:ready()
      self.state = "ready"
      return true
    end

    function value:clear()
      self.generation = self.generation + 1
      self.state = "paused"
      return true
    end

    function value:close()
      self.state = "closed"
      return true
    end

    pools[address] = value
    return value
  end
  local manager = topology.new({
    pool_factory = pool_factory,
    runtime = runtime,
    seeds = { "a:27017", "b:27017" },
    set_name = "rs",
    type = "ReplicaSetNoPrimary",
  })
  local primary = random(2) == 1 and "a:27017" or "b:27017"
  local promoted = primary == "a:27017" and "b:27017" or "a:27017"

  assert(manager:open({ background = false }))
  assert(manager:process_hello(primary, hello(true), { duration = 0.001 }))
  assert(manager:process_hello(promoted, hello(false), { duration = 0.001 }))
  assert(manager:handle_application_error(primary, {
    generation = pools[primary].generation,
    type = "network",
    when = "afterHandshakeCompletes",
  }))
  assert(manager:process_hello(promoted, hello(true), { duration = 0.001 }))
  assert(not manager:handle_application_error(primary, {
    generation = pools[primary].generation - 1,
    type = "network",
    when = "afterHandshakeCompletes",
  }))

  local selected = assert(manager:select_server("write", nil, { timeout_ms = 1 }))

  assert(selected.address == promoted)
  record(trace, "monitoring", primary .. "->" .. promoted)
  assert(manager:close())
  assert(not manager:process_hello(primary, hello(true), { duration = 0.001 }))
end

local function stress_retry(random, trace)
  local mode = random(3)
  local write = random(2) == 1
  local calls = 0
  local underlying = {}

  function underlying.command()
    calls = calls + 1

    if mode == 1 or calls > 1 then
      return bson.document({ { "ok", 1 } })
    elseif mode == 2 then
      return nil, errors.new({
        category = errors.CATEGORY.SERVER,
        code = 10107,
        labels = write and { "RetryableWriteError" } or nil,
        message = "seeded retryable fault",
      })
    end

    return nil, errors.new({
      category = errors.CATEGORY.SERVER,
      code = 2,
      message = "seeded terminal fault",
    })
  end

  function underlying.close()
    return true
  end

  local executor = retry_executor.new(underlying, {
    enabled_reads = true,
    enabled_writes = true,
  })
  local command = bson.document({
    { write and "insert" or "find", "items" },
  })
  local result, err = executor:command("db", command, {
    retryable_read = not write,
    retryable_write = write,
  })

  if mode == 3 then
    assert(result == nil)
    assert(errors.is(err, errors.CATEGORY.SERVER))
    assert(calls == 1)
  else
    assert(result)
    assert(calls == mode)
  end

  record(trace, "retry", (write and "write" or "read") .. "/" .. mode)
end

local function stress_transaction(random, trace, seed)
  local runtime = fake_runtime.new()
  local mode = random(3)
  local callback_calls = 0
  local command_calls = {}
  local fail_abort = random(2) == 1
  local manager = session_module.new({
    clock = runtime.clock,
    id_factory = function()
      return bson.document({
        { "id", bson.binary(
          string.rep(string.char(seed % 255 + 1), 16),
          bson.BINARY_SUBTYPE.UUID
        ) },
      })
    end,
    runtime = runtime,
    timeout_minutes = 30,
    transaction_command = function(_, name)
      command_calls[#command_calls + 1] = name

      if mode == 1 and name == "abortTransaction" and fail_abort then
        return nil, errors.new({
          category = errors.CATEGORY.NETWORK,
          message = "seeded abort cleanup fault",
        })
      elseif mode == 3 and name == "commitTransaction"
          and command_calls[#command_calls - 1] ~= "commitTransaction"
      then
        return nil, errors.new({
          category = errors.CATEGORY.SERVER,
          labels = { "UnknownTransactionCommitResult" },
          message = "seeded unknown commit result",
        })
      end

      return bson.document({ { "ok", 1 } })
    end,
    transaction_jitter = function()
      return 0
    end,
  })
  local session = assert(manager:start())
  local callback_error = errors.new({
    category = errors.CATEGORY.SERVER,
    labels = mode == 2 and { "TransientTransactionError" } or nil,
    message = "seeded callback fault",
  })
  local result, err = session:with_transaction(function(active_session)
    callback_calls = callback_calls + 1
    assert(manager:decorate(
      bson.document({ { "insert", "items" } }),
      { session = active_session }
    ))

    if mode == 1 or mode == 2 and callback_calls == 1 then
      return nil, callback_error
    end

    return "committed"
  end)

  if mode == 1 then
    assert(result == nil)
    assert(err == callback_error)
    assert(callback_calls == 1)
  else
    assert(result == "committed")
    assert(err == nil)
    assert(callback_calls == (mode == 2 and 2 or 1))
  end

  assert(not session:is_in_transaction())
  assert(session:end_session())
  record(trace, "transaction_cleanup", mode .. "/" .. tostring(fail_abort))
end

local function digest(trace)
  local value = 17

  for _, entry in ipairs(trace) do
    for index = 1, #entry do
      value = (value * 131 + string.byte(entry, index)) % MODULUS
    end
  end

  return value
end

function M.run_seed(seed, iterations)
  require_positive_integer("seed", seed)
  iterations = iterations or 4
  require_positive_integer("iterations", iterations)

  local random = new_random(seed)
  local trace = {}

  for _ = 1, iterations do
    stress_cancellation(random, trace)
    stress_pool(random, trace)
    stress_monitoring(random, trace)
    stress_retry(random, trace)
    stress_transaction(random, trace, seed)
  end

  return {
    digest = digest(trace),
    iterations = iterations,
    seed = seed,
    steps = #trace,
    trace = trace,
  }
end

return M
