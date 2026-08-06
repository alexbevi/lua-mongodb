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
    request_id = 1300 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("public find cursor over OP_MSG", function()
  it("gets another batch and kills the live cursor during client close", function()
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

      local find = receive_frame(peer)

      assert.are.equal("find", find.body:keys()[1])
      assert.are.equal(1, find.body:get("batchSize"):to_number())
      send_response(peer, find, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(101) },
          { "ns", "app.users" },
          { "firstBatch", bson.array({ bson.document({ { "n", 1 } }) }) },
        }) },
      }))

      local get_more = receive_frame(peer)

      assert.are.equal("getMore", get_more.body:keys()[1])
      assert.are.equal(101, get_more.body:get("getMore"):to_number())
      assert.are.equal(1, get_more.body:get("batchSize"):to_number())
      send_response(peer, get_more, bson.document({
        { "ok", 1 },
        { "cursor", bson.document({
          { "id", bson.int64(101) },
          { "ns", "app.users" },
          { "nextBatch", bson.array({ bson.document({ { "n", 2 } }) }) },
        }) },
      }))

      local kill = receive_frame(peer)

      assert.are.equal("killCursors", kill.body:keys()[1])
      assert.are.equal(101, kill.body:get("cursors"):get(1):to_number())
      send_response(peer, kill, bson.document({
        { "ok", 1 },
        { "cursorsKilled", bson.array({ bson.int64(101) }) },
      }))
      peer:close()
    end)

    copas.loop(function()
      outcome = table.pack(pcall(function()
        local client = assert(mongodb.client(
          "mongodb://127.0.0.1:" .. port .. "/app",
          { runtime = mongodb.runtime.copas() }
        ))
        local cursor = assert(client:database():collection("users"):find(nil, {
          batch_size = 1,
        }))

        assert.are.equal(1, assert(cursor:next()):get("n"):to_number())
        assert.are.equal(2, assert(cursor:next()):get("n"):to_number())
        assert.is_true(client:close())
        assert.is_true(cursor:is_closed())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
