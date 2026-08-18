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
    request_id = 2600 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("collection change streams over OP_MSG", function()
  it("opens an initial stream batch and kills the cursor on close", function()
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
      local pipeline = aggregate.body:get("pipeline")

      assert.are.equal("aggregate", aggregate.body:keys()[1])
      assert.are.equal("events", aggregate.body:get("aggregate"))
      assert.are.equal("$changeStream", pipeline:get(1):keys()[1])
      assert.are.equal(
        "futureServerMode",
        pipeline:get(1):get("$changeStream"):get("fullDocument")
      )
      assert.are.equal("$match", pipeline:get(2):keys()[1])
      assert.are.equal(
        2,
        aggregate.body:get("cursor"):get("batchSize"):to_number()
      )
      assert.are.equal("en", aggregate.body:get("collation"):get("locale"))
      assert.are.equal(
        1,
        aggregate.body:get("comment"):get("trace"):to_number()
      )
      assert.are.equal(
        "majority",
        aggregate.body:get("readConcern"):get("level")
      )
      send_response(peer, aggregate, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(51) },
          { "ns", "app.events" },
          { "firstBatch", bson.array({}) },
        }) },
      }))

      local get_more = receive_frame(peer)

      assert.are.equal("getMore", get_more.body:keys()[1])
      assert.are.equal(2, get_more.body:get("batchSize"):to_number())
      assert.are.equal(250, get_more.body:get("maxTimeMS"):to_number())
      assert.are.equal(1, get_more.body:get("comment"):get("trace"):to_number())
      send_response(peer, get_more, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(51) },
          { "ns", "app.events" },
          { "nextBatch", bson.array({
            bson.document({
              { "_id", bson.document({ { "token", 1 } }) },
              { "operationType", "insert" },
            }),
          }) },
        }) },
      }))

      local kill = receive_frame(peer)

      assert.are.equal("killCursors", kill.body:keys()[1])
      assert.are.equal(51, kill.body:get("cursors"):get(1):to_number())
      send_response(peer, kill, bson.document({ { "ok", 1 } }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          {
            read_concern = { level = "majority" },
            runtime = mongodb.runtime.copas(),
          }
        ))
        local collection = assert(client:database():collection("events"))
        local stream = assert(collection:watch(bson.array({
          bson.document({ { "$match", bson.document({
            { "operationType", "insert" },
          }) } }),
        }), {
          batch_size = 2,
          collation = bson.document({ { "locale", "en" } }),
          comment = bson.document({ { "trace", 1 } }),
          full_document = "futureServerMode",
          max_await_time_ms = 250,
        }))

        assert.are.equal("insert", assert(stream:next()):get("operationType"))
        assert.is_true(stream:close())
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
