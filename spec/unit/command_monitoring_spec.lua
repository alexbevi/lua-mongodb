local bson = require("mongodb.bson")
local command_executor = require("mongodb.command.executor")
local command_security = require("mongodb.command.security")
local errors = require("mongodb.error")
local fake_runtime = require("mongodb.runtime.fake")
local logging = require("mongodb.logging")
local monitoring = require("mongodb.monitoring")
local op_msg = require("mongodb.wire.op_msg")

local FIXTURE_ROOT = (os.getenv("PWD") or ".")
  .. "/planning/specifications/source/"

local function read_fixture(relative)
  local file = assert(io.open(FIXTURE_ROOT .. relative, "rb"))
  local content = file:read("*a")

  file:close()
  return assert(bson.json.decode(content))
end

local function fake_connection(responses)
  local connection = { requests = {}, responses = responses }

  function connection:write_all(bytes)
    self.requests[#self.requests + 1] = assert(op_msg.decode(bytes, { direction = "request" }))
    return true
  end

  function connection:read_frame()
    local request = self.requests[#self.requests]
    return assert(op_msg.encode({
      body = table.remove(self.responses, 1),
      direction = "response",
      request_id = 500 + #self.requests,
      response_to = request.request_id,
    }))
  end

  function connection.close()
    return true
  end

  return connection
end

local function clock(values)
  return {
    now = function()
      return table.remove(values, 1)
    end,
  }
end

describe("command monitoring", function()
  it("suppresses handshake and heartbeat hello traffic from command logs", function()
    local observed = {}
    local logger = assert(logging.new(fake_runtime.new(), {
      levels = { command = "debug" },
      sink = function(event)
        observed[#observed + 1] = event
      end,
    }))
    local events = monitoring.new({
      clock = clock({ 10, 10.25, 20, 20.5, 30, 30.75 }),
      logger = logger,
      listeners = {},
    })
    local connection = fake_connection({
      bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
      bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
      bson.document({ { "ok", 1 }, { "value", 42 } }),
      bson.document({ { "ok", 0 }, { "errmsg", "bad filter" }, { "code", 2 } }),
    })
    local commands = command_executor.new(connection, {
      driver_connection_id = 17,
      monitoring = events,
      server = "db.example:27018",
      server_host = "db.example",
      server_port = 27018,
    })

    assert(commands:hello())
    assert(commands:hello())
    assert(commands:command("app", bson.document({ { "ping", 1 } })))
    local response, err = commands:command(
      "app",
      bson.document({ { "find", "items" } })
    )

    assert.is_nil(response)
    assert.is_true(errors.is(err, errors.CATEGORY.SERVER))
    assert(commands:command("app", bson.document({ { "insert", "items" } }), {
      no_response = true,
    }))
    assert.are.same({
      "Command started",
      "Command succeeded",
      "Command started",
      "Command failed",
      "Command started",
      "Command succeeded",
    }, (function()
      local messages = {}

      for index, event in ipairs(observed) do
        messages[index] = event.data.message
      end

      return messages
    end)())
    assert.are.equal(observed[1].data.requestId, observed[2].data.requestId)
    assert.are.equal(observed[3].data.requestId, observed[4].data.requestId)
    assert.are.equal(observed[5].data.requestId, observed[6].data.requestId)
    assert.are.equal("command", observed[1].component)
    assert.are.equal("debug", observed[1].level)

    for _, event in ipairs(observed) do
      assert.are.equal(17, event.data.driverConnectionId)
    end

    assert.are.equal("app", observed[1].data.databaseName)
    assert.are.equal("ping", observed[1].data.commandName)
    assert.are.equal('{"ping":1,"$db":"app"}', observed[1].data.command)
    assert.are.equal(250, observed[2].data.durationMS)
    assert.are.equal('{"ok":1,"value":42}', observed[2].data.reply)
    assert.are.equal("find", observed[4].data.commandName)
    assert.are.equal(500, observed[4].data.durationMS)
    assert.matches("bad filter", observed[4].data.failure, 1, true)
    assert.are.equal("db.example", observed[4].data.serverHost)
    assert.are.equal(27018, observed[4].data.serverPort)
    assert.are.equal("insert", observed[6].data.commandName)
    assert.are.equal(750, observed[6].data.durationMS)
    assert.are.equal('{"ok":1}', observed[6].data.reply)
  end)

  it("runs the exact load-balanced serviceId event cases", function()
    local fixture = read_fixture("load-balancers/tests/event-monitoring.json")
    local service_id = bson.object_id("000000000000000000000001")
    local observed = {}
    local events = monitoring.new({
      clock = clock({ 1, 2, 3, 4 }),
      listeners = {
        {
          started = function(_, event)
            observed[#observed + 1] = event
          end,
          succeeded = function(_, event)
            observed[#observed + 1] = event
          end,
          failed = function(_, event)
            observed[#observed + 1] = event
          end,
        },
      },
    })
    local connection = fake_connection({
      bson.document({
        { "ok", 1 },
        { "maxWireVersion", 25 },
        { "serviceId", service_id },
      }),
      bson.document({ { "ok", 1 } }),
      bson.document({ { "ok", 0 }, { "errmsg", "bad filter" }, { "code", 2 } }),
    })
    local commands = command_executor.new(connection, {
      load_balanced = true,
      monitoring = events,
    })

    assert(commands:hello())
    assert(commands:command("database0", bson.document({ { "insert", "coll0" } })))
    local response, err = commands:command(
      "database0",
      bson.document({ { "find", "coll0" } })
    )

    assert.is_nil(response)
    assert.is_true(errors.is(err, errors.CATEGORY.SERVER))
    assert.are.same({
      "command started and succeeded events include serviceId",
      "command failed events include serviceId",
      "poolClearedEvent events include serviceId",
    }, {
      fixture:get("tests"):get(1):get("description"),
      fixture:get("tests"):get(2):get("description"),
      fixture:get("tests"):get(3):get("description"),
    })
    assert.are.same({
      "command_started",
      "command_succeeded",
      "command_started",
      "command_failed",
    }, {
      observed[1].type,
      observed[2].type,
      observed[3].type,
      observed[4].type,
    })

    for _, event in ipairs(observed) do
      assert.are.equal(service_id, event.service_id)
    end

    local expected_pool_event = fixture:get("tests"):get(3)
      :get("expectEvents"):get(2):get("events"):get(1)
      :get("poolClearedEvent")

    assert.is_true(expected_pool_event:get("hasServiceId"))
  end)

  it("keeps security helpers closed for invalid command values", function()
    assert.is_false(command_security.is_sensitive(nil, bson.document({})))
    assert.are.equal(0, #command_security.redact_server_response("invalid"))
  end)

  it("keeps monitor and span state immutable", function()
    local events = monitoring.new({
      clock = clock({ 1 }),
      listeners = {},
    })

    assert.has_error(function()
      events.listeners = {}
    end, "command monitors are immutable")

    local span = events:start({
      command = bson.document({ { "ping", 1 } }),
      database_name = "admin",
      request_id = 1,
    })

    assert.has_error(function()
      span.finished = true
    end, "command monitor spans are immutable")
  end)

  it("publishes correlated ordered outcomes and isolates listeners", function()
    local observed = {}
    local listener_errors = {}
    local noisy = {
      started = function(_, event)
        assert.has_error(function()
          event.request_id = 0
        end, "command monitoring events are immutable")
        error("listener exploded")
      end,
    }
    local recorder = {
      started = function(_, event)
        observed[#observed + 1] = event
      end,
      succeeded = function(_, event)
        observed[#observed + 1] = event
      end,
      failed = function(_, event)
        observed[#observed + 1] = event
      end,
    }
    local events = monitoring.new({
      clock = clock({ 10, 10.25, 20, 20.5 }),
      listeners = { noisy, recorder },
      on_listener_error = function(err)
        listener_errors[#listener_errors + 1] = err
      end,
    })
    local connection = fake_connection({
      bson.document({ { "ok", 1 }, { "connectionId", 99 }, { "maxWireVersion", 25 } }),
      bson.document({ { "ok", 1 } }),
      bson.document({ { "ok", 0 }, { "errmsg", "bad command" }, { "code", 2 } }),
    })
    local commands = command_executor.new(connection, {
      monitoring = events,
      server = "db.example:27017",
    })

    assert(commands:hello())
    assert(commands:command("app", bson.document({ { "insert", "items" } }), {
      operation_id = 700,
      sequences = {
        {
          documents = { bson.document({ { "name", "Ada" } }) },
          identifier = "documents",
        },
      },
    }))
    local response, err = commands:command("app", bson.document({ { "bad", 1 } }))

    assert.is_nil(response)
    assert.is_true(errors.is(err, errors.CATEGORY.SERVER))
    assert.are.equal(2, #listener_errors)
    assert.are.same(
      { "command_started", "command_succeeded", "command_started", "command_failed" },
      { observed[1].type, observed[2].type, observed[3].type, observed[4].type }
    )
    assert.are.equal(observed[1].request_id, observed[2].request_id)
    assert.are.equal(observed[3].request_id, observed[4].request_id)
    assert.are.equal(700, observed[1].operation_id)
    assert.are.equal(250, observed[2].duration_ms)
    assert.are.equal(500, observed[4].duration_ms)
    assert.are.equal("db.example:27017", observed[1].connection_id)
    assert.are.equal(99, observed[1].server_connection_id)
    assert.is_nil(observed[1].service_id)
    assert.is_nil(observed[2].service_id)
    assert.is_nil(observed[3].service_id)
    assert.is_nil(observed[4].service_id)
    assert.are.equal("app", observed[1].database_name)
    assert.are.equal("insert", observed[1].command_name)
    assert.are.equal("Ada", observed[1].command:get("documents"):get(1):get("name"))
    assert.are.equal("bad command", observed[4].failure.message)
  end)

  it("redacts credentials, auth replies, and sensitive server failures", function()
    local observed = {}
    local events = monitoring.new({
      clock = clock({ 1, 2, 3, 4 }),
      listeners = {
        {
          started = function(_, event)
            observed[#observed + 1] = event
          end,
          succeeded = function(_, event)
            observed[#observed + 1] = event
          end,
          failed = function(_, event)
            observed[#observed + 1] = event
          end,
        },
      },
    })
    local connection = fake_connection({
      bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
      bson.document({ { "ok", 1 }, { "payload", "server-secret" } }),
      bson.document({
        { "ok", 0 },
        { "errmsg", "credential leaked" },
        { "code", 18 },
        { "codeName", "AuthenticationFailed" },
        { "errorLabels", bson.array({ "HandshakeError" }) },
      }),
    })
    local commands = command_executor.new(connection, { monitoring = events })

    assert(commands:hello())
    assert(commands:command("admin", bson.document({
      { "saslStart", 1 },
      { "payload", bson.binary("client-secret") },
    })))
    local response = commands:command("admin", bson.document({
      { "authenticate", 1 },
      { "user", "private" },
    }))

    assert.is_nil(response)
    assert.are.equal(0, #observed[1].command)
    assert.are.equal(0, #observed[2].reply)
    assert.are.equal(0, #observed[3].command)
    assert.are.same({ "code", "codeName", "errorLabels" }, observed[4].failure:keys())
    assert.is_nil(observed[4].failure:get("errmsg"))
  end)

  it("keeps protected values out of sensitive command diagnostics", function()
    local client_secret = "audit-client-secret-71f44"
    local server_secret = "audit-server-secret-9c285"
    local observed = {}
    local events = monitoring.new({
      clock = clock({ 1, 2 }),
      listeners = {
        {
          started = function(_, event)
            observed[#observed + 1] = event
          end,
          failed = function(_, event)
            observed[#observed + 1] = event
          end,
        },
      },
    })
    local connection = fake_connection({
      bson.document({ { "ok", 1 }, { "maxWireVersion", 25 } }),
      bson.document({
        { "ok", 0 },
        { "errmsg", "authentication rejected " .. server_secret },
        { "code", 18 },
        { "codeName", "AuthenticationFailed" },
        { "errorLabels", bson.array({ "HandshakeError" }) },
        { "payload", server_secret },
      }),
    })
    local commands = command_executor.new(connection, { monitoring = events })

    assert(commands:hello())
    local reply, err = commands:command("admin", bson.document({
      { "saslStart", 1 },
      { "payload", bson.binary(client_secret) },
    }))

    assert.is_nil(reply)
    assert.is_true(errors.is(err, errors.CATEGORY.SERVER))
    assert.are.equal("sensitive command failed", err.message)
    assert.is_nil(tostring(err):find(client_secret, 1, true))
    assert.is_nil(tostring(err):find(server_secret, 1, true))
    assert.are.same(
      { "code", "codeName", "errorLabels" },
      err.details.response:keys()
    )
    assert.are.equal(0, #observed[1].command)
    assert.are.same(
      { "code", "codeName", "errorLabels" },
      observed[2].failure:keys()
    )
  end)

  it("redacts the complete normative sensitive-command list", function()
    local observed = {}
    local current_time = 0
    local events = monitoring.new({
      clock = {
        now = function()
          current_time = current_time + 0.001
          return current_time
        end,
      },
      listeners = {
        {
          started = function(_, event)
            observed[#observed + 1] = event
          end,
          succeeded = function(_, event)
            observed[#observed + 1] = event
          end,
          failed = function(_, event)
            observed[#observed + 1] = event
          end,
        },
      },
    })
    local commands = {
      "authenticate",
      "saslStart",
      "saslContinue",
      "getnonce",
      "createUser",
      "updateUser",
      "copydbgetnonce",
      "copydbsaslstart",
      "copydb",
    }

    for index, name in ipairs(commands) do
      local span = events:start({
        command = bson.document({ { name, 1 }, { "secret", "client-secret" } }),
        connection_id = "localhost:27017",
        database_name = "admin",
        request_id = index,
      })

      span:succeeded(bson.document({ { "ok", 1 }, { "secret", "server-secret" } }))
      assert.are.equal(0, #observed[#observed - 1].command)
      assert.are.equal(0, #observed[#observed].reply)
    end

    for index, name in ipairs({ "hello", "ismaster", "isMaster" }) do
      local span = events:start({
        command = bson.document({
          { name, 1 },
          { "speculativeAuthenticate", bson.document({ { "payload", "secret" } }) },
        }),
        database_name = "admin",
        request_id = 100 + index,
      })

      span:succeeded(bson.document({ { "ok", 1 }, { "payload", "secret" } }))
      assert.are.equal(0, #observed[#observed - 1].command)
      assert.are.equal(0, #observed[#observed].reply)
    end

    local network_failure = errors.new({
      category = errors.CATEGORY.NETWORK,
      message = "socket closed",
    })
    local span = events:start({
      command = bson.document({ { "saslStart", 1 }, { "payload", "secret" } }),
      database_name = "admin",
      request_id = 200,
    })

    span:failed(network_failure)
    assert.are.equal(0, #observed[#observed - 1].command)
    assert.are.equal(network_failure, observed[#observed].failure)
  end)
end)
