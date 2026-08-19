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

  it("writes inserts for multiple namespaces in one client command", function()
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
        { "maxBsonObjectSize", 16777216 },
        { "maxMessageSizeBytes", 48000000 },
        { "maxWireVersion", 25 },
        { "maxWriteBatchSize", 100000 },
      }))

      local request = receive_frame(peer)

      assert.are.equal("bulkWrite", request.body:keys()[1])
      assert.are.equal("admin", request.body:get("$db"))
      assert.are.equal(2, #request.sequences)
      assert.are.equal("ops", request.sequences[1].identifier)
      assert.are.equal("nsInfo", request.sequences[2].identifier)
      assert.are.equal(3, #request.sequences[1].documents)
      assert.are.equal(2, #request.sequences[2].documents)
      assert.are.equal(
        0,
        request.sequences[1].documents[1]:get("insert"):to_number()
      )
      assert.are.equal(
        1,
        request.sequences[1].documents[2]:get("insert"):to_number()
      )
      assert.are.equal(
        0,
        request.sequences[1].documents[3]:get("insert"):to_number()
      )
      assert.are.equal(
        "app.events",
        request.sequences[2].documents[1]:get("ns")
      )
      assert.are.equal(
        "audit.events",
        request.sequences[2].documents[2]:get("ns")
      )
      send_response(peer, request, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "admin.$cmd.bulkWrite" },
          { "firstBatch", bson.array({}) },
        }) },
        { "nErrors", 0 },
        { "nInserted", 3 },
        { "nMatched", 0 },
        { "nModified", 0 },
        { "nUpserted", 0 },
        { "nDeleted", 0 },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port,
          { runtime = mongodb.runtime.copas() }
        ))
        local written = assert(client:bulk_write({
          mongodb.client_bulk.insert_one(
            "app.events",
            bson.document({ { "_id", 1 } })
          ),
          mongodb.client_bulk.insert_one(
            "audit.events",
            bson.document({ { "_id", 2 } })
          ),
          mongodb.client_bulk.insert_one(
            "app.events",
            bson.document({ { "_id", 3 } })
          ),
        }))

        assert.are.equal(3, written.inserted_count)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
