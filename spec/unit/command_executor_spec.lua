local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local executor = require("mongodb.command.executor")
local op_msg = require("mongodb.wire.op_msg")

local function fake_connection(responses)
  local connection = {
    closed = false,
    requests = {},
    responses = responses,
  }

  function connection:write_all(bytes)
    self.requests[#self.requests + 1] = assert(op_msg.decode(bytes, { direction = "request" }))
    return true
  end

  function connection:read_frame()
    local request = self.requests[#self.requests]
    local body = table.remove(self.responses, 1)

    return assert(op_msg.encode({
      body = body,
      direction = "response",
      request_id = 900 + #self.requests,
      response_to = request.request_id,
    }))
  end

  function connection:close()
    self.closed = true
    return true
  end

  return connection
end

describe("single-connection command executor", function()
  it("negotiates hello metadata and sends a cloned command envelope", function()
    local connection = fake_connection({
      bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
        { "maxBsonObjectSize", 1024 },
        { "maxMessageSizeBytes", 4096 },
        { "maxWriteBatchSize", 100 },
        { "logicalSessionTimeoutMinutes", 30 },
      }),
      bson.document({ { "ok", 1 }, { "helloOk", true }, { "maxWireVersion", 25 } }),
      bson.document({ { "ok", 1 }, { "value", "pong" } }),
    })
    local commands = assert(executor.new(connection, {
      app_name = "command-spec",
      driver_version = "0.1.0-test",
      os_type = "test-os",
      platform = string.rep("p", 1000),
    }))
    local hello = assert(commands:hello())
    local handshake = connection.requests[1].body

    assert.are.same({ "ismaster", "helloOk", "backpressure", "client", "$db" }, handshake:keys())
    assert.are.equal("2", handshake:get("backpressure"))
    assert.are.equal("command-spec", handshake:get("client"):get("application"):get("name"))
    assert.are.equal("lua-mongodb", handshake:get("client"):get("driver"):get("name"))
    assert.are.equal("0.1.0-test", handshake:get("client"):get("driver"):get("version"))
    assert.are.equal("test-os", handshake:get("client"):get("os"):get("type"))
    assert.is_true(#assert(bson.encode(handshake:get("client"))) <= 512)
    assert.is_true(hello.hello_ok)
    assert.is_true(hello.is_writable)
    assert.are.equal(25, hello.max_wire_version)
    assert.are.equal(30, hello.logical_session_timeout_minutes)

    assert(commands:hello())
    assert.are.same({ "hello", "backpressure", "$db" }, connection.requests[2].body:keys())

    local command = bson.document({ { "ping", 1 }, { "comment", "unchanged" } })
    local response = assert(commands:command("admin", command))
    local sent = connection.requests[3].body

    assert.are.equal("pong", response:get("value"))
    assert.are.same({ "ping", "comment" }, command:keys())
    assert.are.same({ "ping", "comment", "$db" }, sent:keys())
    assert.are.equal("admin", sent:get("$db"))
  end)

  it("uses modern hello and Stable API fields when configured", function()
    local connection = fake_connection({
      bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
      bson.document({ { "ok", 1 } }),
    })
    local commands = assert(executor.new(connection, {
      server_api = { deprecation_errors = false, strict = true, version = "1" },
    }))

    assert(commands:hello())
    assert.are.same(
      {
        "hello", "backpressure", "client", "apiVersion",
        "apiStrict", "apiDeprecationErrors", "$db",
      },
      connection.requests[1].body:keys()
    )

    assert(commands:command("db", bson.document({ { "ping", 1 } })))
    local sent = connection.requests[2].body

    assert.are.same(
      { "ping", "apiVersion", "apiStrict", "apiDeprecationErrors", "$db" },
      sent:keys()
    )
    assert.is_true(sent:get("apiStrict"))
    assert.is_false(sent:get("apiDeprecationErrors"))
  end)

  it("returns server codes, names, labels, and response details", function()
    local connection = fake_connection({
      bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
      bson.document({
        { "ok", 0 },
        { "errmsg", "stepdown" },
        { "code", 91 },
        { "codeName", "ShutdownInProgress" },
        { "errorLabels", bson.array({ "RetryableWriteError", "NoWritesPerformed" }) },
      }),
    })
    local commands = assert(executor.new(connection, { server = "db.example:27017" }))

    assert(commands:hello())
    local response, err = commands:command("admin", bson.document({ { "ping", 1 } }))

    assert.is_nil(response)
    assert.is_true(errors.is(err, errors.CATEGORY.SERVER))
    assert.are.equal(91, err.code)
    assert.are.equal("ShutdownInProgress", err.code_name)
    assert.are.equal("db.example:27017", err.server)
    assert.is_true(err:has_label("RetryableWriteError"))
    assert.is_true(err:has_label("NoWritesPerformed"))
    assert.are.equal("stepdown", err.details.response:get("errmsg"))
  end)

  it("closes after a malformed response", function()
    local connection = fake_connection({
      bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
      bson.document({ { "value", 1 } }),
    })
    local commands = assert(executor.new(connection))

    assert(commands:hello())
    local response, err = commands:command("admin", bson.document({ { "ping", 1 } }))

    assert.is_nil(response)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
    assert.is_true(connection.closed)
  end)
end)
