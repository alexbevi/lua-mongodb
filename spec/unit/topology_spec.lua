local bson = require("mongodb.bson")
local copas = require("copas")
local fake_runtime = require("mongodb.runtime.fake")
local pool = require("mongodb.pool")
local runtime_module = require("mongodb.runtime")
local sdam_runner = require("spec.support.sdam_runner")
local topology = require("mongodb.topology")
local topology_executor = require("mongodb.topology_executor")

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

  it("runs every applicable pinned SDAM monitoring event fixture", function()
    local paths = sdam_runner.fixture_paths("monitoring")
    local count = 0

    for _, path in ipairs(paths) do
      if path ~= "monitoring/load_balancer.json" then
        assert(sdam_runner.run(path))
        count = count + 1
      end
    end

    assert.are.equal(7, count)
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

          function resource.measure()
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
    assert(manager:open({ background = false }))
    assert(manager:process_hello("a:27017", hello(false), { duration = 0.001 }))
    assert(manager:process_hello("b:27017", hello(true), { duration = 0.001 }))
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
    assert(commands:command(
      "db",
      bson.document({ { "getMore", bson.int64(1) }, { "collection", "items" } }),
      {
        on_server_selected = function(address)
          continued_on = address
        end,
        server_address = "a:27017",
      }
    ))

    assert.same({ "a:27017", "b:27017", "a:27017" }, command_addresses)
    assert.are.equal("a:27017", continued_on)
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
end)
