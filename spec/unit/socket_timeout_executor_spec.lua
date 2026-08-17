local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local retry_executor = require("mongodb.retry_executor")
local fake_runtime = require("mongodb.runtime.fake")
local socket_timeout_executor = require("mongodb.socket_timeout_executor")
local operation_timeout = require("mongodb.operation_timeout")

local function assert_refreshed_retry_deadline(retry_options, command_options)
  local runtime = fake_runtime.new({ now = 10 })
  local deadlines = {}
  local underlying = {
    close = function() return true end,
    command = function(_, _, _, options)
      deadlines[#deadlines + 1] = options.socket_deadline

      if #deadlines == 1 then
        runtime:advance(0.2)
        return nil, errors.new({
          category = errors.CATEGORY.TIMEOUT,
          message = "operation deadline expired",
        })
      end

      return bson.document({ { "ok", 1 } })
    end,
  }
  local timed = socket_timeout_executor.new(underlying, runtime, 250)
  local executor = retry_executor.new(timed, retry_options)
  local response = assert(executor:command(
    "db",
    bson.document({ { "find", "items" } }),
    command_options
  ))

  assert.are.equal(1, response:get("ok"))
  assert.near(10.25, deadlines[1], 0.000001)
  assert.near(10.45, deadlines[2], 0.000001)
end

describe("socket timeout executor", function()
  it("limits connection I/O without replacing the operation deadline", function()
    local received
    local underlying = {}

    function underlying.command(_, _, _, options)
      received = options
      return bson.document({ { "ok", 1 } })
    end

    function underlying.close()
      return true
    end

    local executor = socket_timeout_executor.new(underlying, {
      clock = { now = function() return 10 end },
    }, 250)
    local response = assert(executor:command(
      "db",
      bson.document({ { "ping", 1 } }),
      { deadline = 20 }
    ))

    assert.are.equal(1, response:get("ok"))
    assert.are.equal(20, received.deadline)
    assert.are.equal(10.25, received.socket_deadline)
  end)

  it("ignores the legacy socket timeout while CSOT is active", function()
    local received
    local runtime = { clock = { now = function() return 10 end } }
    local underlying = {
      close = function() return true end,
      command = function(_, _, _, options)
        received = options
        return bson.document({ { "ok", 1 } })
      end,
    }
    local executor = socket_timeout_executor.new(underlying, runtime, 1)

    operation_timeout.run(runtime, 250, {}, function(options)
      assert(executor:command("db", bson.document({ { "ping", 1 } }), options))
    end)

    assert.near(10.25, received.deadline, 0.000001)
    assert.is_nil(received.socket_deadline)
  end)

  it("refreshes the legacy socket deadline for a read retry", function()
    assert_refreshed_retry_deadline({}, { retryable_read = true })
  end)

  it("refreshes the legacy socket deadline for a write retry", function()
    assert_refreshed_retry_deadline(
      { enabled_writes = true },
      { retryable_write = true }
    )
  end)

  it("delegates capability discovery to the underlying executor", function()
    local capabilities = { max_wire_version = 25 }
    local executor = socket_timeout_executor.new({
      capabilities = function() return capabilities end,
      close = function() return true end,
      command = function() return bson.document({ { "ok", 1 } }) end,
    }, fake_runtime.new(), 250)

    assert.are.equal(capabilities, executor:capabilities())
  end)
end)
