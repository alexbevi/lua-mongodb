local bson = require("mongodb.bson")
local executor = require("mongodb.command.executor")
local op_msg = require("mongodb.wire.op_msg")

local function fake_connection(response)
  local connection = { requests = {} }

  function connection:write_all(bytes)
    self.requests[#self.requests + 1] = assert(op_msg.decode(bytes, {
      direction = "request",
    }))
    return true
  end

  function connection:read_frame()
    return assert(op_msg.encode({
      body = response,
      direction = "response",
      request_id = 900,
      response_to = self.requests[#self.requests].request_id,
    }))
  end

  function connection.close()
    return true
  end

  return connection
end

describe("connection handshake", function()
  it("carries a speculative authentication document through hello", function()
    local speculative_command = bson.document({
      { "saslStart", 1 },
      { "mechanism", "MONGODB-OIDC" },
      { "payload", bson.binary("private-request") },
    })
    local speculative_response = bson.document({
      { "conversationId", 7 },
      { "payload", bson.binary("private-response") },
      { "done", true },
      { "ok", 1 },
    })
    local connection = fake_connection(bson.document({
      { "ok", 1 },
      { "helloOk", true },
      { "isWritablePrimary", true },
      { "maxWireVersion", 25 },
      { "speculativeAuthenticate", speculative_response },
    }))
    local commands = assert(executor.new(connection))
    local hello = assert(commands:hello({
      speculative_authenticate = speculative_command,
    }))
    local sent = connection.requests[1].body:get("speculativeAuthenticate")

    assert.are.equal(
      assert(bson.encode(speculative_command)),
      assert(bson.encode(sent))
    )
    assert.are.equal(
      assert(bson.encode(speculative_response)),
      assert(bson.encode(hello.document:get("speculativeAuthenticate")))
    )
  end)
end)
