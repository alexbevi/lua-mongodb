local bson = require("mongodb.bson")
local socket_timeout_executor = require("mongodb.socket_timeout_executor")
local operation_timeout = require("mongodb.operation_timeout")

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
end)
