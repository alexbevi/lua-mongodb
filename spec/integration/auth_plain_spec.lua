local bson = require("mongodb.bson")
local copas = require("copas")
local mongodb = require("mongodb")
local op_msg = require("mongodb.wire.op_msg")
local socket = require("socket")

local function receive_frame(client)
  local header = assert(client:receive(4))
  local size = string.unpack("<i4", header)
  return assert(op_msg.decode(header .. assert(client:receive(size - 4)), {
    direction = "request",
  }))
end

local function send_response(client, request, body)
  assert(client:send(assert(op_msg.encode({
    body = body,
    direction = "response",
    request_id = 900 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("PLAIN standalone authentication", function()
  it("authenticates once and executes a command", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    port = assert(math.tointeger(port))
    local outcome

    copas.addserver(server, function(client)
      client = copas.wrap(client)
      local handshake = receive_frame(client)

      assert.is_nil(handshake.body:get("saslSupportedMechs"))
      send_response(client, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local start = receive_frame(client)

      assert.are.equal("saslStart", start.body:keys()[1])
      assert.are.equal("PLAIN", start.body:get("mechanism"))
      assert.are.equal("\0user\0pencil", start.body:get("payload").data)
      assert.are.equal(1, start.body:get("autoAuthorize"):to_number())
      assert.are.equal("directory", start.body:get("$db"))
      send_response(client, start, bson.document({
        { "conversationId", 1 },
        { "payload", bson.binary("") },
        { "done", true },
        { "ok", 1 },
      }))

      local ping = receive_frame(client)

      assert.are.equal("ping", ping.body:keys()[1])
      send_response(client, ping, bson.document({ { "ok", 1 } }))
      client:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://user:pencil@127.0.0.1:" .. port
            .. "/directory?authMechanism=PLAIN"
        ))

        assert(client:database():run_command("ping"))
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    assert.is_table(outcome)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
