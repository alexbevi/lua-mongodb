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
    request_id = 1100 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("single-document CRUD over OP_MSG", function()
  it("inserts, finds one document, and reports duplicate-key details", function()
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

      local insert = receive_frame(peer)
      local inserted = insert.body:get("documents"):get(1)

      assert.are.equal("insert", insert.body:keys()[1])
      assert.are.equal("users", insert.body:get("insert"))
      assert.are.equal("_id", inserted:keys()[1])
      assert.is_true(bson.is_tagged(inserted:get("_id"), "object_id"))
      send_response(peer, insert, bson.document({ { "ok", 1 }, { "n", 1 } }))

      local find = receive_frame(peer)

      assert.are.equal("find", find.body:keys()[1])
      assert.are.equal(1, find.body:get("limit"):to_number())
      assert.is_true(find.body:get("singleBatch"))
      send_response(peer, find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(0) },
          { "ns", "app.users" },
          { "firstBatch", bson.array({ inserted }) },
        }) },
      }))

      local duplicate = receive_frame(peer)

      send_response(peer, duplicate, bson.document({
        { "ok", 1 },
        { "writeErrors", bson.array({
          bson.document({
            { "index", 0 },
            { "code", 11000 },
            { "errmsg", "duplicate key" },
            { "errInfo", bson.document({ { "keyValue", bson.document({
              { "_id", inserted:get("_id") },
            }) } }) },
          }),
        }) },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          { runtime = mongodb.runtime.copas() }
        ))
        local collection = assert(client:database():collection("users"))
        local inserted = assert(collection:insert_one(
          bson.document({ { "name", "Ada" } })
        ))
        local found = assert(collection:find_one(inserted.inserted_id))

        assert.are.equal(inserted.inserted_id, found:get("_id"))
        local duplicate, duplicate_err = collection:insert_one(found)

        assert.is_nil(duplicate)
        assert.is_true(errors.is(duplicate_err, errors.CATEGORY.WRITE))
        assert.are.equal(11000, duplicate_err.code)
        assert.is_true(bson.is_document(duplicate_err.details.write_error))
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
