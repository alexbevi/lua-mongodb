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
end)
