local fake_runtime = require("mongodb.runtime.fake")
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
