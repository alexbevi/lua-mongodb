local bson = require("mongodb.bson")
local copas = require("copas")
local errors = require("mongodb.error")
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

describe("public standalone client API", function()
  it("connects, runs ping on the URI database, and closes predictably", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      assert.are.equal("ismaster", handshake.body:keys()[1])
      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local ping = receive_frame(peer)

      assert.are.equal("ping", ping.body:keys()[1])
      assert.are.equal("app", ping.body:get("$db"))
      send_response(peer, ping, bson.document({ { "ok", 1 } }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          { runtime = mongodb.runtime.copas() }
        ))
        local database = assert(client:database())
        local reply = assert(database:run_command("ping"))

        assert.are.equal(1, reply:get("ok"):to_number())
        assert.is_true(client:close())
        assert.is_false(client:close())

        local closed_reply, closed_err = database:run_command("ping")

        assert.is_nil(closed_reply)
        assert.is_true(errors.is(closed_err, errors.CATEGORY.CLIENT))
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
