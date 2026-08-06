local bson = require("mongodb.bson")
local command_executor = require("mongodb.command.executor")
local copas = require("copas")
local op_msg = require("mongodb.wire.op_msg")
local runtime = require("mongodb.runtime")
local scram = require("mongodb.auth.scram")
local socket = require("socket")
local transport = require("mongodb.network.transport")

local ENTROPY = string.pack(
  ">I4I4I4I4I4I4I4I4",
  0x00010203,
  0x04050607,
  0x08090a0b,
  0x0c0d0e0f,
  0x10111213,
  0x14151617,
  0x18191a1b,
  0x1c1d1e1f
)
local NONCE = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

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
    request_id = 700 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("authenticated standalone command execution", function()
  it("authenticates with SCRAM-SHA-256 and pings over TCP", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    port = assert(math.tointeger(port))
    local outcome

    copas.addserver(server, function(client)
      client = copas.wrap(client)
      local handshake = receive_frame(client)

      send_response(client, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxWireVersion", 25 },
      }))

      local start = receive_frame(client)

      assert.are.equal("saslStart", start.body:keys()[1])
      assert.are.equal("SCRAM-SHA-256", start.body:get("mechanism"))
      assert.are.equal("n,,n=user,r=" .. NONCE, start.body:get("payload").data)
      send_response(client, start, bson.document({
        { "conversationId", 1 },
        { "payload", bson.binary(
          "r=" .. NONCE
            .. "server-suffix,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        ) },
        { "done", false },
        { "ok", 1 },
      }))

      local continue = receive_frame(client)

      assert.are.equal("saslContinue", continue.body:keys()[1])
      assert.are.equal(
        "c=biws,r=" .. NONCE
          .. "server-suffix,p=HZEmipSgzJfyX7B1oWa3JqRQhM7vHiB1kTo7N8H8UY8=",
        continue.body:get("payload").data
      )
      send_response(client, continue, bson.document({
        { "conversationId", 1 },
        { "payload", bson.binary("v=ULVJCzOWFs0L7wP6UkjMKgjZGBcBDyOfKFh3lKC0cXk=") },
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
        local adapter = runtime.copas({
          entropy = {
            bytes = function(_, count)
              assert.are.equal(32, count)
              return ENTROPY
            end,
          },
        })
        local deadline = runtime.deadline_after(adapter, 2)
        local connection = assert(transport.connect(adapter, "127.0.0.1", port, {
          deadline = deadline,
        }))
        local commands = command_executor.new(connection, {
          server = "127.0.0.1:" .. port,
        })

        assert(commands:hello({ deadline = deadline }))
        assert(scram.authenticate(commands, adapter, {
          mechanism = "SCRAM-SHA-256",
          password = "pencil",
          source = "admin",
          username = "user",
        }, { deadline = deadline }))
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
