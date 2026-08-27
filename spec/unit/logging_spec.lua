local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local logging = require("mongodb.logging")
local fake_runtime = require("mongodb.runtime.fake")

describe("structured logging configuration", function()
  it("defaults every component to off and output to stderr", function()
    local runtime = fake_runtime.new()
    local logger = assert(logging.new(runtime))

    for _, component in ipairs({
      "command",
      "connection",
      "server_selection",
      "topology",
    }) do
      assert.is_false(logger:enabled(component, "emergency"))
      assert.is_false(logger:enabled(component, "trace"))
    end

    assert.are.equal("stderr", logger.destination)
    assert.are.equal(1000, logger.max_document_length)
  end)

  it("applies component environment values over the all-component value", function()
    local runtime = fake_runtime.new({
      environment = {
        MONGODB_LOG_ALL = "info",
        MONGODB_LOG_COMMAND = "DEBUG",
        MONGODB_LOG_MAX_DOCUMENT_LENGTH = "48",
        MONGODB_LOG_PATH = "STDOUT",
        MONGODB_LOG_SERVER_SELECTION = "off",
      },
    })
    local logger = assert(logging.new(runtime))

    assert.is_true(logger:enabled("command", "debug"))
    assert.is_false(logger:enabled("command", "trace"))
    assert.is_true(logger:enabled("connection", "info"))
    assert.is_false(logger:enabled("connection", "debug"))
    assert.is_false(logger:enabled("server_selection", "emergency"))
    assert.are.equal("stdout", logger.destination)
    assert.are.equal(48, logger.max_document_length)

    assert(logger:output("configured event"))
    assert.are.same({
      { destination = "stdout", value = "configured event" },
    }, runtime.calls.output)
  end)

  it("ignores invalid environment values without raising", function()
    local runtime = fake_runtime.new({
      environment = {
        MONGODB_LOG_ALL = "verbose",
        MONGODB_LOG_COMMAND = "loud",
        MONGODB_LOG_MAX_DOCUMENT_LENGTH = "-1",
        MONGODB_LOG_PATH = "/tmp/driver.log",
      },
    })
    local logger = assert(logging.new(runtime))

    assert.is_false(logger:enabled("command", "emergency"))
    assert.are.equal("stderr", logger.destination)
    assert.are.equal(1000, logger.max_document_length)
  end)

  it("gives valid programmatic values precedence over the environment", function()
    local runtime = fake_runtime.new({
      environment = {
        MONGODB_LOG_ALL = "trace",
        MONGODB_LOG_MAX_DOCUMENT_LENGTH = "200",
        MONGODB_LOG_PATH = "stdout",
      },
    })
    local logger = assert(logging.new(runtime, {
      destination = "stderr",
      levels = {
        all = "error",
        command = "debug",
      },
      max_document_length = 25,
    }))

    assert.is_true(logger:enabled("command", "debug"))
    assert.is_false(logger:enabled("command", "trace"))
    assert.is_true(logger:enabled("topology", "error"))
    assert.is_false(logger:enabled("topology", "warn"))
    assert.are.equal("stderr", logger.destination)
    assert.are.equal(25, logger.max_document_length)
  end)

  it("accepts a callback sink and keeps configuration immutable", function()
    local observed = {}
    local logger = assert(logging.new(fake_runtime.new(), {
      levels = { command = "debug" },
      sink = function(value)
        observed[#observed + 1] = value
        return true
      end,
    }))

    assert(logger:output("custom event"))
    assert.are.same({ "custom event" }, observed)
    assert.has_error(function()
      logger.destination = "stdout"
    end, "logging configuration is immutable")
  end)

  it("returns structured errors for invalid programmatic values", function()
    local invalid_values = {
      { levels = { command = "verbose" } },
      { levels = { unknown = "debug" } },
      { destination = "file" },
      { max_document_length = -1 },
      { sink = true },
      { unknown = true },
    }

    for _, options in ipairs(invalid_values) do
      local logger, err = logging.new(fake_runtime.new(), options)

      assert.is_nil(logger)
      assert.is_true(errors.is(err, errors.CATEGORY.CONFIGURATION))
    end
  end)
end)

describe("structured log event rendering", function()
  it("preserves exact fields and renders declared documents as relaxed Extended JSON", function()
    local observed = {}
    local source = {
      command = bson.document({
        { "integer", bson.int64(1) },
        { "date", bson.datetime(0) },
      }),
      commandName = "find",
      message = "Command started",
      operationId = nil,
    }
    local logger = assert(logging.new(fake_runtime.new(), {
      levels = { command = "debug" },
      sink = function(event)
        observed[#observed + 1] = event
      end,
    }))

    assert.is_true(logger:emit("command", "debug", source, {
      document_fields = { command = false },
    }))

    local event = observed[1]

    assert.are.equal("command", event.component)
    assert.are.equal("debug", event.level)
    assert.are.equal("Command started", event.data.message)
    assert.are.equal("find", event.data.commandName)
    assert.are.equal(
      '{"integer":1,"date":{"$date":"1970-01-01T00:00:00.000Z"}}',
      event.data.command
    )
    assert.is_nil(event.data.operationId)
    assert.is_true(bson.is_document(source.command))
    assert.are.same({ "component", "data", "level" }, (function()
      local keys = {}

      for key in pairs(event) do
        keys[#keys + 1] = key
      end

      table.sort(keys)
      return keys
    end)())
    assert.are.same({ "command", "commandName", "message" }, (function()
      local keys = {}

      for key in pairs(event.data) do
        keys[#keys + 1] = key
      end

      table.sort(keys)
      return keys
    end)())
    assert.has_error(function()
      event.level = "trace"
    end, "structured log events are immutable")
    assert.has_error(function()
      event.data.message = "changed"
    end, "structured log events are immutable")
  end)

  it("redacts documents before rendering and truncates at Unicode boundaries", function()
    local observed = {}
    local logger = assert(logging.new(fake_runtime.new(), {
      levels = { command = "debug" },
      max_document_length = 11,
      sink = function(event)
        observed[#observed + 1] = event
      end,
    }))
    assert.is_true(logger:emit("command", "debug", {
      command = bson.document({ { "secret", function() end } }),
      message = "Command started",
    }, {
      document_fields = { command = true },
    }))
    assert.are.equal("{}", observed[1].data.command)

    assert.is_true(logger:emit("command", "debug", {
      command = bson.document({ { "text", "ééé" } }),
      message = "Command started",
    }, {
      document_fields = { command = false },
    }))
    assert.are.equal('{"text":"éé...', observed[2].data.command)
    assert.are.equal(14, utf8.len('{"text":"ééé"}'))
    assert.are.equal(14, utf8.len(observed[2].data.command))

    logger = assert(logging.new(fake_runtime.new(), {
      levels = { command = "debug" },
      max_document_length = 0,
      sink = function(event)
        observed[#observed + 1] = event
      end,
    }))
    assert.is_true(logger:emit("command", "debug", {
      command = bson.document({ { "text", "value" } }),
    }, {
      document_fields = { command = false },
    }))
    assert.are.equal("...", observed[3].data.command)
  end)

  it("skips rendering when the component level is disabled", function()
    local sink_calls = 0
    local logger = assert(logging.new(fake_runtime.new(), {
      sink = function()
        sink_calls = sink_calls + 1
      end,
    }))

    assert.is_false(logger:emit("command", "debug", {
      command = bson.document({ { "invalid", function() end } }),
    }, {
      document_fields = { command = false },
    }))
    assert.are.equal(0, sink_calls)
  end)

  it("isolates rendering and sink failures from the caller", function()
    local logger = assert(logging.new(fake_runtime.new(), {
      levels = { command = "debug" },
      sink = function()
        error("sink failed")
      end,
    }))

    assert.is_false(logger:emit("command", "debug", { message = "Command started" }))

    local sink_calls = 0
    logger = assert(logging.new(fake_runtime.new(), {
      levels = { command = "debug" },
      sink = function()
        sink_calls = sink_calls + 1
      end,
    }))

    assert.is_false(logger:emit("command", "debug", {
      command = bson.document({ { "invalid", function() end } }),
    }, {
      document_fields = { command = false },
    }))

    local invalid_events = {
      { fields = nil },
      { fields = {}, options = "invalid" },
      { fields = {}, options = { unknown = true } },
      { fields = {}, options = { document_fields = "invalid" } },
      { fields = { [1] = "value" } },
      {
        fields = { command = bson.document({}) },
        options = { document_fields = { command = "invalid" } },
      },
      {
        fields = { command = "not a document" },
        options = { document_fields = { command = false } },
      },
      {
        fields = {},
        options = { document_fields = { [1] = false } },
      },
    }

    for _, invalid in ipairs(invalid_events) do
      assert.is_false(logger:emit("command", "debug", invalid.fields, invalid.options))
    end
    assert.are.equal(0, sink_calls)
  end)

  it("writes a deterministic structured envelope through the runtime", function()
    local runtime = fake_runtime.new()
    local logger = assert(logging.new(runtime, {
      destination = "stdout",
      levels = { topology = "info" },
    }))

    assert.is_true(logger:emit("topology", "info", {
      message = "Topology monitoring started",
      topologyId = "topology-1",
    }))
    assert.are.same({
      {
        destination = "stdout",
        value = '{"component":"topology","level":"info","data":'
          .. '{"message":"Topology monitoring started","topologyId":"topology-1"}}',
      },
    }, runtime.calls.output)

    runtime.output.write = function()
      error("output failed")
    end
    assert.is_false(logger:emit("topology", "info", {
      message = "Topology description changed",
    }))
  end)
end)
