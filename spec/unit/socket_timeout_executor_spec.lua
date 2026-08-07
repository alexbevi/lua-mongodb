local bson = require("mongodb.bson")
local socket_timeout_executor = require("mongodb.socket_timeout_executor")

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
end)
