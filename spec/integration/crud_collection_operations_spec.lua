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
    request_id = 1500 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("core collection operations over OP_MSG", function()
  it("runs aggregate, counts, distinct, and findAndModify", function()
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
        { "maxWireVersion", 25 },
      }))

      local aggregate = receive_frame(peer)

      assert.are.equal("aggregate", aggregate.body:keys()[1])
      send_response(peer, aggregate, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(51) },
          { "ns", "app.users" },
          { "firstBatch", bson.array({ bson.document({ { "n", 1 } }) }) },
        }) },
      }))

      local get_more = receive_frame(peer)

      assert.are.equal("getMore", get_more.body:keys()[1])
      send_response(peer, get_more, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.users" },
          { "nextBatch", bson.array({ bson.document({ { "n", 2 } }) }) },
        }) },
      }))

      local count_documents = receive_frame(peer)

      assert.are.equal("aggregate", count_documents.body:keys()[1])
      assert.are.equal(2, #count_documents.body:get("pipeline"))
      send_response(peer, count_documents, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.users" },
          { "firstBatch", bson.array({ bson.document({ { "n", 2 } }) }) },
        }) },
      }))

      local estimated = receive_frame(peer)

      assert.are.equal("count", estimated.body:keys()[1])
      send_response(peer, estimated, bson.document({ { "ok", 1 }, { "n", 3 } }))

      local distinct = receive_frame(peer)

      assert.are.equal("distinct", distinct.body:keys()[1])
      send_response(peer, distinct, bson.document({
        { "ok", 1 },
        { "values", bson.array({ "a", "b" }) },
      }))

      for index, expected in ipairs({ "remove", "replace", "update" }) do
        local request = receive_frame(peer)

        assert.are.equal("findAndModify", request.body:keys()[1])
        if expected == "remove" then
          assert.is_true(request.body:get("remove"))
        elseif expected == "replace" then
          assert.are.equal("b", request.body:get("update"):get("kind"))
        else
          assert.is_true(bson.is_document(request.body:get("update"):get("$set")))
        end
        send_response(peer, request, bson.document({
          { "ok", 1 },
          { "value", bson.document({ { "index", index } }) },
        }))
      end
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          { runtime = mongodb.runtime.copas() }
        ))
        local collection = assert(client:database():collection("users"))
        local cursor = assert(collection:aggregate(bson.array({
          bson.document({ { "$match", bson.document({}) } }),
        }), { batch_size = 1 }))

        assert.are.equal(1, assert(cursor:next()):get("n"):to_number())
        assert.are.equal(2, assert(cursor:next()):get("n"):to_number())
        assert.are.equal(2, assert(collection:count_documents(bson.document({}))))
        assert.are.equal(3, assert(collection:estimated_document_count()))
        assert.are.equal(2, #assert(collection:distinct("kind")))
        assert.are.equal(1, assert(collection:find_one_and_delete(
          bson.document({})
        )):get("index"):to_number())
        assert.are.equal(2, assert(collection:find_one_and_replace(
          bson.document({}),
          bson.document({ { "kind", "b" } })
        )):get("index"):to_number())
        assert.are.equal(3, assert(collection:find_one_and_update(
          bson.document({}),
          bson.document({ { "$set", bson.document({ { "kind", "c" } }) } })
        )):get("index"):to_number())
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
