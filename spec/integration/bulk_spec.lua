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
    request_id = 1600 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("collection bulk writes over OP_MSG", function()
  it("splits document sequences at the negotiated message size", function()
    local server = assert(socket.bind("127.0.0.1", 0))
    local _, port = assert(server:getsockname())
    local outcome

    port = assert(math.tointeger(port))
    copas.addserver(server, function(peer)
      peer = copas.wrap(peer)
      local handshake = receive_frame(peer)

      send_response(peer, handshake, bson.document({
        { "ok", 1 },
        { "helloOk", true },
        { "isWritablePrimary", true },
        { "maxBsonObjectSize", 1024 },
        { "maxMessageSizeBytes", 250 },
        { "maxWireVersion", 25 },
        { "maxWriteBatchSize", 100 },
      }))

      for identifier = 1, 2 do
        local insert = receive_frame(peer)

        assert.are.equal("insert", insert.body:keys()[1])
        assert.are.equal(1, #insert.sequences)
        assert.are.equal("documents", insert.sequences[1].identifier)
        assert.are.equal(1, #insert.sequences[1].documents)
        assert.are.equal(
          identifier,
          insert.sequences[1].documents[1]:get("_id"):to_number()
        )
        send_response(peer, insert, bson.document({ { "ok", 1 }, { "n", 1 } }))
      end
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          { runtime = mongodb.runtime.copas() }
        ))
        local collection = assert(client:database():collection("events"))
        local inserted = assert(collection:insert_many({
          bson.document({ { "_id", 1 }, { "payload", string.rep("a", 100) } }),
          bson.document({ { "_id", 2 }, { "payload", string.rep("b", 100) } }),
        }))

        assert.are.equal(2, #inserted.inserted_ids)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
