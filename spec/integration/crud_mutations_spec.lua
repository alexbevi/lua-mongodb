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
    request_id = 1400 + request.request_id,
    response_to = request.request_id,
  }))))
end

describe("update replace and delete over OP_MSG", function()
  it("executes each public mutation model and returns server counts", function()
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

      for index, expected in ipairs({
        { command = "update", multi = false, modified = 1 },
        { command = "update", multi = true, modified = 2 },
        { command = "update", multi = false, modified = 1, replacement = true },
        { command = "delete", limit = 1, deleted = 1 },
        { command = "delete", limit = 0, deleted = 3 },
      }) do
        local request = receive_frame(peer)

        assert.are.equal(expected.command, request.body:keys()[1])
        if expected.command == "update" then
          local model = request.body:get("updates"):get(1)

          assert.are.equal(expected.multi, model:get("multi"))
          if expected.replacement then
            assert.are.equal("Ada", model:get("u"):get("name"))
          else
            assert.is_true(bson.is_document(model:get("u"):get("$set")))
          end
          send_response(peer, request, bson.document({
            { "ok", 1 },
            { "n", index == 2 and 3 or 1 },
            { "nModified", expected.modified },
          }))
        else
          assert.are.equal(
            expected.limit,
            request.body:get("deletes"):get(1):get("limit"):to_number()
          )
          send_response(peer, request, bson.document({
            { "ok", 1 },
            { "n", expected.deleted },
          }))
        end
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
        local filter = bson.document({ { "active", true } })
        local update = bson.document({
          { "$set", bson.document({ { "active", false } }) },
        })

        assert.are.equal(1, assert(collection:update_one(filter, update)).modified_count)
        assert.are.equal(3, assert(collection:update_many(filter, update)).matched_count)
        assert.are.equal(1, assert(collection:replace_one(
          filter,
          bson.document({ { "name", "Ada" } })
        )).modified_count)
        assert.are.equal(1, assert(collection:delete_one(filter)).deleted_count)
        assert.are.equal(3, assert(collection:delete_many(filter)).deleted_count)
        assert.is_true(client:close())
      end))
      copas.removeserver(server)
    end)

    if not outcome[1] then
      error(outcome[2], 0)
    end
  end)
end)
