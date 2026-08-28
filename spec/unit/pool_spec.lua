local bson = require("mongodb.bson")
local fake_runtime = require("mongodb.runtime.fake")
local logging = require("mongodb.logging")
local pool = require("mongodb.pool")
local cmap_runner = require("spec.support.cmap_runner")
local copas = require("copas")
local errors = require("mongodb.error")
local runtime_module = require("mongodb.runtime")

local function run_copas(callback)
  local outcome

  copas.loop(function()
    outcome = table.pack(pcall(callback))
  end)

  if not outcome[1] then
    error(outcome[2], 0)
  end
end

describe("CMAP connection pools", function()
  it("tracks service-specific generations across targeted clears", function()
    local runtime = fake_runtime.new()
    local service_a = bson.object_id("000000000000000000000001")
    local service_b = bson.object_id("000000000000000000000002")
    local services = { service_a, service_b }
    local resources = {}
    local cleared_event
    local connection_pool = pool.new({
      address = "load-balancer:27017",
      connect = function()
        local service_id = table.remove(services, 1)
        local resource = {
          closed = false,
          close = function(self)
            self.closed = true
          end,
        }

        resources[#resources + 1] = resource
        return resource, nil, { service_id = service_id }
      end,
      listeners = {
        function(event)
          if event.type == "ConnectionPoolCleared" then
            cleared_event = event
          end
        end,
      },
      runtime = runtime,
    })

    assert(connection_pool:ready())
    local first = assert(connection_pool:check_out())
    local second = assert(connection_pool:check_out())

    assert.are.equal(service_a, first.service_id)
    assert.are.equal(service_b, second.service_id)
    assert.are.equal(0, first.generation)
    assert.are.equal(0, second.generation)
    assert(connection_pool:check_in(first))
    assert(connection_pool:check_in(second))
    assert(connection_pool:clear(false, service_a))
    assert.are.equal(service_a, cleared_event.service_id)
    assert.are.equal("ready", connection_pool.state)
    assert.are.equal(1, connection_pool:generation_for(service_a))
    assert.are.equal(0, connection_pool:generation_for(service_b))
    assert.is_true(connection_pool:is_stale(0, service_a))
    assert.is_false(connection_pool:is_stale(0, service_b))
    assert.is_true(resources[1].closed)
    assert.is_false(resources[2].closed)

    local reused = assert(connection_pool:check_out())

    assert.are.equal(second.id, reused.id)
    assert(connection_pool:check_in(reused))
    assert(connection_pool:close())
  end)

  it("creates, readies, and checks out an established connection", function()
    local runtime = fake_runtime.new()
    local events = {}
    local connection_pool = pool.new({
      address = "a:27017",
      connect = function()
        return { close = function() end }
      end,
      listeners = {
        function(event)
          events[#events + 1] = event
        end,
      },
      runtime = runtime,
    })

    assert.are.equal("paused", connection_pool.state)
    assert(connection_pool:ready())
    local connection = assert(connection_pool:check_out())

    assert.are.equal(1, connection.id)
    assert.are.equal("in_use", connection.state)
    assert.is_nil(connection.owner)
    assert.is_nil(connection_pool.runtime)
    assert.are.equal("ConnectionPoolCreated", events[1].type)
    assert.are.equal("ConnectionCheckedOut", events[#events].type)
    assert(connection:check_in())
    assert(connection_pool:close())
  end)

  it("logs pool and connection lifecycle transitions", function()
    local runtime = fake_runtime.new()
    local observed = {}
    local logger = assert(logging.new(runtime, {
      levels = { connection = "debug" },
      sink = function(event)
        observed[#observed + 1] = event
      end,
    }))
    local connection_pool = pool.new({
      address = "server.example:27017",
      connect = function()
        runtime:advance(0.0125)
        return { close = function() end }
      end,
      logger = logger,
      runtime = runtime,
    })

    assert(connection_pool:ready())
    local connection = assert(connection_pool:check_out())

    assert(connection_pool:check_in(connection))
    assert(connection_pool:close())
    local messages = {}

    for index, event in ipairs(observed) do
      messages[index] = event.data.message
    end

    assert.same({
      "Connection pool created",
      "Connection pool ready",
      "Connection checkout started",
      "Connection created",
      "Connection ready",
      "Connection checked out",
      "Connection checked in",
      "Connection closed",
      "Connection pool closed",
    }, messages)
    assert.are.equal("connection", observed[1].component)
    assert.are.equal("server.example", observed[1].data.serverHost)
    assert.are.equal(27017, observed[1].data.serverPort)
    assert.are.equal(1, observed[4].data.driverConnectionId)
    assert.near(12.5, observed[5].data.durationMS, 0.000001)
    assert.are.equal(1, observed[6].data.driverConnectionId)
    assert.is_number(observed[6].data.durationMS)
    assert.are.equal(1, observed[7].data.driverConnectionId)
    assert.are.equal("Connection pool was closed", observed[8].data.reason)
  end)

  it("logs only configured pool options when the pool is created", function()
    local runtime = fake_runtime.new()
    local observed = {}
    local logger = assert(logging.new(runtime, {
      levels = { connection = "debug" },
      sink = function(event)
        observed[#observed + 1] = event
      end,
    }))
    local configured = pool.new({
      address = "server.example:27017",
      connect = function()
        return { close = function() end }
      end,
      logger = logger,
      max_connecting = 5,
      max_idle_time_ms = 10000,
      max_pool_size = 5,
      min_pool_size = 1,
      runtime = runtime,
      wait_queue_timeout_ms = 2000,
    })
    local defaults = pool.new({
      address = "server.example:27017",
      connect = function()
        return { close = function() end }
      end,
      logger = logger,
      runtime = runtime,
    })

    assert.same({
      maxConnecting = 5,
      maxIdleTimeMS = 10000,
      maxPoolSize = 5,
      message = "Connection pool created",
      minPoolSize = 1,
      serverHost = "server.example",
      serverPort = 27017,
      waitQueueTimeoutMS = 2000,
    }, observed[1].data)
    assert.same({
      message = "Connection pool created",
      serverHost = "server.example",
      serverPort = 27017,
    }, observed[2].data)
    assert(configured:close())
    assert(defaults:close())
  end)

  it("publishes check-in before close after interrupting an in-use connection", function()
    local runtime = fake_runtime.new()
    local closed = 0
    local event_types = {}
    local connection_pool = pool.new({
      address = "a:27017",
      connect = function()
        return {
          close = function()
            closed = closed + 1
          end,
        }
      end,
      listeners = {
        function(event)
          event_types[#event_types + 1] = event.type
        end,
      },
      runtime = runtime,
    })

    assert(connection_pool:ready())
    local connection = assert(connection_pool:check_out())

    assert(connection_pool:clear(true))
    assert.is_true(connection.interrupted)
    assert.are.equal("in_use", connection.state)
    assert.are.equal(1, closed)
    assert(connection_pool:check_in(connection))
    assert.are.equal("closed", connection.state)
    assert.same({
      "ConnectionPoolCleared",
      "ConnectionCheckedIn",
      "ConnectionClosed",
    }, {
      event_types[#event_types - 2],
      event_types[#event_types - 1],
      event_types[#event_types],
    })
    assert(connection_pool:close())
    assert.is_false(connection_pool:clear())
    assert.is_false(connection:mark_error())
  end)

  it("runs every pinned unit CMAP fixture", function()
    local paths = cmap_runner.fixture_paths("unit")

    assert.are.equal(26, #paths)

    for _, path in ipairs(paths) do
      assert(cmap_runner.run(path, false))
    end
  end)

  it("releases capacity and applies backpressure labels after setup failure", function()
    local runtime = fake_runtime.new()
    local event_types = {}
    local connection_pool = pool.new({
      address = "a:27017",
      connect = function()
        return nil, errors.new({
          category = errors.CATEGORY.NETWORK,
          message = "handshake failed",
        })
      end,
      listeners = {
        function(event)
          event_types[#event_types + 1] = event.type
        end,
      },
      runtime = runtime,
    })

    assert(connection_pool:ready())
    local connection, err = connection_pool:check_out()

    assert.is_nil(connection)
    assert.is_true(errors.is(err, errors.CATEGORY.NETWORK))
    assert.is_true(err:has_label("SystemOverloadedError"))
    assert.is_true(err:has_label("RetryableError"))
    assert.are.equal(0, connection_pool.total_connection_count)
    assert.are.equal(0, connection_pool.pending_connection_count)
    assert.are.equal(0, connection_pool.operation_count)
    assert.same({
      "ConnectionPoolCreated",
      "ConnectionPoolReady",
      "ConnectionCheckOutStarted",
      "ConnectionCreated",
      "ConnectionClosed",
      "ConnectionCheckOutFailed",
    }, event_types)
  end)

  it("reports authentication setup failure before closing the connection", function()
    local runtime = fake_runtime.new()
    local event_types = {}
    local connection_pool

    connection_pool = pool.new({
      address = "a:27017",
      connect = function()
        return nil, errors.new({
          category = errors.CATEGORY.AUTHENTICATION,
          message = "authentication failed",
        })
      end,
      listeners = {
        function(event)
          event_types[#event_types + 1] = event.type
        end,
      },
      on_connection_error = function(err)
        assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
        assert(connection_pool:clear(false))
        return true
      end,
      runtime = runtime,
    })

    assert(connection_pool:ready())
    local connection, err = connection_pool:check_out()

    assert.is_nil(connection)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.are.equal("paused", connection_pool.state)
    assert.are.equal(1, connection_pool.generation)
    assert.same({
      "ConnectionPoolCreated",
      "ConnectionPoolReady",
      "ConnectionCheckOutStarted",
      "ConnectionCreated",
      "ConnectionPoolCleared",
      "ConnectionClosed",
      "ConnectionCheckOutFailed",
    }, event_types)
  end)

  it("reports load-balanced authentication failures with service generation", function()
    local runtime = fake_runtime.new()
    local service_id = bson.object_id("000000000000000000000001")
    local reported
    local connection_pool

    connection_pool = pool.new({
      address = "load-balancer:27017",
      connect = function()
        return nil, errors.new({
          category = errors.CATEGORY.AUTHENTICATION,
          message = "authentication failed",
        }), { service_id = service_id }
      end,
      on_connection_error = function(err, details)
        assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
        reported = details
        assert(connection_pool:clear(false, details.service_id))
        return true
      end,
      runtime = runtime,
    })

    assert(connection_pool:ready())
    local connection, err = connection_pool:check_out()

    assert.is_nil(connection)
    assert.is_true(errors.is(err, errors.CATEGORY.AUTHENTICATION))
    assert.is_true(reported.handshake_complete)
    assert.are.equal(service_id, reported.service_id)
    assert.are.equal(0, reported.generation)
    assert.are.equal(1, connection_pool:generation_for(service_id))
    assert.are.equal("ready", connection_pool.state)
    assert(connection_pool:close())
  end)

  it("reports load-balanced checkout purposes in wait queue timeouts", function()
    local runtime = fake_runtime.new()
    local connection_pool = pool.new({
      address = "load-balancer:27017",
      connect = function()
        return { close = function() end }
      end,
      load_balanced = true,
      max_pool_size = 3,
      poll_interval_ms = 1,
      runtime = runtime,
      wait_queue_timeout_ms = 1,
    })

    assert(connection_pool:ready())
    local function assert_timeout_counts()
      local value, err = connection_pool:check_out()

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.POOL))
      assert.matches(
        "maxPoolSize: 3, connections in use by cursors: 1, "
          .. "connections in use by transactions: 1, "
          .. "connections in use by other operations: 1",
        err.message,
        1,
        true
      )
    end

    local cursor = assert(connection_pool:check_out({ purpose = "cursor" }))
    local transaction = assert(connection_pool:check_out({
      purpose = "transaction",
    }))
    local other = assert(connection_pool:check_out())

    assert_timeout_counts()

    assert(cursor:check_in())
    assert(transaction:mark_error())
    assert(transaction:check_in())
    cursor = assert(connection_pool:check_out({ purpose = "cursor" }))
    transaction = assert(connection_pool:check_out({ purpose = "transaction" }))
    assert_timeout_counts()
    assert(cursor:check_in())
    assert(transaction:check_in())
    assert(other:check_in())
    assert.are.equal(0, connection_pool.operation_count)
    assert(connection_pool:close())
  end)

  it("replenishes minPoolSize after a background connection error", function()
    run_copas(function()
      local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
      local attempts = 0
      local connection_pool

      connection_pool = pool.new({
        address = "a:27017",
        connect = function()
          attempts = attempts + 1

          if attempts == 1 then
            return nil, errors.new({
              category = errors.CATEGORY.SERVER,
              code = 91,
              message = "transient background handshake failure",
            })
          end

          return { close = function() end }
        end,
        min_pool_size = 2,
        on_connection_error = function()
          runtime.task:spawn(function()
            assert(runtime.clock:sleep(0.005))
            assert(connection_pool:ready())
          end)
        end,
        poll_interval_ms = 1,
        runtime = runtime,
      })

      assert(connection_pool:ready())
      local deadline = runtime.clock:now() + 1

      while connection_pool.total_connection_count < 2 do
        assert.is_true(runtime.clock:now() < deadline)
        assert(runtime.clock:sleep(0.001))
      end

      assert.are.equal("ready", connection_pool.state)
      assert.are.equal(0, connection_pool.pending_connection_count)
      assert.are.equal(2, connection_pool.available_connection_count)
      assert.are.equal(3, attempts)
      assert(connection_pool:close())
      assert.are.equal(0, connection_pool.total_connection_count)
    end)
  end)

  it("settles in-flight minPoolSize maintenance before close returns", function()
    run_copas(function()
      local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
      local connection_started = false
      local connection_settled = false
      local connection_pool = pool.new({
        address = "a:27017",
        connect = function(options)
          connection_started = true
          local _, err = runtime.clock:sleep(60, options.cancellation)

          connection_settled = true
          return nil, err
        end,
        min_pool_size = 1,
        poll_interval_ms = 1,
        runtime = runtime,
      })

      assert(connection_pool:ready())

      while not connection_started do
        assert(runtime.clock:sleep(0.001))
      end

      assert.are.equal(1, connection_pool.pending_connection_count)
      assert(connection_pool:close())
      assert.is_true(connection_settled)
      assert.are.equal(0, connection_pool.pending_connection_count)
      assert.are.equal(0, connection_pool.total_connection_count)
    end)
  end)

  it("replenishes minPoolSize without clearing after a handshake error", function()
    run_copas(function()
      local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
      local attempts = 0
      local cleared = 0
      local connection_pool = pool.new({
        address = "a:27017",
        connect = function()
          attempts = attempts + 1

          if attempts == 1 then
            return nil, errors.new({
              category = errors.CATEGORY.NETWORK,
              message = "background handshake closed",
            })
          end

          return { close = function() end }
        end,
        listeners = {
          function(event)
            if event.type == "ConnectionPoolCleared" then
              cleared = cleared + 1
            end
          end,
        },
        min_pool_size = 2,
        on_connection_error = function(err)
          assert.is_true(err:has_label("SystemOverloadedError"))
          return false
        end,
        poll_interval_ms = 1,
        runtime = runtime,
      })

      assert(connection_pool:ready())
      local deadline = runtime.clock:now() + 0.25

      while connection_pool.state == "ready"
          and connection_pool.total_connection_count < 2
          and runtime.clock:now() < deadline
      do
        assert(runtime.clock:sleep(0.001))
      end

      assert.are.equal("ready", connection_pool.state)
      assert.are.equal(0, cleared)
      assert.are.equal(3, attempts)
      assert.are.equal(0, connection_pool.pending_connection_count)
      assert.are.equal(2, connection_pool.available_connection_count)
      assert(connection_pool:close())
      assert.are.equal(0, connection_pool.total_connection_count)
    end)
  end)

  it("removes cancelled waiters and interrupted checkouts without leaks", function()
    run_copas(function()
      local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
      local connection_pool = pool.new({
        address = "a:27017",
        connect = function()
          return { close = function() end }
        end,
        max_pool_size = 1,
        poll_interval_ms = 1,
        runtime = runtime,
      })

      assert(connection_pool:ready())
      local first = assert(connection_pool:check_out())
      local cancellation = runtime.cancellation:new()
      local waiter = runtime.task:spawn(function()
        return connection_pool:check_out({ cancellation = cancellation })
      end)

      assert(runtime.clock:sleep(0.005))
      assert(cancellation:cancel("cancel checkout"))
      local value, err = runtime.task:await(waiter)

      assert.is_nil(value)
      assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
      assert.are.equal(1, connection_pool.total_connection_count)
      assert.are.equal(1, connection_pool.operation_count)
      assert(connection_pool:clear(true))
      assert.are.equal(1, connection_pool.total_connection_count)
      assert.are.equal(1, connection_pool.operation_count)
      assert(connection_pool:check_in(first))
      assert.are.equal(0, connection_pool.total_connection_count)
      assert.are.equal(0, connection_pool.operation_count)
    end)
  end)
end)
