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
