local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local event_module = require("mongodb.unified.events")
local fake_runtime = require("mongodb.runtime.fake")
local runner_module = require("mongodb.unified.runner")

local function array(values)
  return bson.array(values)
end

local function document(entries)
  return bson.document(entries)
end

local function expected_events(values, extra)
  local entries = {
    { "client", "client0" },
    { "events", array(values) },
  }

  if extra ~= nil then
    entries[#entries + 1] = { "ignoreExtraEvents", extra }
  end

  return array({
    document(entries),
  })
end

local function expected_cmap_events(values)
  return array({
    document({
      { "client", "client0" },
      { "eventType", "cmap" },
      { "events", array(values) },
    }),
  })
end

local function expected_sdam_events(values)
  return array({
    document({
      { "client", "client0" },
      { "eventType", "sdam" },
      { "events", array(values) },
    }),
  })
end

local function expected_event(name, command_name)
  return document({
    { name, document({ { "commandName", command_name } }) },
  })
end

local function actual_event(kind, command_name)
  return {
    command = document({ { command_name, "coll" } }),
    command_name = command_name,
    database_name = "db",
    reply = document({ { "ok", 1 } }),
    type = kind,
  }
end

local function setup()
  local runner = runner_module.new({ runtime = fake_runtime.new() })
  local client = {}
  local collector = assert(event_module.new(document({
    { "observeEvents", array({
      "commandFailedEvent",
      "commandStartedEvent",
      "commandSucceededEvent",
    }) },
  })))

  assert(runner:add_entity("client0", "client", client))
  return runner, collector, { [client] = collector }
end

describe("unified command events", function()
  it("tracks live pool population and resets warm-up events", function()
    local _, collector = setup()
    local address = "127.0.0.1:27017"
    local second_address = "127.0.0.1:27018"

    collector.pool_listener:ConnectionPoolReady({ address = address })
    collector.pool_listener:ConnectionPoolReady({ address = second_address })
    assert.is_false(collector:pools_populated(1))

    collector.pool_listener:ConnectionReady({
      address = address,
      connection_id = 1,
    })
    assert.is_false(collector:pools_populated(1))
    assert.are.equal(0, collector:connections_checked_out())
    collector.pool_listener:ConnectionCheckedOut({
      address = address,
      connection_id = 1,
    })
    assert.are.equal(1, collector:connections_checked_out())
    collector.pool_listener:ConnectionCheckedIn({
      address = address,
      connection_id = 1,
    })
    assert.are.equal(0, collector:connections_checked_out())

    collector.pool_listener:ConnectionReady({
      address = second_address,
      connection_id = 2,
    })
    assert.is_true(collector:pools_populated(1))

    collector.listener:started(actual_event("command_started", "find"))
    assert.are.equal(1, collector:count("commandStartedEvent", "find"))
    collector:reset()
    assert.are.equal(0, collector:count("commandStartedEvent", "find"))

    collector.pool_listener:ConnectionClosed({
      address = address,
      connection_id = 1,
    })
    assert.is_false(collector:pools_populated(1))

    collector.pool_listener:ConnectionPoolClosed({ address = address })
    assert.is_true(collector:pools_populated(1))
  end)

  it("counts pool-ready events and matching unknown server transitions", function()
    local collector = assert(event_module.new(document({
      { "observeEvents", array({
        "poolReadyEvent",
        "serverDescriptionChangedEvent",
      }) },
    })))

    collector.pool_listener:ConnectionPoolReady({
      address = "127.0.0.1:27017",
    })
    collector.sdam_listener:ServerDescriptionChanged({
      address = "127.0.0.1:27017",
      new_description = { type = "Unknown" },
    })

    assert.are.equal(1, collector:count("poolReadyEvent", document({})))
    assert.are.equal(1, collector:count(
      "serverDescriptionChangedEvent",
      document({
        { "newDescription", document({ { "type", "Unknown" } }) },
      })
    ))
    assert.are.equal(0, collector:count(
      "serverDescriptionChangedEvent",
      document({
        { "newDescription", document({ { "type", "Standalone" } }) },
      })
    ))
  end)

  it("retains the latest topology description without observing topology events", function()
    local collector = assert(event_module.new(document({})))
    local description = { type = "ReplicaSetWithPrimary" }

    assert.is_false(collector:observes_sdam())
    assert.is_nil(collector:topology_description())
    collector.sdam_listener:TopologyDescriptionChanged({
      new_description = description,
    })
    assert.are.equal(description, collector:topology_description())
  end)

  it("matches topology lifecycle descriptions in publication order", function()
    local runner = runner_module.new({ runtime = fake_runtime.new() })
    local client = {}
    local collector = assert(event_module.new(document({
      { "observeEvents", array({
        "topologyOpeningEvent",
        "topologyDescriptionChangedEvent",
        "topologyClosedEvent",
      }) },
    })))

    assert.is_true(collector:observes_sdam())
    assert(runner:add_entity("client0", "client", client))
    collector.sdam_listener:TopologyOpening({})
    collector.sdam_listener:TopologyDescriptionChanged({
      new_description = { type = "ReplicaSetWithPrimary" },
      previous_description = { type = "ReplicaSetNoPrimary" },
    })
    collector.sdam_listener:TopologyClosed({})

    assert.are.equal(1, collector:count(
      "topologyDescriptionChangedEvent",
      document({})
    ))
    assert(event_module.assert_all(runner, expected_sdam_events({
      document({ { "topologyOpeningEvent", document({}) } }),
      document({
        { "topologyDescriptionChangedEvent", document({
          { "previousDescription", document({
            { "type", "ReplicaSetNoPrimary" },
          }) },
          { "newDescription", document({
            { "type", "ReplicaSetWithPrimary" },
          }) },
        }) },
      }),
      document({ { "topologyClosedEvent", document({}) } }),
    }), { [client] = collector }, "$.expectEvents"))
  end)

  it("collects heartbeat events with their awaited state", function()
    local runner = runner_module.new({ runtime = fake_runtime.new() })
    local client = {}
    local collector = assert(event_module.new(document({
      { "observeEvents", array({
        "serverHeartbeatStartedEvent",
        "serverHeartbeatSucceededEvent",
        "serverHeartbeatFailedEvent",
      }) },
    })))

    assert.is_true(collector:observes_heartbeat())
    assert(runner:add_entity("client0", "client", client))
    collector.heartbeat_listener:ServerHeartbeatStarted({ awaited = false })
    collector.heartbeat_listener:ServerHeartbeatSucceeded({ awaited = false })
    collector.heartbeat_listener:ServerHeartbeatStarted({ awaited = true })

    assert.are.equal(2, collector:count(
      "serverHeartbeatStartedEvent",
      document({})
    ))
    assert(event_module.assert_all(runner, expected_sdam_events({
      document({
        { "serverHeartbeatStartedEvent", document({ { "awaited", false } }) },
      }),
      document({
        { "serverHeartbeatSucceededEvent", document({ { "awaited", false } }) },
      }),
      document({
        { "serverHeartbeatStartedEvent", document({ { "awaited", true } }) },
      }),
    }), { [client] = collector }, "$.expectEvents"))
  end)

  it("matches event order and permits only trailing events when requested", function()
    local runner, collector, collectors = setup()

    collector.listener:started(actual_event("command_started", "find"))
    collector.listener:succeeded(actual_event("command_succeeded", "find"))
    assert(event_module.assert_all(runner, expected_events({
      expected_event("commandStartedEvent", "find"),
    }, true), collectors, "$.expectEvents"))
  end)

  it("matches failed events and validates server identifiers", function()
    local runner, collector, collectors = setup()
    local event = actual_event("command_failed", "find")

    event.server_connection_id = 42
    event.service_id = bson.object_id("0123456789abcdef01234567")
    collector.listener:failed(event)
    assert(event_module.assert_all(runner, expected_events({
      document({
        { "commandFailedEvent", document({
          { "commandName", "find" },
          { "hasServerConnectionId", true },
          { "hasServiceId", true },
        }) },
      }),
    }), collectors, "$.expectEvents"))
  end)

  it("reports missing and extra events at the client event path", function()
    local runner, _, collectors = setup()
    local ok, err = event_module.assert_all(runner, expected_events({
      expected_event("commandStartedEvent", "find"),
    }), collectors, "$.expectEvents")

    assert.is_nil(ok)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("$.expectEvents[1].events", err.details.path)

    local collector
    runner, collector, collectors = setup()
    collector.listener:started(actual_event("command_started", "find"))
    collector.listener:succeeded(actual_event("command_succeeded", "find"))
    ok, err = event_module.assert_all(runner, expected_events({
      expected_event("commandStartedEvent", "find"),
    }), collectors, "$.expectEvents")

    assert.is_nil(ok)
    assert.are.equal("$.expectEvents[1].events", err.details.path)
  end)

  it("reports reordered and unknown events at the exact event path", function()
    local runner, collector, collectors = setup()

    collector.listener:succeeded(actual_event("command_succeeded", "find"))
    local ok, err = event_module.assert_all(runner, expected_events({
      expected_event("commandStartedEvent", "find"),
    }), collectors, "$.expectEvents")

    assert.is_nil(ok)
    assert.are.equal("$.expectEvents[1].events[1]", err.details.path)

    runner, collector, collectors = setup()
    collector.listener:started(actual_event("command_started", "find"))
    ok, err = event_module.assert_all(runner, expected_events({
      expected_event("futureCommandEvent", "find"),
    }), collectors, "$.expectEvents")

    assert.is_nil(ok)
    assert.are.equal("$.expectEvents[1].events[1]", err.details.path)
  end)

  it("matches checkout-started, ready, checked-out, and checked-in events", function()
    local runner = runner_module.new({ runtime = fake_runtime.new() })
    local client = {}
    local collector = assert(event_module.new(document({
      { "observeEvents", array({
        "connectionCheckOutStartedEvent",
        "connectionReadyEvent",
        "connectionCheckedOutEvent",
        "connectionCheckedInEvent",
      }) },
    })))

    assert(runner:add_entity("client0", "client", client))
    collector.pool_listener:ConnectionCheckOutStarted({
      address = "127.0.0.1:27017",
    })
    collector.pool_listener:ConnectionReady({
      address = "127.0.0.1:27017",
      connection_id = 1,
      duration_ms = 2,
    })
    collector.pool_listener:ConnectionCheckedOut({
      address = "127.0.0.1:27017",
      connection_id = 1,
      duration_ms = 3,
    })
    collector.pool_listener:ConnectionCheckedIn({
      address = "127.0.0.1:27017",
      connection_id = 1,
    })

    assert(event_module.assert_all(runner, expected_cmap_events({
      document({ { "connectionCheckOutStartedEvent", document({}) } }),
      document({ { "connectionReadyEvent", document({}) } }),
      document({ { "connectionCheckedOutEvent", document({}) } }),
      document({ { "connectionCheckedInEvent", document({}) } }),
    }), { [client] = collector }, "$.expectEvents"))
  end)

  it("matches whether a pool clear interrupted in-use connections", function()
    local runner = runner_module.new({ runtime = fake_runtime.new() })
    local client = {}
    local collector = assert(event_module.new(document({
      { "observeEvents", array({ "poolClearedEvent" }) },
    })))

    assert(runner:add_entity("client0", "client", client))
    local service_id = bson.object_id("0123456789abcdef01234567")

    collector.pool_listener:ConnectionPoolCleared({
      address = "127.0.0.1:27017",
      interrupt_in_use_connections = true,
      service_id = service_id,
    })

    assert(event_module.assert_all(runner, expected_cmap_events({
      document({
        { "poolClearedEvent", document({
          { "hasServiceId", true },
          { "interruptInUseConnections", true },
        }) },
      }),
    }), { [client] = collector }, "$.expectEvents"))
  end)

  it("discards only an eager construction checkout start", function()
    local runner = runner_module.new({ runtime = fake_runtime.new() })
    local client = {}
    local collector = assert(event_module.new(document({
      { "observeEvents", array({
        "connectionCheckOutStartedEvent",
        "connectionCreatedEvent",
      }) },
    })))

    assert(runner:add_entity("client0", "client", client))
    collector.pool_listener:ConnectionCheckOutStarted({
      address = "127.0.0.1:27017",
    })
    collector.pool_listener:ConnectionCreated({
      address = "127.0.0.1:27017",
      connection_id = 1,
    })
    collector:discard_type("connection_checkout_started")

    assert(event_module.assert_all(runner, expected_cmap_events({
      document({ { "connectionCreatedEvent", document({}) } }),
    }), { [client] = collector }, "$.expectEvents"))
  end)

  it("rejects unknown expected connection events", function()
    local runner = runner_module.new({ runtime = fake_runtime.new() })
    local client = {}
    local collector = assert(event_module.new(document({
      { "observeEvents", array({ "connectionReadyEvent" }) },
    })))

    assert(runner:add_entity("client0", "client", client))
    collector.pool_listener:ConnectionReady({
      address = "127.0.0.1:27017",
      connection_id = 1,
      duration_ms = 2,
    })

    local ok, err = event_module.assert_all(runner, expected_cmap_events({
      document({ { "futureConnectionEvent", document({}) } }),
    }), { [client] = collector }, "$.expectEvents")

    assert.is_nil(ok)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("$.expectEvents[1].events[1]", err.details.path)
  end)
end)
