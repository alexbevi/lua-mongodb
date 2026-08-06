local bson = require("mongodb.bson")
local command_executor = require("mongodb.command.executor")
local copas = require("copas")
local op_msg = require("mongodb.wire.op_msg")
local runtime = require("mongodb.runtime")
local socket = require("socket")
local transport = require("mongodb.network.transport")

local function receive_frame(client)
  local header = assert(client:receive(4))
  local size = string.unpack("<i4", header)
  return header .. assert(client:receive(size - 4))
end

local function send_response(client, request, body)
  local response = assert(op_msg.encode({
    body = body,
    direction = "response",
    request_id = 700 + request.request_id,
    response_to = request.request_id,
  }))

  assert(client:send(response))
end

describe("standalone command execution", function()
  it("handshakes and pings over the Copas TCP adapter", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    port = assert(math.tointeger(port))
    local outcome

    copas.addserver(server, function(client)
      client = copas.wrap(client)
      local handshake = assert(op_msg.decode(receive_frame(client), { direction = "request" }))

      assert.are.equal("ismaster", handshake.body:keys()[1])
      send_response(client, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local ping = assert(op_msg.decode(receive_frame(client), { direction = "request" }))

      assert.are.equal("ping", ping.body:keys()[1])
      assert.are.equal("admin", ping.body:get("$db"))
      send_response(client, ping, bson.document({ { "ok", 1 } }))
      client:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local adapter = runtime.copas()
        local deadline = runtime.deadline_after(adapter, 2)
        local connection = assert(transport.connect(adapter, "127.0.0.1", port, {
          deadline = deadline,
        }))
        local commands = command_executor.new(connection, {
          server = "127.0.0.1:" .. port,
        })

        assert(commands:hello({ deadline = deadline }))
        assert(commands:command("admin", bson.document({ { "ping", 1 } }), {
          deadline = deadline,
        }))
        assert.is_true(commands:close())
      end))
      copas.removeserver(server)
    end)

    assert.is_table(outcome)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
