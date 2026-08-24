local bson = require("mongodb.bson")
local copas = require("copas")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local pool = require("mongodb.pool")
local runtime_module = require("mongodb.runtime")
local sdam_runner = require("spec.support.sdam_runner")
local socket_timeout_executor = require("mongodb.socket_timeout_executor")
local topology = require("mongodb.topology")
local topology_executor = require("mongodb.topology_executor")

local FIXTURE_ROOT = (os.getenv("PWD") or ".")
  .. "/planning/specifications/source/"

local function read_fixture(relative)
  local file = assert(io.open(FIXTURE_ROOT .. relative, "rb"))
  local content = file:read("*a")

  file:close()
  return assert(bson.json.decode(content))
end

local function hello(primary, topology_version)
  local entries = {
    { "ok", 1 },
    { "isWritablePrimary", primary },
    { "secondary", not primary },
    { "setName", "rs" },
    { "hosts", bson.array({ "a:27017", "b:27017" }) },
    { "maxWireVersion", 21 },
  }

  if topology_version then
    entries[#entries + 1] = { "topologyVersion", topology_version }
  end

  return bson.document(entries)
end

local function new_pool()
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

  return value
end

local function run_copas(callback)
  local outcome

  copas.loop(function()
    outcome = table.pack(pcall(callback))
  end)

  if not outcome[1] then
    error(outcome[2], 0)
  end
end

describe("monitored topology", function()
  it("publishes discovery changes and readies the server pool", function()
    local events = {}
    local ready_count = 0
    local manager = topology.new({
      heartbeat_listeners = {
        function(event)
          events[#events + 1] = event
        end,
      },
      listeners = {
        function(event)
          events[#events + 1] = event
        end,
      },
      pool_factory = function()
        return {
          generation = 0,
          close = function() end,
          clear = function() end,
          ready = function()
            ready_count = ready_count + 1
            return true
          end,
        }
      end,
      runtime = fake_runtime.new(),
      seeds = { "a:27017" },
      topology_id = "42",
      type = "ReplicaSetNoPrimary",
    })

    assert(manager:open({ background = false }))
    assert(manager:process_hello("a:27017", bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "setName", "rs" },
      { "hosts", bson.array({ "a:27017" }) },
      { "maxWireVersion", 21 },
    }), { duration = 0.01 }))

    assert.are.equal("ReplicaSetWithPrimary", manager.description.type)
    assert.are.equal(1, ready_count)
    assert.is_false(events[4].awaited)
    assert.is_false(events[5].awaited)
    assert.same({
      "TopologyOpening",
      "TopologyDescriptionChanged",
      "ServerOpening",
      "ServerHeartbeatStarted",
      "ServerHeartbeatSucceeded",
      "ServerDescriptionChanged",
      "TopologyDescriptionChanged",
    }, (function()
      local types = {}

      for index, event in ipairs(events) do
        types[index] = event.type
      end

      return types
    end)())
  end)

  it("selects a discovered mongos without primary semantics", function()
    local manager = topology.new({
      pool_factory = new_pool,
      runtime = fake_runtime.new(),
      seeds = { "mongos:27017" },
      type = "Unknown",
    })

    assert(manager:open({ background = false }))
    assert(manager:process_hello("mongos:27017", bson.document({
      { "ok", 1 },
      { "msg", "isdbgrid" },
      { "maxWireVersion", 25 },
      { "logicalSessionTimeoutMinutes", 30 },
    }), { duration = 0.01 }))

    local selected, selected_pool = manager:select_server("write", nil, {
      timeout_ms = 0,
    })

    assert.are.equal("Sharded", manager.description.type)
    assert.are.equal("Mongos", selected.type)
    assert.are.equal("mongos:27017", selected.address)
    assert.are.equal("ready", selected_pool.state)
    assert(manager:close())
  end)

  it("constructs a static load-balanced topology without monitoring", function()
    local events = {}
    local runtime = fake_runtime.new()
    local checks = 0
    local manager = topology.new({
      check = function()
        checks = checks + 1
        return nil
      end,
      listeners = {
        function(event)
          events[#events + 1] = event
        end,
      },
      pool_factory = new_pool,
      runtime = runtime,
      seeds = { "load-balancer:27017" },
      topology_id = "42",
      type = "LoadBalanced",
    })

    assert(manager:open())
    assert.are.equal("LoadBalanced", manager.description.type)
    assert.are.equal(
      "LoadBalancer",
      manager.description:server("load-balancer:27017").type
    )
    assert.is_true(manager.description.compatible)
    assert.is_true(manager.description.sessions_supported)
    assert.are.equal(0, checks)
    assert.are.equal(0, #runtime._task_queue)

    local event_types = {}

    for index, event in ipairs(events) do
      event_types[index] = event.type
    end

    assert.are.same({
      "TopologyOpening",
      "TopologyDescriptionChanged",
      "ServerOpening",
      "ServerDescriptionChanged",
      "TopologyDescriptionChanged",
    }, event_types)
    assert.are.equal("Unknown", events[2].previous_description.type)
    assert.are.equal(0, #events[2].previous_description:addresses())
    assert.are.equal("Unknown", events[2].new_description
      :server("load-balancer:27017").type)
    assert.are.equal("Unknown", events[4].previous_description.type)
    assert.are.equal("LoadBalancer", events[4].new_description.type)

    local static_description = manager.description

    assert(manager:process_hello("load-balancer:27017", bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "maxWireVersion", 25 },
    })))
    assert.are.equal(static_description, manager.description)
    assert(manager:close())
  end)

  it("runs the exact load-balanced server-selection fixture", function()
    local fixture = read_fixture("load-balancers/tests/server-selection.json")
    local database = fixture:get("createEntities"):get(2):get("database")
    local collection = fixture:get("createEntities"):get(3):get("collection")
    local case = fixture:get("tests"):get(1)
    local operation = case:get("operations"):get(1)
    local expected = case:get("expectEvents"):get(1):get("events")
      :get(1):get("commandStartedEvent")
    local expected_command = expected:get("command")
    local wire_mode = collection:get("collectionOptions")
      :get("readPreference"):get("mode")
    local runtime = fake_runtime.new()
    local sent_database
    local sent_command
    local selected_type
    local manager = topology.new({
      pool_factory = function(address)
        return pool.new({
          address = address,
          connect = function()
            return {
              capabilities = function()
                return {
                  logical_session_timeout_minutes = nil,
                  max_wire_version = 25,
                  server_type = "load_balancer",
                }
              end,
              close = function() return true end,
              command = function(_, database_name, command)
                sent_database = database_name
                sent_command = command
                return bson.document({ { "ok", 1 } })
              end,
            }
          end,
          runtime = runtime,
        })
      end,
      runtime = runtime,
      seeds = { "load-balancer:27017" },
      topology_id = "42",
      type = "LoadBalanced",
    })

    assert(manager:open({ background = false }))
    local commands = topology_executor.new(manager, {
      read_preference = {
        max_staleness_seconds = -1,
        mode = assert(({ secondaryPreferred = "secondary_preferred" })[wire_mode]),
        tag_sets = { {} },
      },
    })

    assert(commands:command(
      database:get("databaseName"),
      bson.document({
        { assert(operation:get("name")), collection:get("collectionName") },
        { "filter", operation:get("arguments"):get("filter") },
      }),
      {
        on_server_selected = function(_, server_type)
          selected_type = server_type
        end,
      }
    ))
    assert.are.equal("LoadBalancer", selected_type)
    assert.are.equal(expected:get("databaseName"), sent_database)
    assert.are.equal(expected:get("commandName"), sent_command:keys()[1])
    assert.are.equal(
      assert(bson.json.encode(expected_command, { mode = "canonical" })),
      assert(bson.json.encode(sent_command, { mode = "canonical" }))
    )
    assert.is_true(assert(commands:capabilities()).sessions_supported)
    assert(commands:close())
  end)

  it("runs every applicable pinned SDAM monitoring event fixture", function()
    local paths = sdam_runner.fixture_paths("monitoring")

    for _, path in ipairs(paths) do
      assert(sdam_runner.run(path))
    end

    assert.are.equal(8, #paths)
  end)

  it("runs the pinned load-balanced discovery fixture", function()
    assert(sdam_runner.run("load-balanced/discover_load_balancer.json"))
  end)

  it("runs every pinned SDAM application error fixture", function()
    local paths = sdam_runner.fixture_paths("errors")

    assert.are.equal(72, #paths)

    for _, path in ipairs(paths) do
      assert(sdam_runner.run(path))
    end
  end)

  it("schedules heartbeats and sends awaitable hello fields", function()
    run_copas(function()
      local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
      local checks = 0
      local awaited_fields
      local awaited_pending = false
      local rtt_while_awaited = false
      local process_id = assert(bson.object_id("000000000000000000000001"))
      local version = bson.document({
        { "processId", process_id },
        { "counter", bson.int64(1) },
      })
      local response = bson.document({
        { "ok", 1 },
        { "isWritablePrimary", true },
        { "setName", "rs" },
        { "hosts", bson.array({ "a:27017" }) },
        { "maxWireVersion", 21 },
        { "topologyVersion", version },
      })
      local manager = topology.new({
        check = function(_, fields)
          checks = checks + 1

          if fields.awaited then
            awaited_fields = fields
            awaited_pending = true
            assert(runtime.clock:sleep(0.03))
            awaited_pending = false
          end

          return response
        end,
        heartbeat_frequency_ms = 10,
        min_heartbeat_frequency_ms = 5,
        pool_factory = new_pool,
        rtt_check = function()
          if awaited_pending then
            rtt_while_awaited = true
          end

          return 25
        end,
        runtime = runtime,
        seeds = { "a:27017" },
        set_name = "rs",
        type = "ReplicaSetNoPrimary",
      })

      assert(manager:open())
      local deadline = runtime.clock:now() + 1

      while not rtt_while_awaited and runtime.clock:now() < deadline do
        assert(runtime.clock:sleep(0.001))
      end

      assert.is_true(manager.description:server("a:27017").round_trip_time > 0)
      assert(manager:close())

      assert.is_true(checks >= 2)
      assert.is_true(awaited_fields.awaited)
      assert.are.equal(version, awaited_fields.topology_version)
      assert.are.equal(10, awaited_fields.max_await_time_ms)
      assert.is_true(rtt_while_awaited)
    end)
  end)

  it("starts streaming without waiting for the heartbeat interval", function()
    run_copas(function()
      local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
      local awaited_fields
      local version = bson.document({
        { "processId", assert(bson.object_id("000000000000000000000001")) },
        { "counter", bson.int64(1) },
      })
      local response = hello(true, version)
      local manager = topology.new({
        check = function(_, fields)
          if fields.awaited then
            awaited_fields = fields
            return nil, select(2, runtime.clock:sleep(1, fields.cancellation))
          end

          return response
        end,
        heartbeat_frequency_ms = 60000,
        min_heartbeat_frequency_ms = 500,
        pool_factory = new_pool,
        runtime = runtime,
        seeds = { "a:27017" },
        set_name = "rs",
        type = "ReplicaSetNoPrimary",
      })

      assert(manager:open())
      assert(runtime.clock:sleep(0.03))
      assert.is_not_nil(awaited_fields)
      assert.are.equal(version, awaited_fields.topology_version)
      assert.are.equal(60000, awaited_fields.max_await_time_ms)
      assert(manager:close())
    end)
  end)

  it("does not schedule RTT checks in polling mode", function()
    run_copas(function()
      local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
      local rtt_checks = 0
      local version = bson.document({
        { "processId", assert(bson.object_id("000000000000000000000001")) },
        { "counter", bson.int64(1) },
      })
      local manager = topology.new({
        check = function()
          return hello(true, version)
        end,
        heartbeat_frequency_ms = 10,
        min_heartbeat_frequency_ms = 5,
        pool_factory = new_pool,
        rtt_check = function()
          rtt_checks = rtt_checks + 1
          return 25
        end,
        runtime = runtime,
        seeds = { "a:27017" },
        server_monitoring_mode = "poll",
        set_name = "rs",
        type = "ReplicaSetNoPrimary",
      })

      assert(manager:open())
      assert(runtime.clock:sleep(0.025))
      assert(manager:close())
      assert.are.equal(0, rtt_checks)
    end)
  end)

  it("uses polling for auto mode on FaaS", function()
    run_copas(function()
      local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
      local awaited_checks = 0
      local checks = 0
      local rtt_checks = 0
      local version = bson.document({
        { "processId", assert(bson.object_id("000000000000000000000001")) },
        { "counter", bson.int64(1) },
      })
      local manager = topology.new({
        check = function(_, fields)
          checks = checks + 1

          if fields.awaited then
            awaited_checks = awaited_checks + 1
          end

          return hello(true, version)
        end,
        heartbeat_frequency_ms = 10,
        is_faas = true,
        min_heartbeat_frequency_ms = 5,
        pool_factory = new_pool,
        rtt_check = function()
          rtt_checks = rtt_checks + 1
          return 25
        end,
        runtime = runtime,
        seeds = { "a:27017" },
        server_monitoring_mode = "auto",
        set_name = "rs",
        type = "ReplicaSetNoPrimary",
      })

      assert(manager:open())
      assert(runtime.clock:sleep(0.025))
      assert(manager:close())

      assert.is_true(checks >= 2)
      assert.are.equal(0, awaited_checks)
      assert.are.equal(0, rtt_checks)
    end)
  end)

  it("shuts monitor tasks down cooperatively", function()
    run_copas(function()
      local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
      local hard_cancel = runtime.task.cancel
      local hard_cancel_count = 0
      local first_check = true
      local awaited_started = false
      local awaited_stopped = false
      local executor_resources_closed_after_stopped
      local monitor_resources_closed_after_stopped
      local rtt_started = false
      local rtt_stopped = false
      local version = bson.document({
        { "processId", assert(bson.object_id("000000000000000000000001")) },
        { "counter", bson.int64(1) },
      })
      local response = bson.document({
        { "ok", 1 },
        { "isWritablePrimary", true },
        { "setName", "rs" },
        { "hosts", bson.array({ "a:27017" }) },
        { "maxWireVersion", 21 },
        { "topologyVersion", version },
      })

      runtime.task.cancel = function(...)
        hard_cancel_count = hard_cancel_count + 1
        return hard_cancel(...)
      end

      local manager = topology.new({
        check = function(_, fields)
          if first_check then
            first_check = false
            return response, nil, 10
          end

          awaited_started = true
          local slept, err = runtime.clock:sleep(1, fields.cancellation)

          awaited_stopped = not slept
          return nil, err
        end,
        heartbeat_frequency_ms = 5,
        min_heartbeat_frequency_ms = 1,
        on_server_close = function()
          monitor_resources_closed_after_stopped = awaited_stopped and rtt_stopped
        end,
        pool_factory = new_pool,
        rtt_check = function(_, fields)
          rtt_started = true
          local slept = runtime.clock:sleep(1, fields.cancellation)

          rtt_stopped = not slept
        end,
        runtime = runtime,
        seeds = { "a:27017" },
        set_name = "rs",
        type = "ReplicaSetNoPrimary",
      })
      local commands = topology_executor.new(manager, {
        on_close = function()
          executor_resources_closed_after_stopped = awaited_stopped and rtt_stopped
        end,
      })

      assert(manager:open())

      while not awaited_started or not rtt_started do
        assert(runtime.clock:sleep(0.001))
      end

      assert(commands:close())
      assert.are.equal(0, hard_cancel_count)
      assert(runtime.clock:sleep(0.01))
      assert.is_true(awaited_stopped)
      assert.is_true(rtt_stopped)
      assert.is_true(monitor_resources_closed_after_stopped)
      assert.is_true(executor_resources_closed_after_stopped)
    end)
  end)

  it("cancels an awaited check before recovering from an application error", function()
    run_copas(function()
      local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
      local awaited_started = false
      local version = bson.document({
        { "processId", assert(bson.object_id("000000000000000000000001")) },
        { "counter", bson.int64(1) },
      })
      local response = bson.document({
        { "ok", 1 },
        { "isWritablePrimary", true },
        { "setName", "rs" },
        { "hosts", bson.array({ "a:27017" }) },
        { "maxWireVersion", 21 },
        { "topologyVersion", version },
      })
      local manager = topology.new({
        check = function(_, fields)
          if fields.awaited then
            awaited_started = true
            local slept, err = runtime.clock:sleep(1, fields.cancellation)

            if not slept then
              return nil, err
            end
          end

          return response, nil, 10
        end,
        heartbeat_frequency_ms = 10,
        min_heartbeat_frequency_ms = 5,
        pool_factory = new_pool,
        runtime = runtime,
        seeds = { "a:27017" },
        set_name = "rs",
        type = "ReplicaSetNoPrimary",
      })

      assert(manager:open())
      assert(runtime.clock:sleep(0.03))

      local handled = manager:handle_application_error("a:27017", {
        type = "network",
        when = "afterHandshakeCompletes",
      })
      assert(runtime.clock:sleep(0.03))

      local server = manager.description:server("a:27017")
      local server_type = server.type
      local round_trip_time = server.round_trip_time

      assert(manager:close())
      assert.is_true(awaited_started)
      assert.is_true(handled)
      assert.are.equal("RSPrimary", server_type)
      assert.are.equal(10, round_trip_time)
    end)
  end)

  it("interrupts in-use connections after a monitor network timeout", function()
    local runtime = fake_runtime.new()
    local closed = 0
    local cleared
    local event_types = {}
    local manager = topology.new({
      check = function()
        return nil, errors.new({
          category = errors.CATEGORY.NETWORK,
          message = "monitor timed out",
          timeout = true,
        })
      end,
      pool_factory = function(address)
        return pool.new({
          address = address,
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

              if event.type == "ConnectionPoolCleared" then
                cleared = event
              end
            end,
          },
          runtime = runtime,
        })
      end,
      runtime = runtime,
      seeds = { "a:27017" },
      type = "Single",
    })

    assert(manager:open({ background = false }))
    assert(manager:process_hello("a:27017", bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "maxWireVersion", 21 },
    })))
    local connection_pool = manager:pool("a:27017")
    local connection = assert(connection_pool:check_out())

    assert(manager:check_server("a:27017"))

    assert.is_true(connection.interrupted)
    assert.are.equal("in_use", connection.state)
    assert.are.equal(1, closed)
    assert.is_true(cleared.interrupt_in_use_connections)
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
    assert(manager:close())
  end)

  it("ignores a response returned by a cancelled awaited check", function()
    run_copas(function()
      local runtime = runtime_module.copas({ lock_poll_interval = 0.001 })
      local checks = 0
      local awaited_cancelled = false
      local fresh_started = false
      local version = bson.document({
        { "processId", assert(bson.object_id("000000000000000000000001")) },
        { "counter", bson.int64(1) },
      })
      local primary = bson.document({
        { "ok", 1 },
        { "isWritablePrimary", true },
        { "setName", "rs" },
        { "hosts", bson.array({ "a:27017" }) },
        { "maxWireVersion", 21 },
        { "topologyVersion", version },
      })
      local stale_secondary = bson.document({
        { "ok", 1 },
        { "secondary", true },
        { "setName", "rs" },
        { "hosts", bson.array({ "a:27017" }) },
        { "maxWireVersion", 21 },
        { "topologyVersion", version },
      })
      local manager = topology.new({
        check = function(_, fields)
          checks = checks + 1

          if checks == 1 then
            return primary, nil, 10
          elseif checks == 2 then
            while not fields.cancellation:is_cancelled() do
              assert(runtime.clock:sleep(0.001))
            end

            awaited_cancelled = true
            return stale_secondary, nil, 10
          end

          fresh_started = true
          local slept, err = runtime.clock:sleep(1, fields.cancellation)

          if not slept then
            return nil, err
          end

          return primary, nil, 10
        end,
        heartbeat_frequency_ms = 10,
        min_heartbeat_frequency_ms = 5,
        pool_factory = new_pool,
        runtime = runtime,
        seeds = { "a:27017" },
        set_name = "rs",
        type = "ReplicaSetNoPrimary",
      })

      assert(manager:open())
      assert(runtime.clock:sleep(0.03))
      assert(manager:handle_application_error("a:27017", {
        type = "network",
        when = "afterHandshakeCompletes",
      }))
      assert(runtime.clock:sleep(0.03))

      local server_type = manager.description:server("a:27017").type

      assert(manager:close())
      assert.is_true(awaited_cancelled)
      assert.is_true(fresh_started)
      assert.are.equal("Unknown", server_type)
    end)
  end)

  it("rescans unknown servers until a writable member is selectable", function()
    local runtime = fake_runtime.new()
    local manager = topology.new({
      check = function(address)
        return hello(address == "b:27017")
      end,
      pool_factory = new_pool,
      runtime = runtime,
      seeds = { "a:27017", "b:27017" },
      set_name = "rs",
      type = "ReplicaSetNoPrimary",
    })

    assert(manager:open({ background = false }))
    local selected, selected_pool = manager:select_server("write", nil, {
      timeout_ms = 1000,
    })

    assert.are.equal("b:27017", selected.address)
    assert.are.equal("ready", selected_pool.state)
    assert(manager:close())
  end)

  it("checks pooled commands out from the selected replica-set member", function()
    local runtime = fake_runtime.new()
    local command_addresses = {}
    local measured_command
    local measured_options
    local sent_commands = {}
    local manager
    local function pool_factory(address)
      return pool.new({
        address = address,
        connect = function()
          local resource = {}

          function resource.capabilities()
            return { max_wire_version = 21 }
          end

          function resource.close()
            return true
          end

          function resource.command(_, _, command)
            command_addresses[#command_addresses + 1] = address
            sent_commands[#sent_commands + 1] = command
            return bson.document({ { "ok", 1 } })
          end

          function resource.measure(_, _, command, options)
            measured_command = command
            measured_options = options
            return { message_size = 32 }
          end

          return resource
        end,
        runtime = runtime,
      })
    end

    manager = topology.new({
      pool_factory = pool_factory,
      runtime = runtime,
      seeds = { "a:27017", "b:27017" },
      set_name = "rs",
      type = "ReplicaSetNoPrimary",
    })
    local function with_last_write(response)
      local entries = response:entries()

      entries[#entries + 1] = {
        "lastWrite",
        bson.document({ { "lastWriteDate", bson.datetime(100000) } }),
      }
      return bson.document(entries)
    end

    assert(manager:open({ background = false }))
    assert(manager:process_hello(
      "a:27017",
      with_last_write(hello(false)),
      { duration = 0.001 }
    ))
    assert(manager:process_hello(
      "b:27017",
      with_last_write(hello(true)),
      { duration = 0.001 }
    ))
    local commands = topology_executor.new(manager)

    assert(commands:command(
      "db",
      bson.document({ { "find", "items" } }),
      {
        read_preference = {
          max_staleness_seconds = -1,
          mode = "secondary",
          tag_sets = { {} },
        },
      }
    ))
    assert(commands:command("db", bson.document({ { "insert", "items" } })))
    local continued_on
    local continued_type
    assert(commands:command(
      "db",
      bson.document({ { "getMore", bson.int64(1) }, { "collection", "items" } }),
      {
        on_server_selected = function(address, server_type)
          continued_on = address
          continued_type = server_type
        end,
        server_address = "a:27017",
      }
    ))
    local measurement = assert(commands:measure(
      "db",
      bson.document({ { "find", "items" } }),
      {
        read_preference = {
          max_staleness_seconds = 120,
          mode = "secondary",
          tag_sets = { {}, { zone = "b", region = "east" } },
        },
        socket_deadline = 1,
        socket_deadline_factory = function() return 42 end,
      }
    ))

    assert.same({ "a:27017", "b:27017", "a:27017" }, command_addresses)
    assert.are.equal(32, measurement.message_size)
    assert.are.equal(42, measured_options.socket_deadline)
    assert.is_nil(measured_options.socket_deadline_factory)
    assert.are.equal(
      120,
      measured_command:get("$readPreference"):get("maxStalenessSeconds")
    )
    local measured_tags = measured_command:get("$readPreference"):get("tags")

    assert.are.equal(2, #measured_tags)
    assert.are.equal("east", measured_tags:get(2):get("region"))
    assert.same({ "region", "zone" }, measured_tags:get(2):keys())
    assert.are.equal("a:27017", continued_on)
    assert.are.equal("RSSecondary", continued_type)
    assert.are.equal(
      "secondary",
      sent_commands[1]:get("$readPreference"):get("mode")
    )
    assert.is_nil(sent_commands[2]:get("$readPreference"))
    assert.is_nil(sent_commands[3]:get("$readPreference"))
    assert.are.equal(0, manager:pool("a:27017").operation_count)
    assert.are.equal(0, manager:pool("b:27017").operation_count)
    assert(commands:close())
  end)

  it("routes enumeration commands through every required topology role", function()
    local cases = {
      {
        address = "standalone:27017",
        hello = bson.document({
          { "ok", 1 },
          { "isWritablePrimary", true },
          { "maxWireVersion", 25 },
        }),
        name = "standalone",
        topology_type = "Single",
      },
      {
        address = "primary:27017",
        hello = bson.document({
          { "ok", 1 },
          { "isWritablePrimary", true },
          { "setName", "rs" },
          { "hosts", bson.array({ "primary:27017" }) },
          { "maxWireVersion", 25 },
        }),
        name = "replica-set primary",
        set_name = "rs",
        topology_type = "ReplicaSetNoPrimary",
      },
      {
        address = "secondary:27017",
        hello = bson.document({
          { "ok", 1 },
          { "isWritablePrimary", false },
          { "secondary", true },
          { "setName", "rs" },
          { "hosts", bson.array({ "secondary:27017" }) },
          { "maxWireVersion", 25 },
        }),
        name = "direct replica-set secondary",
        topology_type = "Single",
      },
      {
        address = "mongos:27017",
        hello = bson.document({
          { "ok", 1 },
          { "msg", "isdbgrid" },
          { "maxWireVersion", 25 },
        }),
        name = "mongos",
        topology_type = "Unknown",
      },
    }

    for _, case in ipairs(cases) do
      local runtime = fake_runtime.new()
      local selected_addresses = {}
      local manager = topology.new({
        pool_factory = function(address)
          return pool.new({
            address = address,
            connect = function()
              return {
                close = function() return true end,
                command = function()
                  selected_addresses[#selected_addresses + 1] = address
                  return bson.document({ { "ok", 1 } })
                end,
              }
            end,
            runtime = runtime,
          })
        end,
        runtime = runtime,
        seeds = { case.address },
        set_name = case.set_name,
        type = case.topology_type,
      })

      assert(manager:open({ background = false }), case.name)
      assert(manager:process_hello(case.address, case.hello, {
        duration = 0.001,
      }), case.name)
      local commands = topology_executor.new(manager, {
        read_preference = {
          max_staleness_seconds = -1,
          mode = "secondary",
          tag_sets = { {} },
        },
      })
      local primary = {
        max_staleness_seconds = -1,
        mode = "primary",
        tag_sets = { {} },
      }

      assert(commands:command(
        "admin",
        bson.document({ { "listDatabases", 1 } }),
        { read_preference = primary }
      ), case.name)
      assert(commands:command(
        "app",
        bson.document({ { "listCollections", 1 } }),
        { read_preference = primary }
      ), case.name)
      assert.same({ case.address, case.address }, selected_addresses, case.name)
      assert(commands:close(), case.name)
    end
  end)

  it("starts socket timeouts after topology checkout", function()
    local runtime = fake_runtime.new({ now = 10 })
    local received_deadline
    local manager = topology.new({
      pool_factory = function(address)
        return pool.new({
          address = address,
          connect = function()
            runtime:advance(1)
            return {
              close = function() return true end,
              command = function(_, _, _, options)
                received_deadline = options.socket_deadline
                return bson.document({ { "ok", 1 } })
              end,
            }
          end,
          runtime = runtime,
        })
      end,
      runtime = runtime,
      seeds = { "a:27017" },
      set_name = "rs",
      type = "ReplicaSetNoPrimary",
    })

    assert(manager:open({ background = false }))
    assert(manager:process_hello("a:27017", bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "setName", "rs" },
      { "hosts", bson.array({ "a:27017" }) },
      { "maxWireVersion", 21 },
    }), { duration = 0.001 }))
    local commands = socket_timeout_executor.new(
      topology_executor.new(manager),
      runtime,
      250
    )

    assert(commands:command("db", bson.document({ { "ping", 1 } })))
    assert.near(11.25, received_deadline, 0.000001)
    assert(commands:close())
  end)

  it("does not report a cleared-pool checkout as an application error", function()
    local runtime = fake_runtime.new()
    local manager = topology.new({
      pool_factory = function(address)
        return pool.new({
          address = address,
          connect = function()
            error("cleared pool must not establish a connection")
          end,
          runtime = runtime,
        })
      end,
      runtime = runtime,
      seeds = { "a:27017" },
      type = "Single",
    })

    assert(manager:open({ background = false }))
    assert(manager:process_hello("a:27017", bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "maxWireVersion", 21 },
    }), { duration = 0.001 }))
    local connection_pool = manager:pool("a:27017")
    local commands = topology_executor.new(manager)

    assert(connection_pool:clear(false))
    local response, err = commands:command(
      "db",
      bson.document({ { "ping", 1 } })
    )

    assert.is_nil(response)
    assert.is_true(errors.is(err, errors.CATEGORY.POOL))
    assert.are.equal("Standalone", manager.description:server("a:27017").type)
    assert.are.equal(1, connection_pool.generation)
    assert(commands:close())
  end)

  it("discards a cancelled pooled connection without an SDAM failure", function()
    local runtime = fake_runtime.new()
    local connect_count = 0
    local closed_count = 0
    local manager = topology.new({
      pool_factory = function(address)
        return pool.new({
          address = address,
          connect = function()
            connect_count = connect_count + 1
            local cancelled = connect_count == 1

            return {
              close = function()
                closed_count = closed_count + 1
                return true
              end,
              command = function()
                if cancelled then
                  return nil, errors.new({
                    category = errors.CATEGORY.CANCELLED,
                    message = "stop pooled read",
                  })
                end

                return bson.document({ { "ok", 1 } })
              end,
            }
          end,
          runtime = runtime,
        })
      end,
      runtime = runtime,
      seeds = { "a:27017" },
      type = "Single",
    })

    assert(manager:open({ background = false }))
    assert(manager:process_hello("a:27017", bson.document({
      { "ok", 1 },
      { "isWritablePrimary", true },
      { "maxWireVersion", 21 },
    }), { duration = 0.001 }))
    local commands = topology_executor.new(manager)
    local response, err = commands:command(
      "db",
      bson.document({ { "ping", 1 } })
    )

    assert.is_nil(response)
    assert.is_true(errors.is(err, errors.CATEGORY.CANCELLED))
    assert.are.equal("Standalone", manager.description:server("a:27017").type)
    assert.are.equal(0, manager:pool("a:27017").generation)
    assert(commands:command("db", bson.document({ { "ping", 1 } })))
    assert.are.equal(2, connect_count)
    assert.are.equal(1, closed_count)
    assert(commands:close())
  end)

  it("clears a failed primary and selects its promoted replica", function()
    local runtime = fake_runtime.new()
    local manager = topology.new({
      pool_factory = new_pool,
      runtime = runtime,
      seeds = { "a:27017", "b:27017" },
      set_name = "rs",
      type = "ReplicaSetNoPrimary",
    })

    assert(manager:open({ background = false }))
    assert(manager:process_hello("a:27017", hello(true), { duration = 0.001 }))
    assert(manager:process_hello("b:27017", hello(false), { duration = 0.001 }))
    assert(manager:handle_application_error("a:27017", {
      type = "network",
      when = "afterHandshakeCompletes",
    }))

    assert.are.equal("ReplicaSetNoPrimary", manager.description.type)
    assert.are.equal(1, manager:pool("a:27017").generation)
    assert(manager:process_hello("b:27017", hello(true), { duration = 0.001 }))
    local selected = assert(manager:select_server("write", nil, { timeout_ms = 1 }))

    assert.are.equal("b:27017", selected.address)
    assert(manager:close())
  end)

  it("orders shutdown events and ignores late monitor results", function()
    local runtime = fake_runtime.new()
    local events = {}
    local topology_changes = {}
    local manager = topology.new({
      listeners = {
        function(event)
          events[#events + 1] = event.type

          if event.type == "TopologyDescriptionChanged" then
            topology_changes[#topology_changes + 1] = event
          end
        end,
      },
      pool_factory = new_pool,
      runtime = runtime,
      seeds = { "a:27017" },
      type = "Single",
    })

    assert(manager:open({ background = false }))
    assert(manager:close())
    local count = #events

    assert.are.equal("Unknown", topology_changes[1].previous_description.type)
    assert.are.equal("Single", topology_changes[1].new_description.type)
    assert.are.equal("Single", topology_changes[2].previous_description.type)
    assert.are.equal("Unknown", topology_changes[2].new_description.type)
    assert.are.equal(0, #topology_changes[2].new_description:addresses())
    assert.are.equal(topology_changes[2].new_description, manager.description)
    assert.is_false(manager:process_hello("a:27017", bson.document({ { "ok", 1 } })))
    assert.are.equal(count, #events)
    assert.same({
      "TopologyDescriptionChanged",
      "ServerClosed",
      "TopologyClosed",
    }, { events[count - 2], events[count - 1], events[count] })
  end)

  it("publishes Sharded shutdown before topology close exactly once", function()
    local events = {}
    local topology_changes = {}
    local manager = topology.new({
      listeners = {
        function(event)
          events[#events + 1] = event.type

          if event.type == "TopologyDescriptionChanged" then
            topology_changes[#topology_changes + 1] = event
          end
        end,
      },
      pool_factory = new_pool,
      runtime = fake_runtime.new(),
      seeds = { "mongos:27017" },
      type = "Unknown",
    })

    assert(manager:open({ background = false }))
    assert(manager:process_hello("mongos:27017", bson.document({
      { "ok", 1 },
      { "msg", "isdbgrid" },
      { "maxWireVersion", 25 },
    }), { duration = 0.01 }))
    assert(manager:close())
    local count = #events
    local shutdown = topology_changes[#topology_changes]

    assert.are.equal("Sharded", shutdown.previous_description.type)
    assert.are.equal("Unknown", shutdown.new_description.type)
    assert.are.equal(0, #shutdown.new_description:addresses())
    assert.are.equal(shutdown.new_description, manager.description)
    assert.same({
      "TopologyDescriptionChanged",
      "ServerClosed",
      "TopologyClosed",
    }, { events[count - 2], events[count - 1], events[count] })
    assert.is_false(manager:close())
    assert.are.equal(count, #events)
  end)
end)
