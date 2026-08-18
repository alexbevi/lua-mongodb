local bson = require("mongodb.bson")
local errors = require("mongodb.error")
local executor = require("mongodb.command.executor")
local handshake_metadata = require("mongodb.handshake.metadata")
local monitoring = require("mongodb.monitoring")
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
    local scripted = table.remove(self.responses, 1)
    local body = scripted.body or scripted

    return assert(op_msg.encode({
      body = body,
      direction = "response",
      flags = scripted.flags,
      request_id = scripted.request_id or 900 + #self.requests,
      response_to = scripted.response_to or request.request_id,
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
      {
        body = bson.document({
          { "ok", 1 }, { "helloOk", true }, { "maxWireVersion", 25 },
        }),
        flags = op_msg.FLAG.MORE_TO_COME,
        request_id = 902,
      },
      {
        body = bson.document({
          { "ok", 1 }, { "helloOk", true }, { "maxWireVersion", 25 },
        }),
        request_id = 903,
        response_to = 902,
      },
      bson.document({ { "ok", 1 }, { "value", "pong" } }),
    })
    local commands = assert(executor.new(connection, {
      metadata = handshake_metadata.new({
        app_name = "command-spec",
        os = { type = "test-os" },
        platform = string.rep("p", 1000),
      }),
    }))
    local hello = assert(commands:hello())
    local handshake = connection.requests[1].body

    assert.are.same({ "ismaster", "helloOk", "backpressure", "client", "$db" }, handshake:keys())
    assert.are.equal("2", handshake:get("backpressure"))
    assert.are.equal("command-spec", handshake:get("client"):get("application"):get("name"))
    assert.are.equal("lua-mongodb", handshake:get("client"):get("driver"):get("name"))
    assert.are.equal("0.5.0", handshake:get("client"):get("driver"):get("version"))
    assert.are.equal("test-os", handshake:get("client"):get("os"):get("type"))
    assert.is_true(#assert(bson.encode(handshake:get("client"))) <= 512)
    assert.is_true(hello.hello_ok)
    assert.is_true(hello.is_writable)
    assert.are.equal(25, hello.max_wire_version)
    assert.are.equal(30, hello.logical_session_timeout_minutes)

    local process_id = assert(bson.object_id("000000000000000000000001"))
    local topology_version = bson.document({
      { "processId", process_id },
      { "counter", bson.int64(1) },
    })

    assert(commands:hello({
      max_await_time_ms = 10000,
      topology_version = topology_version,
    }))
    assert.are.same(
      { "hello", "backpressure", "topologyVersion", "maxAwaitTimeMS", "$db" },
      connection.requests[2].body:keys()
    )
    assert.are.equal(
      assert(bson.encode(topology_version)),
      assert(bson.encode(connection.requests[2].body:get("topologyVersion")))
    )
    assert.are.equal(
      10000,
      connection.requests[2].body:get("maxAwaitTimeMS"):to_number()
    )
    assert.is_true(
      connection.requests[2].flags & op_msg.FLAG.EXHAUST_ALLOWED ~= 0
    )

    assert(commands:hello({
      max_await_time_ms = 10000,
      topology_version = topology_version,
    }))
    assert.are.equal(2, #connection.requests)

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

  it("validates awaitable hello arguments before writing", function()
    local connection = fake_connection({
      bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
    })
    local commands = assert(executor.new(connection))
    local topology_version = bson.document({
      { "processId", bson.object_id("000000000000000000000001") },
      { "counter", bson.int64(1) },
    })

    assert(commands:hello())
    assert.has_error(function()
      commands:hello("invalid")
    end, "hello options must be a table")
    assert.has_error(function()
      commands:hello({ unsupported = true })
    end, "unknown hello option: unsupported")
    assert.has_error(function()
      commands:hello({
        max_await_time_ms = -1,
        topology_version = topology_version,
      })
    end, "max_await_time_ms must be a non-negative integer")
    assert.has_error(function()
      commands:hello({
        max_await_time_ms = 1,
        topology_version = "invalid",
      })
    end, "topology_version must be a BSON document")
    assert.has_error(function()
      commands:hello({ max_await_time_ms = 1 })
    end, "awaitable hello requires topology_version and max_await_time_ms")
    assert.are.equal(1, #connection.requests)
  end)

  it("rejects commands while a streamed hello response is pending", function()
    local topology_version = bson.document({
      { "processId", bson.object_id("000000000000000000000001") },
      { "counter", bson.int64(1) },
    })
    local connection = fake_connection({
      bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
      {
        body = bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
        flags = op_msg.FLAG.MORE_TO_COME,
      },
    })
    local commands = assert(executor.new(connection))

    assert(commands:hello())
    assert(commands:hello({
      max_await_time_ms = 10000,
      topology_version = topology_version,
    }))
    assert.has_error(function()
      commands:command("admin", bson.document({ { "ping", 1 } }))
    end, "cannot send a command while an exhaust response is pending")
    assert.are.equal(2, #connection.requests)
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

  it("sends unacknowledged commands with moreToCome without reading a reply", function()
    local connection = fake_connection({
      bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
    })
    local commands = assert(executor.new(connection))

    assert(commands:hello())
    assert(commands:command("app", bson.document({ { "insert", "users" } }), {
      no_response = true,
    }))
    assert.is_true(connection.requests[2].more_to_come)
    assert.are.equal(0, #connection.responses)
  end)

  it("rejects an unexpected streamed reply for an ordinary command", function()
    local failed_event
    local events = monitoring.new({
      clock = { now = function() return 0 end },
      listeners = {
        {
          failed = function(_, event)
            failed_event = event
          end,
        },
      },
    })
    local connection = fake_connection({
      bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
      {
        body = bson.document({ { "ok", 1 } }),
        flags = op_msg.FLAG.MORE_TO_COME,
      },
    })
    local commands = assert(executor.new(connection, { monitoring = events }))

    assert(commands:hello())
    local response, err = commands:command(
      "admin",
      bson.document({ { "ping", 1 } })
    )

    assert.is_nil(response)
    assert.is_true(errors.is(err, errors.CATEGORY.PROTOCOL))
    assert.is_true(connection.closed)
    assert.are.equal("command_failed", failed_event.type)
    assert.are.equal(err, failed_event.failure)
  end)
end)
