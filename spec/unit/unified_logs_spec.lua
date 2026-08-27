local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local logging = require("mongodb.logging")
local fake_runtime = require("mongodb.runtime.fake")
local logs = require("mongodb.unified.logs")
local runner_module = require("mongodb.unified.runner")

local function array(values)
  return bson.array(values)
end

local function document(entries)
  return bson.document(entries)
end

local function expected_message(component, level, data, failure_is_redacted)
  local entries = {
    { "component", component },
    { "level", level },
    { "data", data },
  }

  if failure_is_redacted ~= nil then
    entries[#entries + 1] = { "failureIsRedacted", failure_is_redacted }
  end

  return document(entries)
end

local function expected_group(messages, options)
  options = options or {}
  local entries = {
    { "client", "client0" },
    { "messages", array(messages) },
  }

  if options.ignore_messages then
    entries[#entries + 1] = { "ignoreMessages", array(options.ignore_messages) }
  end

  if options.ignore_extra ~= nil then
    entries[#entries + 1] = { "ignoreExtraMessages", options.ignore_extra }
  end

  return array({ document(entries) })
end

local function setup()
  local runner = runner_module.new({ runtime = fake_runtime.new() })
  local client = {}
  local collector = assert(logs.new(document({
    { "observeLogMessages", document({
      { "command", "debug" },
      { "serverSelection", "info" },
    }) },
  })))
  local logger = assert(logging.new(fake_runtime.new(), collector:options()))

  assert(runner:add_entity("client0", "client", client))
  return runner, collector, { [client] = collector }, logger
end

describe("unified log expectations", function()
  it("matches configured messages in order after unordered ignores", function()
    local runner, collector, collectors, logger = setup()

    assert.is_true(logger:emit("command", "debug", {
      command = document({ { "find", "events" }, { "$db", "app" } }),
      commandName = "find",
      message = "Command started",
    }, {
      document_fields = { command = false },
    }))
    assert.is_true(logger:emit("command", "info", {
      message = "ignore me",
    }))
    assert.is_true(logger:emit("server_selection", "info", {
      message = "Server selection started",
      operation = "find",
    }))
    assert.is_false(logger:emit("topology", "debug", {
      message = "Topology description changed",
    }))

    assert(logs.assert_all(runner, expected_group({
      expected_message("command", "debug", document({
        { "message", "Command started" },
        { "commandName", "find" },
        { "command", document({
          { "$$matchAsDocument", document({
            { "find", "events" },
            { "$db", "app" },
          }) },
        }) },
      })),
      expected_message("serverSelection", "info", document({
        { "message", "Server selection started" },
        { "operation", "find" },
      })),
    }, {
      ignore_messages = {
        expected_message("command", "info", document({
          { "message", "ignore me" },
        })),
      },
    }), collectors, "$.expectLogMessages"))
    assert.is_false(collector.active)
  end)

  it("permits only trailing extra messages when requested", function()
    local runner, _, collectors, logger = setup()

    assert.is_true(logger:emit("command", "debug", { message = "first" }))
    assert.is_true(logger:emit("command", "debug", { message = "trailing" }))
    assert(logs.assert_all(runner, expected_group({
      expected_message("command", "debug", document({ { "message", "first" } })),
    }, { ignore_extra = true }), collectors, "$.expectLogMessages"))
  end)

  it("matches explicit redacted and unredacted failures", function()
    local runner, _, collectors, logger = setup()

    assert.is_true(logger:emit("command", "debug", {
      failure = "",
      message = "Command failed",
    }))
    assert.is_true(logger:emit("command", "debug", {
      failure = "network error",
      message = "Command failed",
    }))
    assert(logs.assert_all(runner, expected_group({
      expected_message("command", "debug", document({
        { "message", "Command failed" },
      }), true),
      expected_message("command", "debug", document({
        { "message", "Command failed" },
      }), false),
    }), collectors, "$.expectLogMessages"))
  end)

  it("reports exact count and ordering failures at deterministic paths", function()
    local runner, _, collectors, logger = setup()

    assert.is_true(logger:emit("command", "debug", { message = "actual" }))

    local ok, err = logs.assert_all(runner, expected_group({}), collectors,
      "$.expectLogMessages")

    assert.is_nil(ok)
    assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    assert.are.equal("$.expectLogMessages[1].messages", err.details.path)

    runner, _, collectors, logger = setup()
    assert.is_true(logger:emit("command", "debug", { message = "actual" }))
    ok, err = logs.assert_all(runner, expected_group({
      expected_message("command", "debug", document({ { "message", "expected" } })),
    }), collectors, "$.expectLogMessages")

    assert.is_nil(ok)
    assert.are.equal("$.expectLogMessages[1].messages[1].data.message", err.details.path)
  end)
end)
